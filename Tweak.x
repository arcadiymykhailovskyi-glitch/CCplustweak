#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "CXShared.h"
#import "CXPickerController.h"

static BOOL gEditing = NO;
static NSString *const kEditNote = @"com.ccplus.editChanged";
enum { kTagPlus = 7001, kTagDone = 7002, kTagCancel = 7003, kTagOverlay = 7010, kTagBadge = 7011 };

static char kGestureStoreKey;

static CXPickerController *gSheet = nil;
static NSHashTable<UIViewController *> *gContainers = nil;
static __weak UIViewController *gDragging = nil;
static NSMutableArray<UIGestureRecognizer *> *gSuspended = nil;

// Состояние перетаскивания (одновременно двигается только один модуль)
static CGAffineTransform gDragBase;
static CGPoint gDragStartCenter, gDragHome, gDragLoc0;
static __weak UILongPressGestureRecognizer *gDragGR = nil;
static CADisplayLink *gDragLink = nil;
static __weak UIScrollView *gDragScroll = nil;

// Страницы и точки-индикатор
static char kSnapKey, kTopFixKey;
static CADisplayLink *gPagerLink = nil;
static NSInteger gDotsCount = 0, gDotsCurrent = -1;

// Прозрачный слой, который не перехватывает касания
@interface CXPassView : UIView
@end
@implementation CXPassView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    return (v == self) ? nil : v;
}
@end
static CXPassView *gDotsHost = nil;

// Слой редактирования поверх каждого модуля: гасит нажатия на сам модуль
@interface CXEditOverlay : UIView
@end
@implementation CXEditOverlay
@end

// Есть ли под пальцем слой редактирования какого-нибудь модуля
static BOOL CXPointInsideModule(UIView *host, CGPoint p) {
    for (UIViewController *o in gContainers.allObjects) {
        if (!o.isViewLoaded) continue;
        UIView *ov = [o.view viewWithTag:kTagOverlay];
        if (!ov || !ov.window || ov.hidden || ov.alpha < 0.01) continue;
        CGPoint q = [host convertPoint:p toView:ov];
        if ([ov pointInside:q withEvent:nil]) return YES;
    }
    return NO;
}

// Прозрачный слой поверх окна Control Center. Пропускает касания только к своим кнопкам,
// шторке и модулям. Касания в пустом месте «съедает», чтобы Control Center не закрылся резко:
// тап по пустому месту плавно выходит из режима редактирования.
@interface CXHostView : UIView <UIGestureRecognizerDelegate>
@end
@implementation CXHostView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    if (v != self) return v;
    if (!gEditing) return nil;
    if (CXPointInsideModule(self, point)) return nil;   // отдаём касание слою редактирования модуля
    return self;
}
// Жесты этого слоя реагируют только на касания «в пустоту»
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gr shouldReceiveTouch:(UITouch *)touch {
    return touch.view == self;
}
@end

static CXHostView *gHost = nil;

// Пока идёт редактирование, отключаем жесты Control Center (закрытие свайпом или тапом),
// но оставляем прокрутку, чтобы страницу можно было листать вверх и вниз.
static void CXAddChain(UIView *from, NSMutableOrderedSet<UIView *> *views) {
    for (UIView *x = from; x; x = x.superview) [views addObject:x];
}

