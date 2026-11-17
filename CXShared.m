#import "CXShared.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

NSString *const CXPlanNote = @"com.ccplus.planChanged";

// ---------- Рантайм-хелперы (приватные классы без заголовков) ----------

static id CXCallGetter(id target, SEL sel) {
    return ((id (*)(id, SEL))objc_msgSend)(target, sel);
}

static id CXIvarOfClass(id owner, NSString *clsName) {
    if (!owner) return nil;
    unsigned n = 0;
    Ivar *iv = class_copyIvarList(object_getClass(owner), &n);
    id found = nil;
    for (unsigned i = 0; i < n && !found; i++) {
        const char *t = ivar_getTypeEncoding(iv[i]);
        if (t && strstr(t, clsName.UTF8String)) found = object_getIvar(owner, iv[i]);
    }
    free(iv);
    return found;
}

static NSArray *CXArrayFrom(id r) {
    if ([r isKindOfClass:NSArray.class]) return r;
    if ([r isKindOfClass:NSSet.class]) return [(NSSet *)r allObjects];
    return @[];
}

static id CXManager(void);

// Ищем объект нужного класса в полях другого объекта (на несколько уровней вглубь)
static id CXFindObject(id root, Class target, int depth, NSMutableSet *seen) {
    if (!root || depth < 0 || !target) return nil;
    NSValue *key = [NSValue valueWithNonretainedObject:root];
    if ([seen containsObject:key]) return nil;
    [seen addObject:key];
    if ([root isKindOfClass:target]) return root;
    if ([root isKindOfClass:NSString.class] || [root isKindOfClass:NSNumber.class] || [root isKindOfClass:NSData.class] ||
        [root isKindOfClass:NSDate.class] || [root isKindOfClass:NSArray.class] || [root isKindOfClass:NSDictionary.class] ||
        [root isKindOfClass:NSSet.class] || [root isKindOfClass:UIView.class] || [root isKindOfClass:UIViewController.class]) return nil;

    for (Class c = object_getClass(root); c && c != NSObject.class; c = class_getSuperclass(c)) {
        unsigned n = 0;
        Ivar *iv = class_copyIvarList(c, &n);
        for (unsigned i = 0; i < n; i++) {
            const char *t = ivar_getTypeEncoding(iv[i]);
            if (!t || t[0] != '@') continue;
            id v = nil;
            @try { v = object_getIvar(root, iv[i]); } @catch (NSException *e) { v = nil; }
            if (!v) continue;
            id found = CXFindObject(v, target, depth - 1, seen);
            if (found) { free(iv); return found; }
        }
        free(iv);
    }
    return nil;
}

// Настройки пишем через ТОТ ЖЕ объект, которым пользуется сам Control Center. Если писать через новый,
// у Control Center остаётся своя «старая копия» настроек, и она со временем перезаписывает наши изменения.
static id gLiveProv = nil;
static BOOL gLiveProvSearched = NO;

static id CXNewProvider(void) {
    Class pc = NSClassFromString(@"CCSModuleSettingsProvider");
    if (!pc) return nil;
    if (!gLiveProv && !gLiveProvSearched) {
        id im = CXManager();
        if (im) {
            gLiveProv = CXFindObject(im, pc, 5, [NSMutableSet new]);
            gLiveProvSearched = YES;
        }
    }
    return gLiveProv ?: [[pc alloc] init];
}

static NSArray *CXProvList(id prov, NSString *selName) {
    SEL s = NSSelectorFromString(selName);
    if (!prov || ![prov respondsToSelector:s]) return @[];
    @try { return CXArrayFrom(CXCallGetter(prov, s)); } @catch (NSException *e) { return @[]; }
}

static void CXProvSet(id prov, NSString *selName, NSArray *arr) {
    SEL s = NSSelectorFromString(selName);
    if (!prov || ![prov respondsToSelector:s]) return;
    @try { ((void (*)(id, SEL, id))objc_msgSend)(prov, s, arr); } @catch (NSException *e) {}
}

static id CXManager(void) {
    Class c = NSClassFromString(@"CCUIModuleInstanceManager");
    SEL s = NSSelectorFromString(@"sharedInstance");
    if (c && [c respondsToSelector:s]) return CXCallGetter(c, s);
    return nil;
}

