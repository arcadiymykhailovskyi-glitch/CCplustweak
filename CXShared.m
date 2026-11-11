#import "CXShared.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *const kConfigPath = @"/var/mobile/Library/ControlCenter/ModuleConfiguration.plist";
static NSString *const kIDsKey = @"module-identifiers";

NSArray<NSString *> *CXReadModuleIDs(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kConfigPath];
    NSArray *ids = d[kIDsKey];
    return [ids isKindOfClass:NSArray.class] ? ids : nil;
}

BOOL CXWriteModuleIDs(NSArray<NSString *> *ids) {
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:kConfigPath];
    if (!d || !d[kIDsKey]) return NO; // не трогаем файл, если структура не такая, как ждём
    d[kIDsKey] = ids;
    return [d writeToFile:kConfigPath atomically:YES];
}

static BOOL CXHas(NSString *s, NSArray<NSString *> *needles) {
    for (NSString *n in needles) if ([s containsString:n]) return YES;
    return NO;
}

static NSString *CXCategoryFor(NSString *s) {
    if (CXHas(s, @[@"connectiv", @"wifi", @"bluetooth", @"airplane", @"cellular", @"hotspot"])) return @"Связь";
    if (CXHas(s, @[@"camera", @"flashlight", @"torch", @"record", @"magnif", @"recognition", @"shazam", @"scanner"])) return @"Захват";
    if (CXHas(s, @[@"timer", @"stopwatch", @"alarm", @"clock"])) return @"Часы";
    if (CXHas(s, @[@"brightness", @"display", @"volume", @"audio", @"mirror", @"orientation", @"darkmode", @"nightshift", @"truetone"])) return @"Экран и звук";
    if (CXHas(s, @[@"donotdisturb", @"focus", @"battery", @"lowpower"])) return @"Фокус и питание";
    if (CXHas(s, @[@"nowplaying", @"media", @"music"])) return @"Медиа";
    return @"Другое";
}

static NSString *CXIconFor(NSString *s) {
    NSArray *map = @[
        @[@"connectiv", @"wifi"], @[@"airplane", @"airplane"],
        @[@"flashlight", @"flashlight.on.fill"], @[@"torch", @"flashlight.on.fill"],
        @[@"camera", @"camera.fill"], @[@"record", @"record.circle"],
        @[@"magnif", @"plus.magnifyingglass"], @[@"recognition", @"waveform"], @[@"shazam", @"waveform"],
        @[@"stopwatch", @"stopwatch"], @[@"timer", @"timer"], @[@"alarm", @"alarm.fill"], @[@"clock", @"clock.fill"],
        @[@"calc", @"plus.slash.minus"],
        @[@"brightness", @"sun.max.fill"], @[@"display", @"sun.max.fill"],
        @[@"volume", @"speaker.wave.2.fill"], @[@"audio", @"speaker.wave.2.fill"],
        @[@"mirror", @"rectangle.on.rectangle"], @[@"orientation", @"lock.rotation"],
        @[@"donotdisturb", @"moon.fill"], @[@"focus", @"moon.fill"],
        @[@"lowpower", @"battery.50"], @[@"battery", @"battery.50"],
        @[@"nowplaying", @"play.fill"], @[@"media", @"play.fill"],
        @[@"note", @"note.text"], @[@"hearing", @"ear"], @[@"home", @"house.fill"],
    ];
    for (NSArray *pair in map) if ([s containsString:pair[0]]) return pair[1];
    return @"square.grid.2x2.fill";
}

