#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "CXShared.h"
#import "CXPickerController.h"

static BOOL gEditing = NO;
static NSString *const kEditNote = @"com.ccplus.editChanged";
enum { kTagPlus = 7001, kTagDone = 7002, kTagCancel = 7003, kTagOverlay = 7010, kTagBadge = 7011 };

static char kStartTransformKey, kStartCenterKey, kGestureStoreKey;

// Прозрачный слой поверх окна Control Center: пропускает касания, кроме своих кнопок и шторки
@interface CXHostView : UIView
@end
@implementation CXHostView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    return (v == self) ? nil : v;
}
@end

// Слой поверх каждого модуля в режиме редактирования: гасит нажатия на сам модуль
@interface CXEditOverlay : UIView
@end
@implementation CXEditOverlay
@end

static CXHostView *gHost = nil;
static CXPickerController *gSheet = nil;
static NSHashTable<UIViewController *> *gContainers = nil;
static __weak UIViewController *gDragging = nil;
static NSMutableArray<UIGestureRecognizer *> *gSuspended = nil;

// На время перетаскивания отключаем жесты Control Center выше по иерархии (закрытие, прокрутку)
static void CXSuspendAncestorGestures(UIView *from, BOOL suspend) {
    if (suspend) {
        gSuspended = [NSMutableArray new];
        for (UIView *x = from; x; x = x.superview) {
            for (UIGestureRecognizer *gr in x.gestureRecognizers) {
                if (gr.enabled) { gr.enabled = NO; [gSuspended addObject:gr]; }
            }
        }
    } else {
        for (UIGestureRecognizer *gr in gSuspended) gr.enabled = YES;
        gSuspended = nil;
    }
}

@interface CCUIModularControlCenterOverlayViewController : UIViewController
- (void)cx_setEditing:(BOOL)on;
- (void)cx_plusTapped;
- (void)cx_doneTapped;
- (void)cx_cancelTapped;
- (void)cx_refreshButtons;
- (void)cx_longPressed:(UILongPressGestureRecognizer *)g;
@end

@interface CCUIContentModuleContainerViewController : UIViewController
- (NSString *)moduleIdentifier;
- (void)cx_refreshEdit;
- (void)cx_planChanged;
- (void)cx_badgeTapped;
- (void)cx_pan:(UIPanGestureRecognizer *)g;
- (void)cx_setSystemGestures:(BOOL)enable;
@end

static UIColor *CXGreen(void) {
    return [UIColor colorWithRed:0.20 green:0.78 blue:0.35 alpha:1.0];
}

static UIButton *CXPill(NSString *title, NSString *symbol, NSInteger tag) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.tag = tag;
    b.tintColor = UIColor.whiteColor;
    b.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.25];
    b.layer.cornerRadius = 16;
    b.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    b.contentEdgeInsets = UIEdgeInsetsMake(7, 16, 7, 16);
    if (symbol) [b setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
    if (title) [b setTitle:title forState:UIControlStateNormal];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    return b;
}

static void CXHaptic(void) {
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
}

// ---------- Оверлей Control Center: долгий тап, «+», «Готово / Применить», «Отмена» ----------

%hook CCUIModularControlCenterOverlayViewController

- (void)viewDidLoad {
    %orig;
    UILongPressGestureRecognizer *lp =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(cx_longPressed:)];
    lp.minimumPressDuration = 0.7;
    lp.cancelsTouchesInView = NO;
    [self.view addGestureRecognizer:lp];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(cx_refreshButtons)
                                                 name:CXPlanNote object:nil];
}

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    // Закрыли Control Center, не нажав «Применить»: изменения отменяются
    if (gEditing) {
        CXPlanReset();
        [self cx_setEditing:NO];
    }
}

%new
- (void)cx_longPressed:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan && !gEditing) {
        CXHaptic();
        [self cx_setEditing:YES];
    }
}

