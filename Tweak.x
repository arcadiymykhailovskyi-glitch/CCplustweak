#import <UIKit/UIKit.h>
#import "CXShared.h"
#import "CXPickerController.h"

static BOOL gEditing = NO;
static NSString *const kEditNote = @"com.ccplus.editChanged";
enum { kTagPlus = 7001, kTagDone = 7002, kTagBadge = 7003 };

// Прозрачный слой поверх всего окна Control Center: пропускает касания, кроме своих кнопок/шторки
@interface CXHostView : UIView
@end
@implementation CXHostView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    return (v == self) ? nil : v;
}
@end

static CXHostView *gHost = nil;
static CXPickerController *gSheet = nil;

@interface CCUIModularControlCenterOverlayViewController : UIViewController
- (void)cx_setEditing:(BOOL)on;
- (void)cx_plusTapped;
- (void)cx_doneTapped;
- (void)cx_refreshDone;
- (void)cx_longPressed:(UILongPressGestureRecognizer *)g;
@end

@interface CCUIContentModuleContainerViewController : UIViewController
- (NSString *)moduleIdentifier;
- (void)cx_updateBadge;
- (void)cx_removeTapped;
@end

static UIButton *CXPill(NSString *title, NSString *symbol, NSInteger tag) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.tag = tag;
    b.tintColor = UIColor.whiteColor;
    b.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.25];
    b.layer.cornerRadius = 16;
    b.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    b.contentEdgeInsets = UIEdgeInsetsMake(6, 16, 6, 16);
    if (symbol) [b setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
    if (title) [b setTitle:title forState:UIControlStateNormal];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    return b;
}

// ---------- Оверлей Control Center: долгий тап, «+» и «Готово / Применить» ----------

%hook CCUIModularControlCenterOverlayViewController

- (void)viewDidLoad {
    %orig;
    UILongPressGestureRecognizer *lp =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(cx_longPressed:)];
    lp.minimumPressDuration = 0.9;
    lp.cancelsTouchesInView = NO;
    [self.view addGestureRecognizer:lp];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(cx_refreshDone)
                                                 name:CXPendingNote object:nil];
}

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    if (CXHasPending()) CXRespring();   // закрыли Control Center: применяем накопленные изменения
    else [self cx_setEditing:NO];
}

%new
- (void)cx_longPressed:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan && !gEditing) [self cx_setEditing:YES];
}

%new
- (void)cx_setEditing:(BOOL)on {
    if (gEditing == on) return;
    gEditing = on;

    if (on) {
        // Кнопки живут не внутри view контроллера, а в верхнем слое окна: так их ничто не перекроет
        UIView *parent = self.view.window ?: self.view;
        CXHostView *host = [[CXHostView alloc] initWithFrame:parent.bounds];
        host.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        host.backgroundColor = UIColor.clearColor;

        UIButton *plus = CXPill(nil, @"plus", kTagPlus);
        [plus addTarget:self action:@selector(cx_plusTapped) forControlEvents:UIControlEventTouchUpInside];
        UIButton *done = CXPill(@"Готово", nil, kTagDone);
        [done addTarget:self action:@selector(cx_doneTapped) forControlEvents:UIControlEventTouchUpInside];
        [host addSubview:plus];
        [host addSubview:done];

        UILayoutGuide *g = host.safeAreaLayoutGuide;
        [NSLayoutConstraint activateConstraints:@[
            [plus.topAnchor constraintEqualToAnchor:g.topAnchor constant:8],
            [plus.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-16],
            [done.topAnchor constraintEqualToAnchor:g.topAnchor constant:8],
            [done.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:16],
        ]];

        [parent addSubview:host];
        gHost = host;
        [self cx_refreshDone];
    } else {
        if (gSheet) {
            [gSheet.view removeFromSuperview];
            [gSheet removeFromParentViewController];
            gSheet = nil;
        }
        [gHost removeFromSuperview];
        gHost = nil;
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:kEditNote object:nil];
}