static NSSet *CXLiveSet(id im) {
    SEL s = NSSelectorFromString(@"enabledModuleIdentifiers");
    if (!im || ![im respondsToSelector:s]) return nil;
    id r = CXCallGetter(im, s);
    if ([r isKindOfClass:NSSet.class]) return r;
    if ([r isKindOfClass:NSArray.class]) return [NSSet setWithArray:r];
    return nil;
}

void CXDebugLog(NSString *msg) {
    NSLog(@"[CCPlus] %@", msg);
}

void CXRespringNow(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ exit(0); });
}

// ---------- Имена, категории, иконки ----------

NSString *CXShortID(NSString *ident) {
    NSString *t = [[ident componentsSeparatedByString:@"."] lastObject];
    if ([t hasSuffix:@"Module"] && t.length > 6) t = [t substringToIndex:t.length - 6];
    return t ?: ident;
}

static NSString *CXKey(NSString *ident) {
    return [[CXShortID(ident) stringByAppendingFormat:@" %@", ident] lowercaseString];
}

static BOOL CXHas(NSString *s, NSArray<NSString *> *needles) {
    for (NSString *n in needles) if ([s containsString:n]) return YES;
    return NO;
}

static NSString *CXCategoryFor(NSString *k) {
    if (CXHas(k, @[@"connectiv", @"airplane", @"wifi", @"bluetooth", @"cellular", @"hotspot"])) return @"Связь";
    if (CXHas(k, @[@"camera", @"flashlight", @"torch", @"screencapture", @"magnif", @"recognition", @"shazam",
                   @"scanner", @"voicememo", @"nfc", @"barcode", @"videoconference", @"audioconference"])) return @"Захват";
    if (CXHas(k, @[@"stopwatch", @"alarm", @"timer", @"clock", @"sleep"])) return @"Часы";
    if (CXHas(k, @[@"display", @"brightness", @"audio", @"volume", @"mirror", @"orientation", @"darkmode",
                   @"nightshift", @"truetone", @"textsize", @"mute", @"silence"])) return @"Экран и звук";
    if (CXHas(k, @[@"focus", @"donotdisturb", @"lowpower", @"battery"])) return @"Фокус и питание";
    if (CXHas(k, @[@"nowplaying", @"media", @"music", @"remote"])) return @"Медиа";
    if (CXHas(k, @[@"hearing", @"accessib", @"guided"])) return @"Универсальный доступ";
    if (CXHas(k, @[@"home"])) return @"Дом";
    return @"Другое";
}

NSString *CXCategoryIcon(NSString *category) {
    NSDictionary *m = @{ @"Связь": @"wifi", @"Захват": @"camera.fill", @"Часы": @"clock.fill",
                         @"Экран и звук": @"speaker.wave.2.fill", @"Фокус и питание": @"moon.fill",
                         @"Медиа": @"play.rectangle.fill", @"Универсальный доступ": @"person.circle.fill",
                         @"Дом": @"house.fill" };
    return m[category] ?: @"square.grid.2x2.fill";
}

static NSString *CXIconFor(NSString *k) {
    NSArray *map = @[
        @[@"connectiv", @"wifi"], @[@"airplane", @"airplane"],
        @[@"flashlight", @"flashlight.on.fill"], @[@"torch", @"flashlight.on.fill"],
        @[@"screencapture", @"record.circle"], @[@"videoconference", @"camera.filters"],
        @[@"audioconference", @"mic.fill"], @[@"camera", @"camera.fill"],
        @[@"magnif", @"plus.magnifyingglass"], @[@"recognition", @"waveform"], @[@"shazam", @"waveform"],
        @[@"stopwatch", @"stopwatch.fill"], @[@"alarm", @"alarm.fill"], @[@"timer", @"timer"],
        @[@"calculator", @"plus.slash.minus"],
        @[@"display", @"sun.max.fill"], @[@"audio", @"speaker.wave.2.fill"],
        @[@"mirror", @"rectangle.on.rectangle"], @[@"orientation", @"lock.rotation"],
        @[@"focus", @"moon.fill"], @[@"donotdisturb", @"moon.fill"],
        @[@"lowpower", @"battery.25"], @[@"nowplaying", @"play.fill"],
        @[@"voicememo", @"waveform.circle.fill"], @[@"sleep", @"bed.double.fill"],
        @[@"silence", @"bell.slash.fill"], @[@"mute", @"bell.slash.fill"],
        @[@"nfc", @"wave.3.right"], @[@"barcode", @"qrcode.viewfinder"],
        @[@"hearing", @"ear"], @[@"home", @"house.fill"], @[@"textsize", @"textformat.size"],
        @[@"darkmode", @"circle.lefthalf.filled"], @[@"accessib", @"person.circle.fill"],
        @[@"guided", @"lock.circle.fill"], @[@"remote", @"tv.fill"],
        @[@"note", @"note.text"], @[@"wallet", @"creditcard.fill"],
    ];
    for (NSArray *pair in map) if ([k containsString:pair[0]]) return pair[1];
    return @"square.grid.2x2.fill";
}