%new
- (void)cx_setEditing:(BOOL)on {
    if (gEditing == on) return;
    gEditing = on;
    CXInvalidateCache();
    if (!on && gSuspended) CXSuspendAncestorGestures(nil, NO);

    if (on) {
        // Кнопки живут в верхнем слое окна, поэтому ничто в Control Center их не перекроет
        UIView *parent = self.view.window ?: self.view;
        CXHostView *host = [[CXHostView alloc] initWithFrame:parent.bounds];
        host.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        host.backgroundColor = UIColor.clearColor;

        UIButton *plus = CXPill(nil, @"plus", kTagPlus);
        [plus addTarget:self action:@selector(cx_plusTapped) forControlEvents:UIControlEventTouchUpInside];
        UIButton *done = CXPill(@"Готово", nil, kTagDone);
        [done addTarget:self action:@selector(cx_doneTapped) forControlEvents:UIControlEventTouchUpInside];
        UIButton *cancel = CXPill(@"Отмена", nil, kTagCancel);
        [cancel addTarget:self action:@selector(cx_cancelTapped) forControlEvents:UIControlEventTouchUpInside];
        cancel.alpha = 0;
        [host addSubview:plus];
        [host addSubview:done];
        [host addSubview:cancel];

        UILayoutGuide *g = host.safeAreaLayoutGuide;
        [NSLayoutConstraint activateConstraints:@[
            [plus.topAnchor constraintEqualToAnchor:g.topAnchor constant:8],
            [plus.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-16],
            [done.topAnchor constraintEqualToAnchor:g.topAnchor constant:8],
            [done.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:16],
            [cancel.topAnchor constraintEqualToAnchor:g.topAnchor constant:8],
            [cancel.leadingAnchor constraintEqualToAnchor:done.trailingAnchor constant:8],
        ]];

        host.alpha = 0;
        [parent addSubview:host];
        gHost = host;
        [self cx_refreshButtons];
        [UIView animateWithDuration:0.25 animations:^{ host.alpha = 1; }];
    } else {
        if (gSheet) [gSheet closeSheet];
        CXHostView *old = gHost;
        gHost = nil;
        [UIView animateWithDuration:0.18 animations:^{ old.alpha = 0; }
                         completion:^(BOOL f) { [old removeFromSuperview]; }];
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:kEditNote object:nil];
}

%new
- (void)cx_refreshButtons {
    if (!gHost) return;
    UIButton *done = (UIButton *)[gHost viewWithTag:kTagDone];
    UIButton *cancel = (UIButton *)[gHost viewWithTag:kTagCancel];
    BOOL pend = CXPlanHasChanges();
    NSString *title = pend ? [NSString stringWithFormat:@"Применить (%lu)", (unsigned long)CXPlanCount()] : @"Готово";

    [UIView performWithoutAnimation:^{
        [done setTitle:title forState:UIControlStateNormal];
        [done layoutIfNeeded];
    }];
    [UIView animateWithDuration:0.22 animations:^{
        done.backgroundColor = pend ? CXGreen() : [UIColor colorWithWhite:1.0 alpha:0.25];
        cancel.alpha = pend ? 1.0 : 0.0;
    }];
    cancel.userInteractionEnabled = pend;
}

%new
- (void)cx_doneTapped {
    if (CXPlanHasChanges()) {
        UIButton *done = (UIButton *)[gHost viewWithTag:kTagDone];
        done.userInteractionEnabled = NO;
        [done setTitle:@"Применяю…" forState:UIControlStateNormal];
        CXPlanCommit();        // запись + респринг
        return;
    }
    [self cx_setEditing:NO];
}

%new
- (void)cx_cancelTapped {
    CXHaptic();
    CXPlanReset();
}

%new
- (void)cx_plusTapped {
    if (!gHost || gSheet) return;
    CXHaptic();
    CXPickerController *vc = [CXPickerController new];
    vc.onClose = ^{ gSheet = nil; };
    gSheet = vc;
    [vc showInView:gHost parent:self];
}

%end

// ---------- Контейнер каждого модуля: слой редактирования, «−», покачивание, перетаскивание ----------

%hook CCUIContentModuleContainerViewController

- (void)viewDidLoad {
    %orig;
    if (!gContainers) gContainers = [NSHashTable weakObjectsHashTable];
    [gContainers addObject:self];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(cx_refreshEdit)
                                                 name:kEditNote object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(cx_planChanged)
                                                 name:CXPlanNote object:nil];
}

- (void)viewDidLayoutSubviews {
    %orig;
    [self cx_refreshEdit];
}