%new
- (void)cx_refreshDone {
    UIButton *done = (UIButton *)[gHost viewWithTag:kTagDone];
    BOOL pending = CXHasPending();
    [done setTitle:(pending ? @"Применить" : @"Готово") forState:UIControlStateNormal];
    done.backgroundColor = pending ? [UIColor colorWithRed:0.20 green:0.70 blue:0.35 alpha:0.95]
                                   : [UIColor colorWithWhite:1.0 alpha:0.25];
}

%new
- (void)cx_doneTapped {
    NSLog(@"[CCPlus] done tapped, pending=%d", CXHasPending());
    if (CXHasPending()) { CXRespring(); return; }  // один респринг на все изменения
    [self cx_setEditing:NO];
}

%new
- (void)cx_plusTapped {
    NSLog(@"[CCPlus] plus tapped");
    if (!gHost || gSheet) return;

    CXPickerController *vc = [CXPickerController new];
    [self addChildViewController:vc];

    CGRect b = gHost.bounds;
    CGFloat h = floor(b.size.height * 0.62);
    vc.view.frame = CGRectMake(0, b.size.height, b.size.width, h);
    vc.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    vc.view.layer.cornerRadius = 18;
    vc.view.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    vc.view.clipsToBounds = YES;
    [gHost addSubview:vc.view];
    [vc didMoveToParentViewController:self];

    gSheet = vc;
    vc.onClose = ^{ gSheet = nil; };

    [UIView animateWithDuration:0.28 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        vc.view.frame = CGRectMake(0, b.size.height - h, b.size.width, h);
    } completion:nil];
}

%end

// ---------- Контейнер каждого модуля: бейдж «−» и покачивание ----------

%hook CCUIContentModuleContainerViewController

- (void)viewDidLoad {
    %orig;
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(cx_updateBadge)
                                                 name:kEditNote object:nil];
}

- (void)viewDidLayoutSubviews {
    %orig;
    [self cx_updateBadge];
}

%new
- (void)cx_updateBadge {
    if (![self respondsToSelector:@selector(moduleIdentifier)]) return;
    UIView *v = self.view;
    UIButton *badge = (UIButton *)[v viewWithTag:kTagBadge];
    BOOL removed = CXIsRemoved([self moduleIdentifier]);

    if (gEditing && removed) {
        // Уже удалён из конфига: гасим модуль до респринга
        [badge removeFromSuperview];
        [v.layer removeAnimationForKey:@"cx_wobble"];
        v.userInteractionEnabled = NO;
        v.alpha = 0.2;
    } else if (gEditing) {
        if (!badge) {
            badge = [UIButton buttonWithType:UIButtonTypeSystem];
            badge.tag = kTagBadge;
            UIImageSymbolConfiguration *cfg =
                [UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightBold];
            [badge setImage:[UIImage systemImageNamed:@"minus.circle.fill" withConfiguration:cfg]
                   forState:UIControlStateNormal];
            badge.tintColor = UIColor.whiteColor;
            badge.frame = CGRectMake(4, 4, 30, 30);
            [badge addTarget:self action:@selector(cx_removeTapped)
            forControlEvents:UIControlEventTouchUpInside];
            [v addSubview:badge];
        }
        [v bringSubviewToFront:badge];

        if (![v.layer animationForKey:@"cx_wobble"]) {
            CABasicAnimation *w = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
            w.fromValue = @(-0.012);
            w.toValue = @(0.012);
            w.duration = 0.13;
            w.autoreverses = YES;
            w.repeatCount = HUGE_VALF;
            [v.layer addAnimation:w forKey:@"cx_wobble"];
        }
    } else {
        [badge removeFromSuperview];
        [v.layer removeAnimationForKey:@"cx_wobble"];
    }
}

%new
- (void)cx_removeTapped {
    NSString *ident = [self moduleIdentifier];
    NSMutableArray *ids = [CXReadModuleIDs() mutableCopy];
    if (!ident || !ids) return;
    [ids removeObject:ident];
    if (!CXWriteModuleIDs(ids)) return;

    // Респринга нет: модуль гаснет, изменения применятся по «Применить»
    CXMarkRemoved(ident);
    [self cx_updateBadge];
}

%end
