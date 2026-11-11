#import "CXShared.h"
#import <UIKit/UIKit.h>

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