%new
- (void)cx_refreshEdit {
    if (![self respondsToSelector:@selector(moduleIdentifier)] || !self.isViewLoaded) return;
    NSString *ident = [self moduleIdentifier];
    if (!ident) return;

    UIView *v = self.view;
    UIView *ov = [v viewWithTag:kTagOverlay];

    // --- выход из режима редактирования ---
    if (!gEditing) {
        if (ov) {
            [v.layer removeAnimationForKey:@"cx_wobble"];
            [self cx_setSystemGestures:YES];
            [UIView animateWithDuration:0.2 animations:^{
                ov.alpha = 0;
                v.alpha = 1;
                v.transform = CGAffineTransformIdentity;
            } completion:^(BOOL f) { [ov removeFromSuperview]; }];
        }
        return;
    }

    BOOL removable = CXIsRemovable(ident);
    BOOL removed = CXPlanIsRemoved(ident);

    // --- слой редактирования ---
    if (!ov) {
        [self cx_setSystemGestures:NO];

        ov = [[CXEditOverlay alloc] initWithFrame:v.bounds];
        ov.tag = kTagOverlay;
        ov.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        ov.backgroundColor = UIColor.clearColor;
        ov.alpha = 0;

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(cx_pan:)];
        pan.maximumNumberOfTouches = 1;
        [ov addGestureRecognizer:pan];

        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.tag = kTagBadge;
        b.frame = CGRectMake(0, 0, 40, 40);    // большая зона нажатия, чтобы легко попадать по «−»
        b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        b.contentVerticalAlignment = UIControlContentVerticalAlignmentTop;
        b.contentEdgeInsets = UIEdgeInsetsMake(4, 4, 0, 0);
        [b addTarget:self action:@selector(cx_badgeTapped) forControlEvents:UIControlEventTouchUpInside];
        [ov addSubview:b];

        [v addSubview:ov];
        [UIView animateWithDuration:0.2 animations:^{ ov.alpha = 1; }];
    }
    [v bringSubviewToFront:ov];

    // --- значок «−» / «вернуть» ---
    UIButton *badge = (UIButton *)[ov viewWithTag:kTagBadge];
    badge.hidden = !removable;
    NSString *sym = removed ? @"arrow.uturn.backward.circle.fill" : @"minus.circle.fill";
    if (![badge.accessibilityIdentifier isEqualToString:sym]) {
        UIImageSymbolConfiguration *cfg =
            [UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightBold];
        [badge setImage:[UIImage systemImageNamed:sym withConfiguration:cfg] forState:UIControlStateNormal];
        badge.tintColor = removed ? CXGreen() : UIColor.whiteColor;
        BOOL first = (badge.accessibilityIdentifier == nil);
        badge.accessibilityIdentifier = sym;
        if (!first) {
            badge.transform = CGAffineTransformMakeScale(0.4, 0.4);
            [UIView animateWithDuration:0.4 delay:0 usingSpringWithDamping:0.55 initialSpringVelocity:0.8
                                options:0 animations:^{ badge.transform = CGAffineTransformIdentity; } completion:nil];
        }
    }

    // --- убранный модуль тускнеет ---
    CGFloat targetAlpha = removed ? 0.3 : 1.0;
    if (fabs(v.alpha - targetAlpha) > 0.01) {
        [UIView animateWithDuration:0.25 animations:^{ v.alpha = targetAlpha; }];
    }

    // --- покачивание, как на домашнем экране ---
    BOOL shouldWobble = removable && !removed && gDragging != self;
    if (shouldWobble && ![v.layer animationForKey:@"cx_wobble"]) {
        CABasicAnimation *w = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
        w.fromValue = @(-0.014);
        w.toValue = @(0.014);
        w.duration = 0.13;
        w.autoreverses = YES;
        w.repeatCount = HUGE_VALF;
        w.timeOffset = (arc4random_uniform(100)) / 1000.0;
        [v.layer addAnimation:w forKey:@"cx_wobble"];
    } else if (!shouldWobble) {
        [v.layer removeAnimationForKey:@"cx_wobble"];
    }
}

%new
- (void)cx_planChanged {
    [self cx_refreshEdit];
    // После «Отмены» модули плавно возвращаются на свои места
    if (gEditing && !CXPlanOrder() && gDragging != self && self.isViewLoaded) {
        UIView *v = self.view;
        if (!CGAffineTransformIsIdentity(v.transform)) {
            [UIView animateWithDuration:0.5 delay:0 usingSpringWithDamping:0.85 initialSpringVelocity:0.2
                                options:UIViewAnimationOptionAllowUserInteraction
                             animations:^{ v.transform = CGAffineTransformIdentity; } completion:nil];
        }
    }
}

%new
- (void)cx_badgeTapped {
    NSString *ident = [self moduleIdentifier];
    if (!ident || !CXIsRemovable(ident)) return;
    CXHaptic();
    CXPlanToggleRemove(ident);
}