// Цвета плиток в выборе: как у системных значков (оранжевые часы, красная запись, индиго для сна и т.д.)
static UIColor *CXRGB(NSInteger hex) {
    return [UIColor colorWithRed:((hex >> 16) & 0xFF) / 255.0 green:((hex >> 8) & 0xFF) / 255.0
                            blue:(hex & 0xFF) / 255.0 alpha:1.0];
}

static UIColor *CXColorFor(NSString *k) {
    NSArray *map = @[
        @[@"connectiv", @0x30D158], @[@"airplane", @0xFF9F0A],
        @[@"screencapture", @0xFF453A], @[@"voicememo", @0xFF453A],
        @[@"videoconference", @0x5E5CE6], @[@"audioconference", @0x5E5CE6],
        @[@"flashlight", @0x636366], @[@"torch", @0x636366], @[@"camera", @0x636366],
        @[@"magnif", @0x0A84FF], @[@"recognition", @0x0A84FF], @[@"shazam", @0x0A84FF],
        @[@"stopwatch", @0xFF9F0A], @[@"alarm", @0xFF9F0A], @[@"timer", @0xFF9F0A], @[@"calculator", @0xFF9F0A],
        @[@"sleep", @0x5E5CE6], @[@"focus", @0x5E5CE6], @[@"donotdisturb", @0x5E5CE6],
        @[@"lowpower", @0xFFD60A], @[@"home", @0xFF9F0A],
        @[@"display", @0x0A84FF], @[@"audio", @0xFF375F], @[@"mirror", @0x0A84FF], @[@"orientation", @0xFF453A],
        @[@"silence", @0xFF453A], @[@"mute", @0xFF453A],
        @[@"nfc", @0x30B0C7], @[@"barcode", @0x636366],
        @[@"hearing", @0x0A84FF], @[@"accessib", @0x0A84FF], @[@"textsize", @0x0A84FF],
        @[@"darkmode", @0x636366], @[@"guided", @0x0A84FF], @[@"remote", @0x636366],
        @[@"note", @0xFFD60A], @[@"wallet", @0x30D158], @[@"nowplaying", @0xFF375F],
    ];
    for (NSArray *pair in map) if ([k containsString:pair[0]]) return CXRGB([pair[1] integerValue]);
    return CXRGB(0x48484A);
}

static NSString *CXRussianName(NSString *k) {
    NSArray *map = @[
        @[@"flashlight", @"Фонарик"], @[@"torch", @"Фонарик"],
        @[@"screencapture", @"Запись экрана"], @[@"videoconference", @"Эффекты видео"],
        @[@"audioconference", @"Режим микрофона"], @[@"camera", @"Камера"],
        @[@"magnif", @"Лупа"], @[@"recognition", @"Распознавание музыки"], @[@"shazam", @"Распознавание музыки"],
        @[@"stopwatch", @"Секундомер"], @[@"alarm", @"Будильник"], @[@"timer", @"Таймер"],
        @[@"calculator", @"Калькулятор"], @[@"lowpower", @"Эконом. режим"],
        @[@"voicememo", @"Диктофон"], @[@"sleep", @"Режим сна"],
        @[@"silence", @"Заглушить звонки"], @[@"mute", @"Без звука"],
        @[@"nfc", @"Метки NFC"], @[@"barcode", @"Сканер кодов"],
        @[@"hearing", @"Слух"], @[@"home", @"Дом"], @[@"textsize", @"Размер текста"],
        @[@"darkmode", @"Тёмный режим"], @[@"guided", @"Гид-доступ"], @[@"remote", @"Пульт Apple TV"],
        @[@"note", @"Заметки"], @[@"wallet", @"Wallet"],
    ];
    for (NSArray *pair in map) if ([k containsString:pair[0]]) return pair[1];
    return nil;
}

// ---------- Язык ----------

BOOL CXIsRussian(void) {
    static BOOL ru = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *l = [NSLocale preferredLanguages].firstObject ?: @"";
        ru = [l hasPrefix:@"ru"] || [l hasPrefix:@"uk"] || [l hasPrefix:@"be"];
    });
    return ru;
}

