#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <spawn.h>
#import <unistd.h>

static NSString *const kDomain = @"com.yourname.ccplus";
static NSString *const kNotify = @"com.yourname.ccplus/prefschanged";

@interface CCPRootListController : PSListController
@end

@implementation CCPRootListController

static BOOL CCPIsRussian(void) {
    NSString *l = [NSLocale preferredLanguages].firstObject ?: @"";
    return [l hasPrefix:@"ru"] || [l hasPrefix:@"uk"] || [l hasPrefix:@"be"];
}

static PSSpecifier *CCPSwitch(id target, NSString *title, NSString *key) {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:title
                                                    target:target
                                                       set:@selector(setPreferenceValue:specifier:)
                                                       get:@selector(readPreferenceValue:)
                                                    detail:nil
                                                      cell:PSSwitchCell
                                                      edit:nil];
    [s setProperty:kDomain forKey:@"defaults"];
    [s setProperty:key forKey:@"key"];
    [s setProperty:@YES forKey:@"default"];
    [s setProperty:kNotify forKey:@"PostNotification"];
    return s;
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        BOOL ru = CCPIsRussian();
        NSMutableArray *list = [NSMutableArray new];

        PSSpecifier *main = [PSSpecifier groupSpecifierWithName:ru ? @"Основное" : @"General"];
        [main setProperty:(ru ? @"Если выключить, Пункт управления работает как обычно, без изменений от CCPlus."
                              : @"When off, Control Center behaves as stock, without any CCPlus changes.")
                   forKey:@"footerText"];
        [list addObject:main];
        [list addObject:CCPSwitch(self, ru ? @"Включить CCPlus" : @"Enable CCPlus", @"enabled")];

        PSSpecifier *look = [PSSpecifier groupSpecifierWithName:ru ? @"Внешний вид" : @"Appearance"];
        [look setProperty:(ru ? @"Размытие сверху убирается при следующем открытии Пункта управления."
                              : @"The top blur is removed the next time you open Control Center.")
                   forKey:@"footerText"];
        [list addObject:look];
        [list addObject:CCPSwitch(self, ru ? @"Убрать размытие сверху" : @"Hide top blur", @"hideBlur")];
        [list addObject:CCPSwitch(self, ru ? @"Точки страниц справа" : @"Page dots on the right", @"showDots")];
        [list addObject:CCPSwitch(self, ru ? @"Тактильный отклик" : @"Haptic feedback", @"haptics")];

        PSSpecifier *tools = [PSSpecifier groupSpecifierWithName:ru ? @"Дополнительно" : @"Advanced"];
        [tools setProperty:(ru ? @"Режим редактирования: зажмите пустое место или двумя пальцами в любом месте."
                               : @"Edit mode: press and hold an empty area, or hold with two fingers anywhere.")
                    forKey:@"footerText"];
        [list addObject:tools];
        PSSpecifier *respring = [PSSpecifier preferenceSpecifierNamed:ru ? @"Перезапустить SpringBoard" : @"Respring"
                                                               target:self
                                                                  set:NULL
                                                                  get:NULL
                                                               detail:nil
                                                                 cell:PSButtonCell
                                                                 edit:nil];
        respring.buttonAction = @selector(respring);
        [list addObject:respring];

        _specifiers = list;
    }
    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"CCPlus";
}

- (void)respring {
    const char *tools[] = { "/var/jb/usr/bin/sbreload", "/usr/bin/sbreload", NULL };
    for (int i = 0; tools[i]; i++) {
        if (access(tools[i], X_OK) == 0) {
            pid_t pid;
            const char *argv[] = { "sbreload", NULL };
            posix_spawn(&pid, tools[i], NULL, NULL, (char *const *)argv, NULL);
            return;
        }
    }
    const char *killers[] = { "/var/jb/usr/bin/killall", "/usr/bin/killall", NULL };
    for (int i = 0; killers[i]; i++) {
        if (access(killers[i], X_OK) == 0) {
            pid_t pid;
            const char *argv[] = { "killall", "-9", "SpringBoard", NULL };
            posix_spawn(&pid, killers[i], NULL, NULL, (char *const *)argv, NULL);
            return;
        }
    }
}

@end