%new
- (void)cx_setSystemGestures:(BOOL)enable {
    // На время редактирования отключаем системные жесты модуля (раскрытие по долгому нажатию и т.п.)
    UIView *v = self.view;
    if (!enable) {
        NSMutableArray *disabled = [NSMutableArray new];
        NSMutableArray *views = [NSMutableArray arrayWithObject:v];
        [views addObjectsFromArray:v.subviews];
        for (UIView *x in views) {
            if ([x isKindOfClass:CXEditOverlay.class]) continue;
            for (UIGestureRecognizer *gr in x.gestureRecognizers) {
                if (gr.enabled) { gr.enabled = NO; [disabled addObject:gr]; }
            }
        }
        objc_setAssociatedObject(self, &kGestureStoreKey, disabled, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        NSArray *disabled = objc_getAssociatedObject(self, &kGestureStoreKey);
        for (UIGestureRecognizer *gr in disabled) gr.enabled = YES;
        objc_setAssociatedObject(self, &kGestureStoreKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

%new
- (void)cx_pan:(UIPanGestureRecognizer *)g {
    UIView *v = self.view;
    UIView *sup = v.superview;
    NSString *ident = [self moduleIdentifier];
    if (!sup || !ident) return;

    if (g.state == UIGestureRecognizerStateBegan) {
        if (!CXIsMovable(ident) || CXPlanIsRemoved(ident)) {
            g.enabled = NO;     // сбрасываем жест: этот модуль двигать нельзя
            g.enabled = YES;
            return;
        }
        gDragging = self;
        objc_setAssociatedObject(self, &kStartTransformKey,
                                 [NSValue valueWithCGAffineTransform:v.transform], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, &kStartCenterKey,
                                 [NSValue valueWithCGPoint:CGPointMake(CGRectGetMidX(v.frame), CGRectGetMidY(v.frame))],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [v.layer removeAnimationForKey:@"cx_wobble"];
        [sup bringSubviewToFront:v];
        CXSuspendAncestorGestures(sup, YES);
        CXHaptic();
        return;
    }

    if (gDragging != self) return;
    CGAffineTransform start = [objc_getAssociatedObject(self, &kStartTransformKey) CGAffineTransformValue];

    if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [g translationInView:sup];
        CGAffineTransform tr = CGAffineTransformTranslate(start, t.x, t.y);
        v.transform = CGAffineTransformScale(tr, 1.07, 1.07);
        return;
    }

    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled ||
        g.state == UIGestureRecognizerStateFailed) {
        gDragging = nil;
        CXSuspendAncestorGestures(nil, NO);
        CGPoint origC = [objc_getAssociatedObject(self, &kStartCenterKey) CGPointValue];
        CGPoint c = CGPointMake(CGRectGetMidX(v.frame), CGRectGetMidY(v.frame));

        // Ищем модуль, на который отпустили палец
        CCUIContentModuleContainerViewController *target = nil;
        NSString *targetIdent = nil;
        for (UIViewController *o in gContainers.allObjects) {
            if (o == self || !o.isViewLoaded || o.view.superview != sup) continue;
            CCUIContentModuleContainerViewController *oc = (CCUIContentModuleContainerViewController *)o;
            NSString *oid = [oc moduleIdentifier];
            if (oid && CXIsMovable(oid) && !CXPlanIsRemoved(oid) && CGRectContainsPoint(o.view.frame, c)) {
                target = oc;
                targetIdent = oid;
                break;
            }
        }

        BOOL swapped = NO;
        if (target && g.state == UIGestureRecognizerStateEnded) {
            NSMutableArray *order = [(CXPlanOrder() ?: CXUserOrder()) mutableCopy];
            NSUInteger iD = [order indexOfObject:ident];
            NSUInteger iT = [order indexOfObject:targetIdent];
            if (iD != NSNotFound && iT != NSNotFound && iD != iT) {
                UIView *tv = target.view;
                CGPoint oC = CGPointMake(CGRectGetMidX(tv.frame), CGRectGetMidY(tv.frame));
                CGAffineTransform tOld = tv.transform;

                [order removeObjectAtIndex:iD];
                [order insertObject:ident atIndex:iT];
                CXPlanSetOrder(order);

                [UIView animateWithDuration:0.55 delay:0 usingSpringWithDamping:0.78 initialSpringVelocity:0.3
                                    options:UIViewAnimationOptionAllowUserInteraction animations:^{
                    v.transform = CGAffineTransformTranslate(start, oC.x - origC.x, oC.y - origC.y);
                    tv.transform = CGAffineTransformTranslate(tOld, origC.x - oC.x, origC.y - oC.y);
                } completion:nil];
                swapped = YES;
            }
        }
        if (!swapped) {
            [UIView animateWithDuration:0.45 delay:0 usingSpringWithDamping:0.82 initialSpringVelocity:0.2
                                options:UIViewAnimationOptionAllowUserInteraction
                             animations:^{ v.transform = start; } completion:nil];
        }
        CXHaptic();
        [self cx_refreshEdit];    // вернуть покачивание
    }
}

%end