NSString *CXCategoryTitle(NSString *key) {
    if (CXIsRussian()) return key;
    NSDictionary *m = @{ @"Связь": @"Connectivity", @"Захват": @"Capture", @"Часы": @"Clock",
                         @"Экран и звук": @"Display & Sound", @"Фокус и питание": @"Focus & Power",
                         @"Медиа": @"Media", @"Универсальный доступ": @"Accessibility",
                         @"Дом": @"Home", @"Другое": @"Other" };
    return m[key] ?: key;
}

NSString *CXModuleDisplayName(NSString *ident) {
    NSString *key = CXKey(ident);
    return (CXIsRussian() ? CXRussianName(key) : nil) ?: CXShortID(ident);
}

// ---------- Данные о модулях ----------

static NSArray *gCacheFx = nil, *gCacheUf = nil, *gCacheUe = nil;

void CXInvalidateCache(void) {
    gCacheFx = nil; gCacheUf = nil; gCacheUe = nil;
    gLiveProv = nil;               // Control Center мог создать новый объект настроек: ищем заново
    gLiveProvSearched = NO;
}

static void CXLoadCache(void) {
    if (gCacheFx) return;
    id prov = CXNewProvider();
    gCacheFx = CXProvList(prov, @"orderedFixedModuleIdentifiers");
    gCacheUf = CXProvList(prov, @"orderedUserEnabledFixedModuleIdentifiers");
    gCacheUe = CXProvList(prov, @"orderedUserEnabledModuleIdentifiers");
}

NSArray<NSString *> *CXUserOrder(void) {
    CXLoadCache();
    return gCacheUe;
}

NSSet<NSString *> *CXCurrentEnabledIDs(void) {
    id prov = CXNewProvider();
    NSMutableSet *all = [NSMutableSet new];
    NSSet *live = CXLiveSet(CXManager());
    if (live) [all unionSet:live];
    [all addObjectsFromArray:CXProvList(prov, @"orderedUserEnabledModuleIdentifiers")];
    [all addObjectsFromArray:CXProvList(prov, @"orderedUserEnabledFixedModuleIdentifiers")];
    [all addObjectsFromArray:CXProvList(prov, @"orderedFixedModuleIdentifiers")];
    return all;
}

BOOL CXIsRemovable(NSString *ident) {
    CXLoadCache();
    return !([gCacheFx containsObject:ident] && ![gCacheUf containsObject:ident]);
}

BOOL CXIsMovable(NSString *ident) {
    CXLoadCache();
    return [gCacheUe containsObject:ident];
}

NSArray<NSDictionary *> *CXAvailableModules(void) {
    // 1. Названия из bundle-ов Control Center
    NSArray *dirs = @[@"/System/Library/ControlCenter/Bundles",
                      @"/var/jb/Library/ControlCenter/Bundles",
                      @"/Library/ControlCenter/Bundles"];
    NSMutableDictionary<NSString *, NSString *> *bundleNames = [NSMutableDictionary new];
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *dir in dirs) {
        for (NSString *file in [fm contentsOfDirectoryAtPath:dir error:nil]) {
            if (![file hasSuffix:@".bundle"]) continue;
            NSBundle *b = [NSBundle bundleWithPath:[dir stringByAppendingPathComponent:file]];
            NSString *ident = b.bundleIdentifier;
            if (!ident || bundleNames[ident]) continue;
            NSString *name = [b objectForInfoDictionaryKey:@"CFBundleDisplayName"] ?: [b objectForInfoDictionaryKey:@"CFBundleName"];
            if ([name isKindOfClass:NSString.class] && name.length) bundleNames[ident] = name;
            else bundleNames[ident] = CXShortID(ident);
        }
    }

    // 2. Что Control Center реально может загрузить на этом устройстве.
    //    Показываем ТОЛЬКО такие модули, иначе часть плиток «добавляется», но на экране не появляется.
    NSArray *ids = nil;
    id repo = CXIvarOfClass(CXManager(), @"CCSModuleRepository");
    SEL loadSel = NSSelectorFromString(@"loadableModuleIdentifiers");
    if (repo && [repo respondsToSelector:loadSel]) {
        @try { ids = CXArrayFrom(CXCallGetter(repo, loadSel)); } @catch (NSException *e) { ids = nil; }
    }
    if (ids.count == 0) ids = bundleNames.allKeys;   // запасной вариант

    // 3. Фиксированные модули (Связь, Яркость и т.п.) добавлять нельзя
    id prov = CXNewProvider();
    NSArray *fixed = CXProvList(prov, @"orderedFixedModuleIdentifiers");
    NSArray *userFixed = CXProvList(prov, @"orderedUserEnabledFixedModuleIdentifiers");

    NSMutableArray *result = [NSMutableArray new];
    NSMutableSet *seen = [NSMutableSet new];
    for (id obj in ids) {
        if (![obj isKindOfClass:NSString.class]) continue;
        NSString *ident = obj;
        if ([seen containsObject:ident]) continue;
        [seen addObject:ident];
        if ([fixed containsObject:ident] && ![userFixed containsObject:ident]) continue;

        NSString *key = CXKey(ident);
        NSString *name = (CXIsRussian() ? CXRussianName(key) : nil) ?: bundleNames[ident] ?: CXShortID(ident);
        [result addObject:@{ @"id": ident, @"name": name,
                             @"category": CXCategoryFor(key), @"icon": CXIconFor(key),
                             @"color": CXColorFor(key) }];
    }
    NSSortDescriptor *sd = [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES
                                                         selector:@selector(localizedCaseInsensitiveCompare:)];
    return [result sortedArrayUsingDescriptors:@[sd]];
}