NSArray<NSDictionary *> *CXAvailableModules(void) {
    NSArray *dirs = @[@"/System/Library/ControlCenter/Bundles",
                      @"/var/jb/Library/ControlCenter/Bundles",
                      @"/Library/ControlCenter/Bundles"];
    NSMutableDictionary *seen = [NSMutableDictionary new];
    NSFileManager *fm = NSFileManager.defaultManager;

    for (NSString *dir in dirs) {
        for (NSString *file in [fm contentsOfDirectoryAtPath:dir error:nil]) {
            if (![file hasSuffix:@".bundle"]) continue;
            NSBundle *b = [NSBundle bundleWithPath:[dir stringByAppendingPathComponent:file]];
            NSString *ident = b.bundleIdentifier;
            if (!ident || seen[ident]) continue;

            NSString *name = [b objectForInfoDictionaryKey:@"CFBundleDisplayName"]
                          ?: [b objectForInfoDictionaryKey:@"CFBundleName"];
            if (![name isKindOfClass:NSString.class] || !name.length) {
                name = [file stringByDeletingPathExtension];
                if ([name hasSuffix:@"Module"]) name = [name substringToIndex:name.length - 6];
            }
            NSString *key = [[ident stringByAppendingString:name] lowercaseString];
            seen[ident] = @{ @"id": ident, @"name": name,
                             @"category": CXCategoryFor(key), @"icon": CXIconFor(key) };
        }
    }
    NSSortDescriptor *sd = [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES
                                                         selector:@selector(localizedCaseInsensitiveCompare:)];
    return [seen.allValues sortedArrayUsingDescriptors:@[sd]];
}

void CXRespring(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ exit(0); });
}

// ---------- Отложенные изменения ----------

NSString *const CXPendingNote = @"com.ccplus.pendingChanged";
static BOOL gPending = NO;
static NSMutableSet<NSString *> *gRemoved = nil;

BOOL CXHasPending(void) { return gPending; }

void CXMarkPending(void) {
    gPending = YES;
    [[NSNotificationCenter defaultCenter] postNotificationName:CXPendingNote object:nil];
}

void CXMarkRemoved(NSString *ident) {
    if (!gRemoved) gRemoved = [NSMutableSet new];
    if (ident) [gRemoved addObject:ident];
    CXMarkPending();
}

void CXMarkAdded(NSString *ident) {
    if (ident) [gRemoved removeObject:ident];
    CXMarkPending();
}

BOOL CXIsRemoved(NSString *ident) {
    return ident && [gRemoved containsObject:ident];
}

// ---------- Диагностика ----------

NSString *const CXDebugNote = @"com.ccplus.debug";
static NSString *gLastDebug = @"—";

void CXDebugLog(NSString *msg) {
    gLastDebug = msg ?: @"";
    NSLog(@"[CCPlus] %@", gLastDebug);
    [[NSNotificationCenter defaultCenter] postNotificationName:CXDebugNote object:nil];
}

NSString *CXLastDebug(void) { return gLastDebug; }

NSString *CXShortID(NSString *ident) {
    NSString *t = [[ident componentsSeparatedByString:@"."] lastObject];
    if ([t hasSuffix:@"Module"] && t.length > 6) t = [t substringToIndex:t.length - 6];
    return t ?: ident;
}

NSString *CXConfigSummary(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kConfigPath];
    if (!d) return @"cfg: файл НЕ читается";
    NSArray *ids = d[kIDsKey];
    if (![ids isKindOfClass:NSArray.class]) {
        return [NSString stringWithFormat:@"cfg: нет module-identifiers; ключи: %@", [d.allKeys componentsJoinedByString:@","]];
    }
    NSMutableArray *short_ = [NSMutableArray new];
    for (NSString *i in ids) [short_ addObject:CXShortID(i)];
    return [NSString stringWithFormat:@"cfg ids(%lu): %@", (unsigned long)ids.count, [short_ componentsJoinedByString:@","]];
}

NSString *CXMatchModuleID(NSString *ident, NSArray<NSString *> *ids) {
    if (!ident) return nil;
    if ([ids containsObject:ident]) return ident;
    NSString *a = CXShortID(ident);
    for (NSString *i in ids) if ([CXShortID(i) isEqualToString:a]) return i;
    return nil;
}

// ---------- Отчёт для отладки ----------

static id CXCallGetter(id target, SEL sel) {
    return ((id (*)(id, SEL))objc_msgSend)(target, sel);
}