static void CXSuspendCCGestures(UIView *rootView, BOOL suspend) {
    if (suspend) {
        if (gSuspended) return;
        NSMutableOrderedSet<UIView *> *views = [NSMutableOrderedSet new];
        CXAddChain(rootView, views);
        for (UIViewController *o in gContainers.allObjects) {
            if (o.isViewLoaded) CXAddChain(o.view.superview, views);
        }
        gSuspended = [NSMutableArray new];
        for (UIView *x in views) {
            UIScrollView *sv = [x isKindOfClass:UIScrollView.class] ? (UIScrollView *)x : nil;
            for (UIGestureRecognizer *gr in x.gestureRecognizers) {
                if (sv && (gr == sv.panGestureRecognizer || gr == sv.pinchGestureRecognizer)) continue;
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
- (void)cx_emptyTapped;
- (void)cx_hostPan:(UIPanGestureRecognizer *)g;
- (void)cx_pagerTick:(CADisplayLink *)link;
- (void)cx_scrollPan:(UIPanGestureRecognizer *)g;
- (void)cx_refreshButtons;
- (void)cx_longPressed:(UILongPressGestureRecognizer *)g;
@end

@interface CCUIContentModuleContainerViewController : UIViewController
- (NSString *)moduleIdentifier;
- (void)cx_refreshEdit;
- (void)cx_planChanged;
- (void)cx_badgeTapped;
- (void)cx_pan:(UILongPressGestureRecognizer *)g;
- (void)cx_dragTick:(CADisplayLink *)link;
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

// Модуль сейчас показан на экране
static BOOL CXIsShown(NSString *ident) {
    for (UIViewController *o in gContainers.allObjects) {
        if (!o.isViewLoaded || !o.view.window) continue;
        CCUIContentModuleContainerViewController *c = (CCUIContentModuleContainerViewController *)o;
        if ([[c moduleIdentifier] isEqualToString:ident]) return YES;
    }
    return NO;
}

// Запасной вариант: плавно гасим экран и перезапускаем SpringBoard
static void CXSmoothRespring(void) {
    UIView *w = gHost.window;
    [UIView animateWithDuration:0.3 animations:^{ w.alpha = 0; }];
    CXRespringNow();
}

static UIScrollView *CXFindScrollView(void) {
    for (UIViewController *o in gContainers.allObjects) {
        if (!o.isViewLoaded) continue;
        for (UIView *x = o.view.superview; x; x = x.superview) {
            if ([x isKindOfClass:UIScrollView.class] && x.window) return (UIScrollView *)x;
        }
    }
    return nil;
}

// Рамка модуля без учёта временных сдвигов (transform), то есть его «настоящее» место
static CGRect CXBaseFrame(UIView *v) {
    CGSize sz = v.bounds.size;
    CGPoint c = v.center;
    return CGRectMake(c.x - sz.width / 2, c.y - sz.height / 2, sz.width, sz.height);
}

// Порядок модулей на экране: сверху вниз, слева направо (только те, которые можно двигать)
static NSArray<NSString *> *CXVisualOrder(UIView *sup) {
    NSMutableArray<NSDictionary *> *items = [NSMutableArray new];
    for (UIViewController *o in gContainers.allObjects) {
        if (!o.isViewLoaded || o.view.superview != sup) continue;
        NSString *oid = [(CCUIContentModuleContainerViewController *)o moduleIdentifier];
        if (!oid || !CXIsRemovable(oid) || CXPlanIsRemoved(oid)) continue;
        CGRect f = CXBaseFrame(o.view);
        [items addObject:@{ @"id": oid, @"y": @(round(f.origin.y)), @"x": @(f.origin.x) }];
    }
    [items sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSComparisonResult r = [a[@"y"] compare:b[@"y"]];
        return r != NSOrderedSame ? r : [a[@"x"] compare:b[@"x"]];
    }];
    NSMutableArray *ids = [NSMutableArray new];
    for (NSDictionary *d in items) [ids addObject:d[@"id"]];
    return ids;
}

// Смещения прокрутки, на которых «останавливается» каждая страница.
// Страницы набираются из целых рядов модулей, чтобы ничего не обрезалось по краям.
static NSArray<NSNumber *> *CXPageOffsets(UIScrollView *sv) {
    NSMutableArray<NSValue *> *frames = [NSMutableArray new];
    for (UIViewController *o in gContainers.allObjects) {
        if (!o.isViewLoaded || !o.view.window || !o.view.superview) continue;
        CGRect f = [o.view.superview convertRect:CXBaseFrame(o.view) toView:sv];
        [frames addObject:[NSValue valueWithCGRect:f]];
    }
    CGFloat minOff = -sv.adjustedContentInset.top;
    if (frames.count < 2) return @[@(minOff)];
    [frames sortUsingComparator:^NSComparisonResult(NSValue *a, NSValue *b) {
        return [@(a.CGRectValue.origin.y) compare:@(b.CGRectValue.origin.y)];
    }];

    CGFloat maxOff = MAX(minOff, sv.contentSize.height - sv.bounds.size.height + sv.adjustedContentInset.bottom);
    CGFloat viewH = sv.bounds.size.height - sv.adjustedContentInset.top - sv.adjustedContentInset.bottom;
    CGFloat firstY = frames.firstObject.CGRectValue.origin.y;
    CGFloat pad = MAX(firstY - minOff, 0);
    CGFloat available = viewH - pad - 16;

    NSMutableArray<NSNumber *> *offs = [NSMutableArray arrayWithObject:@(minOff)];
    CGFloat start = firstY;
    for (NSValue *v in frames) {
        CGRect f = v.CGRectValue;
        if (CGRectGetMaxY(f) - start > available && f.origin.y > start + 1) {
            start = f.origin.y;
            CGFloat off = MAX(minOff, MIN(maxOff, start - pad));
            if (fabs(off - offs.lastObject.doubleValue) > 2) [offs addObject:@(off)];
        }
    }
    return offs;
}

static NSInteger CXNearestIndex(NSArray<NSNumber *> *offs, CGFloat y) {
    NSInteger best = 0;
    CGFloat bd = CGFLOAT_MAX;
    for (NSInteger i = 0; i < (NSInteger)offs.count; i++) {
        CGFloat d = fabs(offs[i].doubleValue - y);
        if (d < bd) { bd = d; best = i; }
    }
    return best;
}

// Плавно «доводит» прокрутку до ближайшей страницы
static void CXSnapScroll(UIScrollView *sv, CGFloat vy) {
    NSArray<NSNumber *> *offs = CXPageOffsets(sv);
    if (offs.count < 2) return;
    NSInteger cur = CXNearestIndex(offs, sv.contentOffset.y);
    NSInteger idx = CXNearestIndex(offs, sv.contentOffset.y - vy * 0.15);
    idx = MAX(cur - 1, MIN(cur + 1, idx));                 // за раз не больше одной страницы
    CGFloat target = offs[idx].doubleValue;

    [sv setContentOffset:sv.contentOffset animated:NO];   // останавливаем инерцию
    [UIView animateWithDuration:0.45 delay:0 usingSpringWithDamping:0.92 initialSpringVelocity:0
                        options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{ sv.contentOffset = CGPointMake(sv.contentOffset.x, target); }
                     completion:nil];
}

// Если ряды модулей упираются в верхний край, добавляем отступ сверху, чтобы они не залезали под статус-бар
static void CXEnsureTopPadding(UIScrollView *sv) {
    if (objc_getAssociatedObject(sv, &kTopFixKey)) return;
    NSArray<NSNumber *> *offs = CXPageOffsets(sv);
    if (offs.count < 2) return;
    objc_setAssociatedObject(sv, &kTopFixKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    CGFloat minOff = -sv.adjustedContentInset.top;
    CGFloat firstY = CGFLOAT_MAX;
    for (UIViewController *o in gContainers.allObjects) {
        if (!o.isViewLoaded || !o.view.window || !o.view.superview) continue;
        CGRect f = [o.view.superview convertRect:CXBaseFrame(o.view) toView:sv];
        firstY = MIN(firstY, f.origin.y);
    }
    CGFloat minPad = MAX(sv.window.safeAreaInsets.top, 20) + 14;
    CGFloat deficit = minPad - (firstY - minOff);
    if (deficit > 1) {
        BOOL atTop = sv.contentOffset.y <= minOff + 1;
        UIEdgeInsets i = sv.contentInset;
        i.top += deficit;
        sv.contentInset = i;
        if (atTop) sv.contentOffset = CGPointMake(sv.contentOffset.x, -sv.adjustedContentInset.top);
    }
}

// Вертикальные точки справа: на какой странице мы сейчас
static void CXUpdateDots(NSInteger count, NSInteger current) {
    if (!gDotsHost) return;
    if (count < 2) {
        if (gDotsHost.alpha > 0.01) [UIView animateWithDuration:0.2 animations:^{ gDotsHost.alpha = 0; }];
        gDotsCount = count;
        return;
    }
    if (gDotsHost.alpha < 0.99) [UIView animateWithDuration:0.2 animations:^{ gDotsHost.alpha = 1; }];

    if (count != gDotsCount) {
        for (UIView *sub in [gDotsHost.subviews copy]) [sub removeFromSuperview];
        CGFloat d = 7, gap = 10;
        CGFloat total = count * d + (count - 1) * gap;
        CGFloat W = gDotsHost.bounds.size.width, H = gDotsHost.bounds.size.height;
        for (NSInteger i = 0; i < count; i++) {
            UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(W - 7 - d, (H - total) / 2 + i * (d + gap), d, d)];
            dot.layer.cornerRadius = d / 2;
            dot.backgroundColor = UIColor.whiteColor;
            dot.alpha = 0.35;
            dot.tag = 100 + i;
            [gDotsHost addSubview:dot];
        }
        gDotsCount = count;
        gDotsCurrent = -1;
    }
    if (current != gDotsCurrent) {
        for (NSInteger i = 0; i < count; i++) {
            UIView *dot = [gDotsHost viewWithTag:100 + i];
            BOOL on = (i == current);
            [UIView animateWithDuration:0.25 animations:^{
                dot.alpha = on ? 1.0 : 0.35;
                dot.transform = on ? CGAffineTransformMakeScale(1.35, 1.35) : CGAffineTransformIdentity;
            }];
        }
        gDotsCurrent = current;
    }
}

// Один «кадр» перетаскивания: палец ведёт модуль, а модуль под ним уступает место
static void CXUpdateDrag(CCUIContentModuleContainerViewController *vc) {
    UILongPressGestureRecognizer *g = gDragGR;
    UIView *v = vc.view;
    UIView *sup = v.superview;
    if (!g || !sup) return;

    CGPoint loc = [g locationInView:sup];
    CGAffineTransform tr = CGAffineTransformTranslate(gDragBase, loc.x - gDragLoc0.x, loc.y - gDragLoc0.y);
    v.transform = CGAffineTransformScale(tr, 1.07, 1.07);

    NSString *ident = [vc moduleIdentifier];
    CGPoint c = CGPointMake(CGRectGetMidX(v.frame), CGRectGetMidY(v.frame));
    for (UIViewController *o in gContainers.allObjects) {
        if (o == vc || !o.isViewLoaded || o.view.superview != sup) continue;
        CCUIContentModuleContainerViewController *oc = (CCUIContentModuleContainerViewController *)o;
        NSString *oid = [oc moduleIdentifier];
        if (!oid || !CXIsRemovable(oid) || CXPlanIsRemoved(oid)) continue;

        CGRect f = o.view.frame;
        if (!CGRectContainsPoint(CGRectInset(f, f.size.width * 0.18, f.size.height * 0.18), c)) continue;

        NSMutableArray *order = [(CXPlanOrder() ?: CXVisualOrder(sup)) mutableCopy];
        NSUInteger iD = [order indexOfObject:ident];
        NSUInteger iT = [order indexOfObject:oid];
        if (iD == NSNotFound || iT == NSNotFound || iD == iT) continue;

        // Поменялись местами: модуль под пальцем плавно уезжает на освободившееся место
        CGPoint oC = CGPointMake(CGRectGetMidX(f), CGRectGetMidY(f));
        CGAffineTransform tOld = o.view.transform;
        [order removeObjectAtIndex:iD];
        [order insertObject:ident atIndex:iT];
        CXPlanSetOrder(order);

        CGPoint home = gDragHome;
        gDragHome = oC;
        UIView *ov = o.view;
        [UIView animateWithDuration:0.45 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0.3
                            options:UIViewAnimationOptionAllowUserInteraction
                         animations:^{ ov.transform = CGAffineTransformTranslate(tOld, home.x - oC.x, home.y - oC.y); }
                         completion:nil];
        [[[UISelectionFeedbackGenerator alloc] init] selectionChanged];
        break;
    }
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

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    UIView *parent = self.view.window;
    if (!parent) return;
    if (!gDotsHost || gDotsHost.superview != parent) {
        [gDotsHost removeFromSuperview];
        gDotsHost = [[CXPassView alloc] initWithFrame:parent.bounds];
        gDotsHost.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        gDotsHost.alpha = 0;
        [parent addSubview:gDotsHost];
    }
    gDotsCount = 0;
    gDotsCurrent = -1;
    if (!gPagerLink) {
        gPagerLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(cx_pagerTick:)];
        gPagerLink.preferredFramesPerSecond = 20;
        [gPagerLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    [gPagerLink invalidate];
    gPagerLink = nil;
    UIView *dots = gDotsHost;
    gDotsHost = nil;
    [UIView animateWithDuration:0.2 animations:^{ dots.alpha = 0; } completion:^(BOOL f) { [dots removeFromSuperview]; }];
    // Control Center закрыли (например, кнопкой Home), не нажав «Применить»: изменения отменяются
    if (gEditing) {
        CXPlanReset();
        [self cx_setEditing:NO];
    }
}

%new
- (void)cx_pagerTick:(CADisplayLink *)link {
    UIScrollView *sv = CXFindScrollView();
    if (!sv) { CXUpdateDots(0, 0); return; }

    // Один раз на каждую прокрутку: быстрое торможение и «доводчик» до страниц
    if (!objc_getAssociatedObject(sv, &kSnapKey)) {
        objc_setAssociatedObject(sv, &kSnapKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        sv.decelerationRate = UIScrollViewDecelerationRateFast;
        [sv.panGestureRecognizer addTarget:self action:@selector(cx_scrollPan:)];
    }
    CXEnsureTopPadding(sv);

    NSArray<NSNumber *> *offs = CXPageOffsets(sv);
    CXUpdateDots(offs.count, CXNearestIndex(offs, sv.contentOffset.y));
}

%new
- (void)cx_scrollPan:(UIPanGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateEnded && g.state != UIGestureRecognizerStateCancelled) return;
    UIScrollView *sv = (UIScrollView *)g.view;
    if (![sv isKindOfClass:UIScrollView.class] || gDragging) return;
    CGFloat vy = [g velocityInView:sv].y;
    dispatch_async(dispatch_get_main_queue(), ^{ CXSnapScroll(sv, vy); });
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
    if (!on) CXSuspendCCGestures(nil, NO);

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

        // Тап по пустому месту: плавный выход из редактирования. Свайп по пустому месту: прокрутка.
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(cx_emptyTapped)];
        tap.delegate = host;
        [host addGestureRecognizer:tap];
        UIPanGestureRecognizer *hp = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(cx_hostPan:)];
        hp.delegate = host;
        [host addGestureRecognizer:hp];

        host.alpha = 0;
        [parent addSubview:host];
        gHost = host;
        CXSuspendCCGestures(self.view, YES);
        [self cx_refreshButtons];
        [UIView animateWithDuration:0.28 delay:0 options:UIViewAnimationOptionCurveEaseOut
                         animations:^{ host.alpha = 1; } completion:nil];
    } else {
        if (gSheet) [gSheet closeSheet];
        CXHostView *old = gHost;
        gHost = nil;
        [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseInOut
                         animations:^{ old.alpha = 0; }
                         completion:^(BOOL f) { [old removeFromSuperview]; }];
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:kEditNote object:nil];
}

%new
- (void)cx_emptyTapped {
    if (gSheet) return;
    if (CXPlanHasChanges()) {
        // Есть неприменённые изменения: мягко «встряхиваем» кнопки вместо того, чтобы что-то терять
        for (NSNumber *t in @[@(kTagDone), @(kTagCancel)]) {
            UIView *b = [gHost viewWithTag:t.integerValue];
            CAKeyframeAnimation *a = [CAKeyframeAnimation animationWithKeyPath:@"transform.translation.x"];
            a.values = @[@0, @-7, @7, @-5, @5, @0];
            a.duration = 0.35;
            [b.layer addAnimation:a forKey:@"cx_shake"];
        }
        CXHaptic();
        return;
    }
    [self cx_setEditing:NO];
}

%new
- (void)cx_hostPan:(UIPanGestureRecognizer *)g {
    static CGFloat startY = 0;
    UIScrollView *sv = CXFindScrollView();
    if (!sv) return;
    if (g.state == UIGestureRecognizerStateBegan) {
        startY = sv.contentOffset.y;
    } else if (g.state == UIGestureRecognizerStateChanged) {
        CGFloat minY = -sv.adjustedContentInset.top;
        CGFloat maxY = MAX(minY, sv.contentSize.height - sv.bounds.size.height + sv.adjustedContentInset.bottom);
        CGFloat y = startY - [g translationInView:g.view].y;
        sv.contentOffset = CGPointMake(sv.contentOffset.x, MAX(minY, MIN(maxY, y)));
    }
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
    if (!CXPlanHasChanges()) {
        [self cx_setEditing:NO];
        return;
    }

    UIButton *done = (UIButton *)[gHost viewWithTag:kTagDone];
    UIButton *cancel = (UIButton *)[gHost viewWithTag:kTagCancel];
    done.userInteractionEnabled = NO;
    cancel.userInteractionEnabled = NO;
    [UIView performWithoutAnimation:^{
        [done setTitle:@"Применяю…" forState:UIControlStateNormal];
        [done layoutIfNeeded];
    }];

    NSArray<NSString *> *removed = CXPlanRemovedList();
    NSArray<NSString *> *added = CXPlanAddedList();

    // Порядок модулей без респринга не обновить. Остальное пробуем применить «вживую».
    if (CXPlanApplyLive()) {
        CXSmoothRespring();
        return;
    }

    __weak CCUIModularControlCenterOverlayViewController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        BOOL ok = YES;
        for (NSString *r in removed) if (CXIsShown(r)) ok = NO;
        for (NSString *a in added) if (!CXIsShown(a)) ok = NO;
        if (ok) {
            CXPlanClear();                 // всё применилось без респринга
            CXHaptic();
            [weakSelf cx_setEditing:NO];
        } else {
            CXSmoothRespring();            // живое обновление не сработало: перезапуск, как раньше
        }
    });
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
            [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
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

        // Зажать и перетащить; быстрый свайп по модулю листает страницу
        UILongPressGestureRecognizer *drag = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(cx_pan:)];
        drag.minimumPressDuration = 0.2;
        drag.allowableMovement = 14;
        [ov addGestureRecognizer:drag];

        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.tag = kTagBadge;
        b.frame = CGRectMake(0, 0, 40, 40);    // большая зона нажатия, чтобы легко попадать по «−»
        b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        b.contentVerticalAlignment = UIControlContentVerticalAlignmentTop;
        b.contentEdgeInsets = UIEdgeInsetsMake(4, 4, 0, 0);
        [b addTarget:self action:@selector(cx_badgeTapped) forControlEvents:UIControlEventTouchUpInside];
        [ov addSubview:b];

        [v addSubview:ov];
        [UIView animateWithDuration:0.25 animations:^{ ov.alpha = 1; }];
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
- (void)cx_pan:(UILongPressGestureRecognizer *)g {
    UIView *v = self.view;
    UIView *sup = v.superview;
    NSString *ident = [self moduleIdentifier];
    if (!sup || !ident) return;

    if (g.state == UIGestureRecognizerStateBegan) {
        if (!CXIsRemovable(ident) || CXPlanIsRemoved(ident)) {
            g.enabled = NO;     // сбрасываем жест: этот модуль двигать нельзя (он фиксированный)
            g.enabled = YES;
            return;
        }
        gDragging = self;
        gDragGR = g;
        gDragBase = v.transform;
        gDragStartCenter = CGPointMake(CGRectGetMidX(v.frame), CGRectGetMidY(v.frame));
        gDragHome = gDragStartCenter;
        gDragLoc0 = [g locationInView:sup];
        gDragScroll = CXFindScrollView();
        gDragScroll.scrollEnabled = NO;          // пока тащим модуль, страница не должна ехать сама по себе
        [v.layer removeAnimationForKey:@"cx_wobble"];
        [sup bringSubviewToFront:v];
        CXHaptic();

        gDragLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(cx_dragTick:)];
        [gDragLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        CCUIContentModuleContainerViewController *me = (CCUIContentModuleContainerViewController *)self;
        [UIView animateWithDuration:0.2 animations:^{ CXUpdateDrag(me); }];   // модуль «приподнимается»
        return;
    }

    if (gDragging != self) return;

    if (g.state == UIGestureRecognizerStateChanged) {
        CXUpdateDrag((CCUIContentModuleContainerViewController *)self);
        return;
    }

    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled ||
        g.state == UIGestureRecognizerStateFailed) {
        gDragging = nil;
        [gDragLink invalidate];
        gDragLink = nil;
        UIScrollView *dragSV = gDragScroll;
        dragSV.scrollEnabled = YES;
        gDragScroll = nil;
        gDragGR = nil;
        if (dragSV) CXSnapScroll(dragSV, 0);

        // Модуль плавно «садится» на своё (возможно, новое) место
        CGAffineTransform end = CGAffineTransformTranslate(gDragBase, gDragHome.x - gDragStartCenter.x,
                                                           gDragHome.y - gDragStartCenter.y);
        [UIView animateWithDuration:0.45 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0.3
                            options:UIViewAnimationOptionAllowUserInteraction
                         animations:^{ v.transform = end; } completion:nil];
        CXHaptic();
        [self cx_refreshEdit];    // вернуть покачивание
    }
}

%new
- (void)cx_dragTick:(CADisplayLink *)link {
    if (gDragging != self) { [link invalidate]; return; }

    // Автопрокрутка страницы, когда модуль подтащили к верхнему или нижнему краю
    UIScrollView *sv = gDragScroll;
    UILongPressGestureRecognizer *g = gDragGR;
    if (sv && g) {
        CGFloat H = sv.window.bounds.size.height;
        CGFloat y = [g locationInView:nil].y;
        CGFloat speed = 0;
        if (y > H - 110) speed = (y - (H - 110)) / 110.0 * 14.0;
        else if (y < 120) speed = -((120.0 - y) / 120.0) * 14.0;
        if (fabs(speed) > 0.5) {
            CGFloat minY = -sv.adjustedContentInset.top;
            CGFloat maxY = MAX(minY, sv.contentSize.height - sv.bounds.size.height + sv.adjustedContentInset.bottom);
            CGFloat ny = MAX(minY, MIN(maxY, sv.contentOffset.y + speed));
            sv.contentOffset = CGPointMake(sv.contentOffset.x, ny);
        }
    }
    CXUpdateDrag((CCUIContentModuleContainerViewController *)self);
}

%end