static NSMutableOrderedSet<NSString *> *gPlanRemove = nil;
static NSMutableOrderedSet<NSString *> *gPlanAdd = nil;
static NSArray<NSString *> *gPlanOrder = nil;

// ---------- Запись изменений (используется только при «Применить») ----------

static void CXApplyRemove(NSString *ident) {
    id prov = CXNewProvider();
    NSArray *ue = CXProvList(prov, @"orderedUserEnabledModuleIdentifiers");
    NSArray *uf = CXProvList(prov, @"orderedUserEnabledFixedModuleIdentifiers");
    if ([ue containsObject:ident]) {
        NSMutableArray *n = [ue mutableCopy];
        [n removeObject:ident];
        CXProvSet(prov, @"setAndSaveOrderedUserEnabledModuleIdentifiers:", n);
    } else if ([uf containsObject:ident]) {
        NSMutableArray *n = [uf mutableCopy];
        [n removeObject:ident];
        CXProvSet(prov, @"setAndSaveOrderedUserEnabledFixedModuleIdentifiers:", n);
    }
}

// Если модуль числится среди «отключённых пользователем», он не появится, сколько его ни добавляй.
// Возвращаем ему видимость через репозиторий модулей (так делает сам Control Center в Настройках).
static void CXEnableVisibility(NSString *ident) {
    id prov = CXNewProvider();
    NSArray *disabled = CXProvList(prov, @"userDisabledModuleIdentifiers");
    if (![disabled containsObject:ident]) return;

    id repo = CXFindObject(CXManager(), NSClassFromString(@"CCSModuleRepository"), 4, [NSMutableSet new]);
    SEL vis = NSSelectorFromString(@"visibilityForModuleIdentifier:");
    SEL setVis = NSSelectorFromString(@"setVisibility:forModuleIdentifier:");
    if (!repo || ![repo respondsToSelector:vis] || ![repo respondsToSelector:setVis]) return;

    // Какое значение означает «включён»: смотрим на модуль, который сейчас точно включён
    NSArray *enabled = CXProvList(prov, @"orderedUserEnabledModuleIdentifiers");
    NSString *probe = enabled.firstObject;
    if (!probe) return;
    @try {
        NSUInteger onVal = ((NSUInteger (*)(id, SEL, id))objc_msgSend)(repo, vis, probe) & 0xFF;
        ((void (*)(id, SEL, NSUInteger, id))objc_msgSend)(repo, setVis, onVal, ident);
    } @catch (NSException *e) {}
}

static void CXApplyAdd(NSString *ident) {
    CXEnableVisibility(ident);
    id prov = CXNewProvider();
    NSArray *fx = CXProvList(prov, @"orderedFixedModuleIdentifiers");
    NSArray *ue = CXProvList(prov, @"orderedUserEnabledModuleIdentifiers");
    NSArray *uf = CXProvList(prov, @"orderedUserEnabledFixedModuleIdentifiers");
    if ([fx containsObject:ident]) {
        if (![uf containsObject:ident]) {
            NSMutableArray *n = [uf mutableCopy];
            [n addObject:ident];
            CXProvSet(prov, @"setAndSaveOrderedUserEnabledFixedModuleIdentifiers:", n);
        }
    } else if (![ue containsObject:ident]) {
        NSMutableArray *n = [ue mutableCopy];
        [n addObject:ident];
        CXProvSet(prov, @"setAndSaveOrderedUserEnabledModuleIdentifiers:", n);
    }
}