static NSString *CXTrim(id obj, NSUInteger max) {
    NSString *s = obj ? [obj description] : @"(nil)";
    s = [[s componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
         componentsJoinedByString:@" "];
    return s.length > max ? [[s substringToIndex:max] stringByAppendingString:@"…"] : s;
}

static BOOL CXLooksSafeGetter(NSString *name) {
    if ([name containsString:@":"]) return NO;
    NSArray *deny = @[@"set", @"save", @"load", @"reset", @"remove", @"add", @"update", @"write",
                      @"delete", @"register", @"start", @"stop", @"init", @"new", @"copy", @"dealloc",
                      @"_set", @"_save", @"_load", @"_reset", @"_remove", @"_add", @"_update", @"_write",
                      @"_delete", @"_register", @"_start", @"_stop", @"_init", @"_new", @"_copy"];
    for (NSString *d in deny) if ([name hasPrefix:d]) return NO;
    if ([name isEqualToString:@"description"] || [name isEqualToString:@"debugDescription"] ||
        [name isEqualToString:@"superclass"] || [name isEqualToString:@"hash"]) return NO;
    NSString *l = name.lowercaseString;
    for (NSString *k in @[@"identifier", @"ordered", @"enabled", @"disabled", @"fixed", @"modules", @"settings", @"configuration"]) {
        if ([l containsString:k]) return YES;
    }
    return NO;
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

static void CXProbeObject(id inst, Class c, NSMutableString *out) {
    if (!c) return;
    [out appendFormat:@"\n== %s ==\n", class_getName(c)];
    unsigned n = 0;
    Method *ms = class_copyMethodList(c, &n);
    NSMutableArray *names = [NSMutableArray new];
    for (unsigned i = 0; i < n; i++) {
        SEL s = method_getName(ms[i]);
        NSString *name = NSStringFromSelector(s);
        NSString *l = name.lowercaseString;
        if ([l containsString:@"module"] || [l containsString:@"identifier"] || [l containsString:@"enabled"] ||
            [l containsString:@"fixed"] || [l containsString:@"order"]) [names addObject:name];
        if (inst && CXLooksSafeGetter(name)) {
            char *rt = method_copyReturnType(ms[i]);
            BOOL isObj = (rt && rt[0] == '@');
            free(rt);
            if (isObj && [inst respondsToSelector:s]) {
                @try {
                    [out appendFormat:@"%@ = %@\n", name, CXTrim(CXCallGetter(inst, s), 350)];
                } @catch (NSException *e) {
                    [out appendFormat:@"%@ = <exception>\n", name];
                }
            }
        }
    }
    free(ms);
    NSString *joined = [names componentsJoinedByString:@" "];
    if (joined.length > 1500) joined = [[joined substringToIndex:1500] stringByAppendingString:@"…"];
    [out appendFormat:@"methods: %@\n", joined];
}

NSString *CXBuildReport(NSArray<NSString *> *shownIDs) {
    NSMutableString *r = [NSMutableString new];
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kConfigPath];
    [r appendFormat:@"PLIST: %@\n", d ? CXTrim(d, 1500) : @"(не читается)"];
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:@"/var/mobile/Library/ControlCenter" error:nil];
    [r appendFormat:@"DIR: %@\n", files ? [files componentsJoinedByString:@", "] : @"(нет)"];
    [r appendFormat:@"SHOWN(%lu): %@\n", (unsigned long)shownIDs.count, [shownIDs componentsJoinedByString:@", "]];

    Class imC = NSClassFromString(@"CCUIModuleInstanceManager");
    id im = nil;
    SEL shared = NSSelectorFromString(@"sharedInstance");
    if (imC && [imC respondsToSelector:shared]) {
        @try { im = CXCallGetter(imC, shared); } @catch (NSException *e) {}
    }
    id repo = CXIvarOfClass(im, @"CCSModuleRepository");
    id prov = CXIvarOfClass(repo, @"CCSModuleSettingsProvider") ?: CXIvarOfClass(im, @"CCSModuleSettingsProvider");

    if (im) CXProbeObject(im, imC, r); else [r appendString:@"\nCCUIModuleInstanceManager: не найден\n"];
    if (repo) CXProbeObject(repo, NSClassFromString(@"CCSModuleRepository"), r);
    else [r appendString:@"\nCCSModuleRepository: не найден в ivar\n"];
    Class provC = NSClassFromString(@"CCSModuleSettingsProvider");
    if (prov) CXProbeObject(prov, provC, r);
    else if (provC) { [r appendString:@"\nSettingsProvider: экземпляр не найден, только методы\n"]; CXProbeObject(nil, provC, r); }
    return r;
}
