#import <UIKit/UIKit.h>
#import "CXShared.h"
#import "CXPickerController.h"

static BOOL gEditing = NO;
static NSString *const kEditNote = @"com.ccplus.editChanged";
enum { kTagPlus = 7001, kTagDone = 7002, kTagBadge = 7003 };

@interface CCUIModularControlCenterOverlayViewController : UIViewController
- (void)cx_setEditing:(BOOL)on;
- (void)cx_plusTapped;
- (void)cx_doneTapped;
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
    b.hidden = YES;
    return b;
}

// ---------- Оверлей Control Center: долгий тап, «+» и «Готово» ----------

%hook CCUIModularControlCenterOverlayViewController

- (void)viewDidLoad {
    %orig;
    UIView *root = self.view;

    UILongPressGestureRecognizer *lp =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(cx_longPressed:)];
    lp.minimumPressDuration = 0.9;
    lp.cancelsTouchesInView = NO;
    [root addGestureRecognizer:lp];

    UIButton *plus = CXPill(nil, @"plus", kTagPlus);
    [plus addTarget:self action:@selector(cx_plusTapped) forControlEvents:UIControlEventTouchUpInside];
    UIButton *done = CXPill(@"Готово", nil, kTagDone);
    [done addTarget:self action:@selector(cx_doneTapped) forControlEvents:UIControlEventTouchUpInside];
    [root addSubview:plus];
    [root addSubview:done];

    UILayoutGuide *g = root.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [plus.topAnchor constraintEqualToAnchor:g.topAnchor constant:8],
        [plus.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-16],
        [done.topAnchor constraintEqualToAnchor:g.topAnchor constant:8],
        [done.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:16],
    ]];
}

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    if (!self.presentedViewController) [self cx_setEditing:NO];
}

%new
- (void)cx_longPressed:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan && !gEditing) [self cx_setEditing:YES];
}

%new
- (void)cx_setEditing:(BOOL)on {
    if (gEditing == on) return;
    gEditing = on;
    UIView *root = self.view;
    for (NSNumber *t in @[@(kTagPlus), @(kTagDone)]) {
        UIView *v = [root viewWithTag:t.integerValue];
        v.hidden = !on;
        if (on) [root bringSubviewToFront:v];
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:kEditNote object:nil];
}

%new
- (void)cx_doneTapped {
    [self cx_setEditing:NO];
}

%new
- (void)cx_plusTapped {
    CXPickerController *vc = [CXPickerController new];
    vc.modalPresentationStyle = UIModalPresentationPageSheet;
    UISheetPresentationController *sheet = vc.sheetPresentationController;
    sheet.detents = @[UISheetPresentationControllerDetent.mediumDetent,
                      UISheetPresentationControllerDetent.largeDetent];
    sheet.prefersGrabberVisible = YES;
    [self presentViewController:vc animated:YES completion:nil];
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

    if (gEditing) {
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
    if (CXWriteModuleIDs(ids)) CXRespring();
}

%end