static void CXApplyOrder(NSArray<NSString *> *order) {
    id prov = CXNewProvider();
    NSArray *ue = CXProvList(prov, @"orderedUserEnabledModuleIdentifiers");
    NSArray *fx = CXProvList(prov, @"orderedFixedModuleIdentifiers");
    NSArray *uf = CXProvList(prov, @"orderedUserEnabledFixedModuleIdentifiers");
    NSMutableArray *n = [NSMutableArray new];
    // Всё, что видно на экране, в новом порядке (и модули любого размера). Системно закреплённые модули
    // в пользовательский список не добавляем, иначе они могли бы продублироваться.
    for (NSString *i in order) {
        if ([fx containsObject:i] && ![uf containsObject:i]) continue;
        if (![n containsObject:i] && ![gPlanRemove containsObject:i]) [n addObject:i];
    }
    for (NSString *i in ue) if (![n containsObject:i] && ![gPlanRemove containsObject:i]) [n addObject:i];
    CXProvSet(prov, @"setAndSaveOrderedUserEnabledModuleIdentifiers:", n);
}

void CXForgetModules(NSArray<NSString *> *ids) {
    for (NSString *i in ids) CXApplyRemove(i);
}

// ---------- План изменений ----------


static void CXPlanEnsure(void) {
    if (!gPlanRemove) gPlanRemove = [NSMutableOrderedSet new];
    if (!gPlanAdd) gPlanAdd = [NSMutableOrderedSet new];
}

static void CXPlanPost(void) {
    [[NSNotificationCenter defaultCenter] postNotificationName:CXPlanNote object:nil];
}

BOOL CXPlanHasChanges(void) { return CXPlanCount() > 0; }

NSUInteger CXPlanCount(void) {
    return gPlanRemove.count + gPlanAdd.count + (gPlanOrder ? 1 : 0);
}

BOOL CXPlanIsRemoved(NSString *ident) { return ident && [gPlanRemove containsObject:ident]; }
BOOL CXPlanIsAdded(NSString *ident) { return ident && [gPlanAdd containsObject:ident]; }

void CXPlanToggleRemove(NSString *ident) {
    if (!ident) return;
    CXPlanEnsure();
    if ([gPlanRemove containsObject:ident]) [gPlanRemove removeObject:ident];
    else [gPlanRemove addObject:ident];
    CXPlanPost();
}

void CXPlanToggleAdd(NSString *ident) {
    if (!ident) return;
    CXPlanEnsure();
    if ([gPlanRemove containsObject:ident]) [gPlanRemove removeObject:ident];   // «вернуть» ранее убранный
    else if ([gPlanAdd containsObject:ident]) [gPlanAdd removeObject:ident];
    else [gPlanAdd addObject:ident];
    CXPlanPost();
}

void CXPlanSetOrder(NSArray<NSString *> *order) {
    gPlanOrder = [order copy];
    CXPlanPost();
}

NSArray<NSString *> *CXPlanOrder(void) { return gPlanOrder; }

void CXPlanReset(void) {
    [gPlanRemove removeAllObjects];
    [gPlanAdd removeAllObjects];
    gPlanOrder = nil;
    CXPlanPost();
}

void CXPlanClear(void) {
    [gPlanRemove removeAllObjects];
    [gPlanAdd removeAllObjects];
    gPlanOrder = nil;
    CXPlanPost();
}

NSArray<NSString *> *CXPlanRemovedList(void) { return [gPlanRemove array] ?: @[]; }
NSArray<NSString *> *CXPlanAddedList(void) { return [gPlanAdd array] ?: @[]; }

// Только записываем изменения в настройки Control Center. Модулями «вживую» не управляем:
// такие правки оставляли виджеты висеть сверху и «мёртвыми». Control Center сам перечитывает
// настройки при следующем открытии.
void CXPlanApplyPersist(void) {
    gLiveProv = nil;
    gLiveProvSearched = NO;
    for (NSString *r in [gPlanRemove array]) CXApplyRemove(r);
    for (NSString *a in [gPlanAdd array]) CXApplyAdd(a);
    if (gPlanOrder.count) CXApplyOrder(gPlanOrder);
}
