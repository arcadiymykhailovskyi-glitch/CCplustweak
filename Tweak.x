#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "CXShared.h"
#import "CXPickerController.h"

static BOOL gEditing = NO;
static NSString *const kEditNote = @"com.ccplus.editChanged";
enum { kTagPlus = 7001, kTagDone = 7002, kTagCancel = 7003, kTagOverlay = 7010, kTagBadge = 7011 };

static char kGestureStoreKey, kSnapKey, kOrigInsetKey, kFadeKey;

static CXPickerController *gSheet = nil;
static NSHashTable<UIViewController *> *gContainers = nil;
static __weak UIViewController *gDragging = nil;
static NSMutableArray<UIGestureRecognizer *> *gSuspended = nil;

// Состояние перетаскивания (одновременно двигается только один модуль)
static CGAffineTransform gDragBase;
static CGPoint gDragHome, gDragLoc0;
static __weak UILongPressGestureRecognizer *gDragGR = nil;
static CADisplayLink *gDragLink = nil;
static __weak UIScrollView *gDragScroll = nil;

// Страницы и точки-индикатор
static CADisplayLink *gPagerLink = nil;
static NSInteger gDotsCount = 0, gDotsCurrent = -1;
static BOOL gInitialSnapDone = NO;
static NSArray<NSNumber *> *gPageCache = nil;
static CFTimeInterval gPageCacheT = 0;
static CGFloat gPageTop = 70;                 // сколько места сверху оставлено на странице
static NSString *gSelected = nil;             // модуль, который сейчас «выбран» (обводится белым)

// Слой редактирования поверх каждого модуля: только рисует значок «−», касания не принимает
@interface CXEditOverlay : UIView
@end
@implementation CXEditOverlay
@end

// Прозрачный слой, который не перехватывает касания (точки страниц)
@interface CXPassView : UIView
@end
@implementation CXPassView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    return (v == self) ? nil : v;
}
@end
static CXPassView *gDotsHost = nil;

// Слой поверх всего окна Control Center в режиме редактирования. Он сам принимает ВСЕ касания
// (перетаскивание, «−», прокрутка, тап по пустому месту), поэтому от внутренностей Control Center
// ничего не зависит и он не закрывается от случайного нажатия.
@interface CXHostView : UIView <UIGestureRecognizerDelegate>
@end
@implementation CXHostView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    if (v != self) return v;                // кнопки, шторка
    return gEditing ? self : nil;           // всё остальное съедаем только в режиме редактирования
}
// Жесты слоя реагируют только на касания «мимо» его кнопок и шторки
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gr shouldReceiveTouch:(UITouch *)touch {
    return touch.view == self;
}
@end

static CXHostView *gHost = nil;

// «Щит»: прозрачное окно НАД Control Center. В режиме редактирования оно перехватывает все касания,
// кроме кнопок «Готово / Отмена / +» и шторки, поэтому Control Center вообще не видит нажатий
// (не раскрывает яркость и громкость, не закрывается, не листается сам).
@interface CXShieldView : UIView
@end
@implementation CXShieldView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (!gEditing || !gHost || gSheet) return nil;
    for (NSNumber *t in @[@(kTagPlus), @(kTagDone), @(kTagCancel)]) {
        UIView *b = [gHost viewWithTag:t.integerValue];
        if (!b || b.hidden || b.alpha < 0.05) continue;
        CGRect r = [self convertRect:b.bounds fromView:b];
        if (CGRectContainsPoint(CGRectInset(r, -8, -8), point)) return nil;   // пропускаем к кнопкам
    }
    return self;
}
@end

static UIWindow *gShield = nil;

static void CXHideShield(void) {
    gShield.hidden = YES;
    gShield = nil;
}

static void CXShowShield(id target) {
    CXHideShield();
    UIWindow *cc = gHost.window;
    UIWindow *w = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    if (cc.windowScene) w.windowScene = cc.windowScene;
    w.windowLevel = cc.windowLevel + 1;
    w.backgroundColor = UIColor.clearColor;

    UIViewController *rvc = [UIViewController new];
    CXShieldView *view = [[CXShieldView alloc] initWithFrame:w.bounds];
    view.backgroundColor = UIColor.clearColor;
    rvc.view = view;
    w.rootViewController = rvc;

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:target action:NSSelectorFromString(@"cx_hostTap:")];
    [view addGestureRecognizer:tap];
    UILongPressGestureRecognizer *drag = [[UILongPressGestureRecognizer alloc] initWithTarget:target action:NSSelectorFromString(@"cx_hostLong:")];
    drag.minimumPressDuration = 0.22;
    drag.allowableMovement = 10;
    [view addGestureRecognizer:drag];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:target action:NSSelectorFromString(@"cx_hostPan:")];
    [view addGestureRecognizer:pan];

    w.hidden = NO;
    gShield = w;
}

// Пока идёт редактирование, отключаем жесты Control Center (закрытие свайпом или тапом)
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
- (void)cx_hostTap:(UITapGestureRecognizer *)g;
- (void)cx_hostLong:(UILongPressGestureRecognizer *)g;
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
- (void)cx_setSystemGestures:(BOOL)enable;
- (void)cx_ovLong:(UILongPressGestureRecognizer *)g;
- (void)cx_ovTap:(UITapGestureRecognizer *)g;
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

static NSString *gLastToggleId = nil;
static CFTimeInterval gLastToggleT = 0;

// Тап по «−» могут поймать сразу два обработчика: защищаемся от двойного срабатывания
// Выбранный модуль обводится белым (при нажатии, удалении и перетаскивании)
static void CXSetSelected(NSString *ident) {
    gSelected = ident;
    [[NSNotificationCenter defaultCenter] postNotificationName:kEditNote object:nil];
}

static void CXFlashSelected(NSString *ident) {
    CXSetSelected(ident);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if ([gSelected isEqualToString:ident] && !gDragging) CXSetSelected(nil);
    });
}

static void CXToggleRemoveOnce(NSString *ident) {
    CFTimeInterval now = CACurrentMediaTime();
    if ([ident isEqualToString:gLastToggleId] && now - gLastToggleT < 0.35) return;
    gLastToggleId = ident;
    gLastToggleT = now;
    CXHaptic();
    CXFlashSelected(ident);
    CXPlanToggleRemove(ident);
}

// Короткая подсказка внизу экрана
static void CXToastFor(NSString *text, double hold) {
    if (!gHost) return;
    UILabel *l = [UILabel new];
    l.text = text;
    l.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    l.textColor = UIColor.whiteColor;
    l.textAlignment = NSTextAlignmentCenter;
    l.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.7];
    l.layer.cornerRadius = 15;
    l.clipsToBounds = YES;
    CGSize sz = [l sizeThatFits:CGSizeMake(gHost.bounds.size.width - 60, 40)];
    l.frame = CGRectMake(0, 0, sz.width + 28, 30);
    l.center = CGPointMake(gHost.bounds.size.width / 2, gHost.bounds.size.height - 70);
    l.alpha = 0;
    [gHost addSubview:l];
    [UIView animateWithDuration:0.2 animations:^{ l.alpha = 1; } completion:^(BOOL f) {
        [UIView animateWithDuration:0.3 delay:hold options:0 animations:^{ l.alpha = 0; }
                         completion:^(BOOL f2) { [l removeFromSuperview]; }];
    }];
}

static void CXToast(NSString *text) { CXToastFor(text, 1.4); }

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

// Общее пространство координат для всех модулей. У каждого модуля может быть своя родительская
// «обёртка», поэтому сравнивать положения нужно в одной системе: в содержимом прокрутки (или в окне).
static UIView *CXSpace(void) {
    UIScrollView *sv = CXFindScrollView();
    if (sv) return sv;
    for (UIViewController *o in gContainers.allObjects) {
        if (o.isViewLoaded && o.view.window) return o.view.window;
    }
    return nil;
}

static CGRect CXFrameInSpace(UIView *v, UIView *space) {
    return [v.superview convertRect:CXBaseFrame(v) toView:space];
}

// Модуль под пальцем (координаты точки: в слое редактирования)
static CCUIContentModuleContainerViewController *CXModuleAtPoint(UIView *host, CGPoint p) {
    for (UIViewController *o in gContainers.allObjects) {
        if (!o.isViewLoaded || !o.view.window) continue;
        CGRect r = [host convertRect:o.view.bounds fromView:o.view];
        if (CGRectContainsPoint(r, p)) return (CCUIContentModuleContainerViewController *)o;
    }
    return nil;
}

// Отключаем все жесты в поддереве вида (кроме нашего слоя редактирования)
static void CXDisableGesturesIn(UIView *root, NSMutableArray *out) {
    if ([root isKindOfClass:CXEditOverlay.class]) return;
    for (UIGestureRecognizer *gr in root.gestureRecognizers) {
        if (gr.enabled) { gr.enabled = NO; [out addObject:gr]; }
    }
    for (UIView *sub in root.subviews) CXDisableGesturesIn(sub, out);
}

// ---------- Страницы ----------

// Подгоняем отступы прокрутки так, чтобы до каждой страницы можно было доскроллить
static void CXApplyInsets(UIScrollView *sv, NSArray<NSNumber *> *offs) {
    NSValue *stored = objc_getAssociatedObject(sv, &kOrigInsetKey);
    if (!stored) {
        stored = [NSValue valueWithUIEdgeInsets:sv.contentInset];
        objc_setAssociatedObject(sv, &kOrigInsetKey, stored, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    UIEdgeInsets orig = stored.UIEdgeInsetsValue;
    CGFloat safeTop = sv.adjustedContentInset.top - sv.contentInset.top;
    CGFloat safeBottom = sv.adjustedContentInset.bottom - sv.contentInset.bottom;
    CGFloat natMin = -(orig.top + safeTop);
    CGFloat natMax = sv.contentSize.height - sv.bounds.size.height + orig.bottom + safeBottom;
    CGFloat minOff = offs.firstObject.doubleValue;
    CGFloat maxOff = offs.lastObject.doubleValue;

    UIEdgeInsets want = orig;
    if (minOff < natMin) want.top = orig.top + (natMin - minOff);
    if (maxOff > natMax) want.bottom = orig.bottom + (maxOff - natMax);
    if (fabs(want.top - sv.contentInset.top) > 1 || fabs(want.bottom - sv.contentInset.bottom) > 1) {
        sv.contentInset = want;
    }
}

// Смещения прокрутки, на которых «останавливается» каждая страница.
// Модули делятся на страницы ПОРОВНУ (а не «сколько влезло»), чтобы последняя страница не была почти пустой.
// Сверху остаётся место под статус-бар и кнопки, снизу небольшой отступ; страницы набираются из целых рядов.
static NSArray<NSNumber *> *CXPageOffsets(UIScrollView *sv) {
    NSMutableArray<NSValue *> *frames = [NSMutableArray new];
    for (UIViewController *o in gContainers.allObjects) {
        if (!o.isViewLoaded || !o.view.window || !o.view.superview) continue;
        CGRect f = [o.view.superview convertRect:CXBaseFrame(o.view) toView:sv];
        [frames addObject:[NSValue valueWithCGRect:f]];
    }
    if (frames.count == 0) return @[@(-sv.adjustedContentInset.top)];
    [frames sortUsingComparator:^NSComparisonResult(NSValue *a, NSValue *b) {
        return [@(a.CGRectValue.origin.y) compare:@(b.CGRectValue.origin.y)];
    }];

    CGFloat H = sv.bounds.size.height;
    CGFloat topMargin = MAX(sv.window.safeAreaInsets.top, 20) + 50;
    gPageTop = topMargin;
    CGFloat bottomMargin = 44;
    CGFloat capacity = H - topMargin - bottomMargin;

    CGFloat firstY = frames.firstObject.CGRectValue.origin.y;
    CGFloat maxBottom = firstY;
    for (NSValue *v in frames) maxBottom = MAX(maxBottom, CGRectGetMaxY(v.CGRectValue));

    // Начала рядов (без повторов)
    NSMutableArray<NSNumber *> *rowStarts = [NSMutableArray new];
    for (NSValue *v in frames) {
        CGFloat y = v.CGRectValue.origin.y;
        if (rowStarts.count == 0 || y > rowStarts.lastObject.doubleValue + 3) [rowStarts addObject:@(y)];
    }

    // 1) Жадное разбиение «сколько влезло»
    NSMutableArray<NSNumber *> *starts = [NSMutableArray arrayWithObject:@(firstY)];
    CGFloat start = firstY;
    for (NSValue *v in frames) {
        CGRect f = v.CGRectValue;
        if (CGRectGetMaxY(f) - start > capacity && f.origin.y > start + 1) {
            start = f.origin.y;
            [starts addObject:@(start)];
        }
    }

    // 2) Если страниц несколько, пробуем разделить поровну
    if (starts.count >= 2) {
        NSInteger n = (NSInteger)starts.count;
        CGFloat target = (maxBottom - firstY) / n;
        NSMutableArray<NSNumber *> *bal = [NSMutableArray arrayWithObject:@(firstY)];
        for (NSInteger k = 1; k < n; k++) {
            CGFloat ideal = firstY + k * target;
            CGFloat best = -1, bd = CGFLOAT_MAX;
            for (NSNumber *r in rowStarts) {
                if (r.doubleValue <= bal.lastObject.doubleValue + 1) continue;
                CGFloat d = fabs(r.doubleValue - ideal);
                if (d < bd) { bd = d; best = r.doubleValue; }
            }
            if (best < 0) break;
            [bal addObject:@(best)];
        }
        BOOL ok = ((NSInteger)bal.count == n);
        for (NSInteger i = 0; ok && i < n; i++) {
            CGFloat s0 = bal[i].doubleValue;
            CGFloat s1 = (i + 1 < n) ? bal[i + 1].doubleValue : CGFLOAT_MAX;
            CGFloat bottom = s0;
            for (NSValue *v in frames) {
                CGRect f = v.CGRectValue;
                if (f.origin.y >= s0 - 1 && f.origin.y < s1 - 1) bottom = MAX(bottom, CGRectGetMaxY(f));
            }
            if (bottom - s0 > capacity) ok = NO;
        }
        if (ok) starts = bal;
    }

    NSMutableArray<NSNumber *> *offs = [NSMutableArray new];
    for (NSNumber *st in starts) [offs addObject:@(st.doubleValue - topMargin)];
    CXApplyInsets(sv, offs);
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

// Дробный номер страницы по положению прокрутки (0.0 — первая, 1.0 — вторая, 0.5 — посередине)
static CGFloat CXPageProgress(NSArray<NSNumber *> *offs, CGFloat y) {
    if (offs.count < 2 || y <= offs.firstObject.doubleValue) return 0;
    for (NSUInteger i = 0; i + 1 < offs.count; i++) {
        CGFloat a = offs[i].doubleValue, b = offs[i + 1].doubleValue;
        if (y < b) return i + (y - a) / MAX(1, b - a);
    }
    return offs.count - 1;
}

// Как в образце: при перелистывании модули уходящей страницы тают, а следующей проявляются
static void CXApplyPageFade(UIScrollView *sv, NSArray<NSNumber *> *offs, CGFloat p) {
    if (offs.count < 2) return;
    BOOL settled = fabs(p - round(p)) < 0.02;
    for (UIViewController *o in gContainers.allObjects) {
        if (!o.isViewLoaded || !o.view.window || !o.view.superview) continue;
        BOOL touched = objc_getAssociatedObject(o, &kFadeKey) != nil;
        if (settled && !touched) continue;
        UIView *v = o.view;
        CGRect f = [v.superview convertRect:CXBaseFrame(v) toView:sv];
        NSInteger k = 0;
        for (NSInteger i = 0; i < (NSInteger)offs.count; i++) {
            if (f.origin.y >= offs[i].doubleValue + gPageTop - 2) k = i;
        }
        CGFloat a = settled ? 1.0 : MAX(0.0, 1.0 - MIN(1.0, fabs(p - k) * 1.3));
        if (fabs(v.alpha - a) > 0.02) v.alpha = a;
        objc_setAssociatedObject(o, &kFadeKey, settled ? nil : @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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

// ---------- Перетаскивание ----------
//
// Как в iOS 18: палец держит поднятый модуль, остальные плавно перестраиваются вокруг него.
// Работает для модулей любого размера: твик «собирает» сетку так же, как Control Center (слева направо,
// сверху вниз, первое подходящее место). Если сетка не совпала с настоящей, остаётся запасной режим:
// обмен местами внутри группы модулей одного размера.

static NSMutableDictionary<NSString *, NSDictionary *> *gInfo = nil;   // id -> @{vc, w, h, cs, rs, r, c, base}
static NSMutableArray<NSString *> *gOrder = nil;                        // текущий порядок всех модулей
static NSArray<NSString *> *gBaseOrder = nil;                           // порядок «как сейчас в Control Center»
static NSMutableDictionary<NSString *, NSValue *> *gDest = nil;         // id -> куда модуль должен встать (центр)
static NSInteger gCols = 4;
static CGFloat gX0 = 0, gY0 = 0, gPX = 0, gPY = 0;
static BOOL gPackMode = YES;
static CFTimeInterval gSwapT = 0;
static __weak UIView *gDragWrap = nil;

// Рассчитывает, где окажется каждый модуль при заданном порядке
static NSMutableDictionary<NSString *, NSValue *> *CXSimulate(NSArray<NSString *> *order) {
    NSMutableDictionary<NSString *, NSValue *> *dest = [NSMutableDictionary new];

    if (gPackMode) {
        NSMutableArray<NSMutableArray<NSNumber *> *> *grid = [NSMutableArray new];
        for (NSString *i in order) {
            NSDictionary *inf = gInfo[i];
            if (!inf) continue;
            NSInteger cs = [inf[@"cs"] integerValue], rs = [inf[@"rs"] integerValue];
            if (cs > gCols) cs = gCols;
            BOOL placed = NO;
            for (NSInteger r = 0; !placed && r < 300; r++) {
                for (NSInteger c = 0; !placed && c + cs <= gCols; c++) {
                    BOOL free = YES;
                    for (NSInteger rr = r; free && rr < r + rs; rr++) {
                        while ((NSInteger)grid.count <= rr) {
                            NSMutableArray *row = [NSMutableArray new];
                            for (NSInteger k = 0; k < gCols; k++) [row addObject:@NO];
                            [grid addObject:row];
                        }
                        for (NSInteger cc = c; cc < c + cs; cc++) {
                            if ([grid[rr][cc] boolValue]) { free = NO; break; }
                        }
                    }
                    if (!free) continue;
                    for (NSInteger rr = r; rr < r + rs; rr++)
                        for (NSInteger cc = c; cc < c + cs; cc++) grid[rr][cc] = @YES;
                    CGFloat w = [inf[@"w"] doubleValue], h = [inf[@"h"] doubleValue];
                    dest[i] = [NSValue valueWithCGPoint:CGPointMake(gX0 + c * gPX + w / 2, gY0 + r * gPY + h / 2)];
                    placed = YES;
                }
            }
        }
    } else {
        // Запасной режим: места (слоты) делятся между модулями одного размера
        NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *groups = [NSMutableDictionary new];
        for (NSString *i in order) {
            NSDictionary *inf = gInfo[i];
            if (!inf) continue;
            NSString *key = [NSString stringWithFormat:@"%ld_%ld", (long)lround([inf[@"w"] doubleValue] / 3),
                             (long)lround([inf[@"h"] doubleValue] / 3)];
            NSMutableArray *g = groups[key];
            if (!g) { g = [NSMutableArray new]; groups[key] = g; }
            [g addObject:i];
        }
        for (NSString *key in groups) {
            NSArray<NSString *> *ids = groups[key];
            NSArray<NSString *> *slots = [ids sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
                NSDictionary *ia = gInfo[a], *ib = gInfo[b];
                NSComparisonResult r = [ia[@"r"] compare:ib[@"r"]];
                return r != NSOrderedSame ? r : [ia[@"c"] compare:ib[@"c"]];
            }];
            for (NSUInteger k = 0; k < ids.count; k++) dest[ids[k]] = gInfo[slots[k]][@"base"];
        }
    }
    return dest;
}

// Собираем сетку из всех модулей на экране
static BOOL CXBuildGrid(void) {
    UIView *space = CXSpace();
    if (!space) return NO;

    NSMutableArray<NSDictionary *> *items = [NSMutableArray new];
    for (UIViewController *o in gContainers.allObjects) {
        if (!o.isViewLoaded || !o.view.window || !o.view.superview) continue;
        NSString *oid = [(CCUIContentModuleContainerViewController *)o moduleIdentifier];
        if (!oid) continue;
        CGRect f = CXFrameInSpace(o.view, space);
        if (f.size.width < 20 || f.size.height < 20) continue;
        [items addObject:@{ @"vc": o, @"id": oid, @"f": [NSValue valueWithCGRect:f] }];
    }
    if (items.count < 2) return NO;

    CGFloat uw = CGFLOAT_MAX, uh = CGFLOAT_MAX;
    NSMutableArray<NSNumber *> *xs = [NSMutableArray new], *ys = [NSMutableArray new];
    for (NSDictionary *d in items) {
        CGRect f = [d[@"f"] CGRectValue];
        uw = MIN(uw, f.size.width);
        uh = MIN(uh, f.size.height);
        BOOL hx = NO, hy = NO;
        for (NSNumber *x in xs) if (fabs(x.doubleValue - f.origin.x) < 4) { hx = YES; break; }
        for (NSNumber *y in ys) if (fabs(y.doubleValue - f.origin.y) < 4) { hy = YES; break; }
        if (!hx) [xs addObject:@(f.origin.x)];
        if (!hy) [ys addObject:@(f.origin.y)];
    }
    [xs sortUsingSelector:@selector(compare:)];
    [ys sortUsingSelector:@selector(compare:)];
    if (xs.count < 2) return NO;

    CGFloat px = CGFLOAT_MAX, py = CGFLOAT_MAX;
    for (NSUInteger i = 0; i + 1 < xs.count; i++) px = MIN(px, xs[i + 1].doubleValue - xs[i].doubleValue);
    for (NSUInteger i = 0; i + 1 < ys.count; i++) py = MIN(py, ys[i + 1].doubleValue - ys[i].doubleValue);
    if (px < uw * 0.8) return NO;
    if (py == CGFLOAT_MAX) py = uh + (px - uw);
    CGFloat gx = px - uw, gy = py - uh;

    gX0 = xs.firstObject.doubleValue;
    gY0 = ys.firstObject.doubleValue;
    gPX = px;
    gPY = py;

    gInfo = [NSMutableDictionary new];
    NSInteger cols = 0;
    for (NSDictionary *d in items) {
        CGRect f = [d[@"f"] CGRectValue];
        NSInteger cs = MAX(1, lround((f.size.width + gx) / px));
        NSInteger rs = MAX(1, lround((f.size.height + gy) / py));
        NSInteger c0 = MAX(0, lround((f.origin.x - gX0) / px));
        NSInteger r0 = MAX(0, lround((f.origin.y - gY0) / py));
        cols = MAX(cols, c0 + cs);
        gInfo[d[@"id"]] = @{ @"vc": d[@"vc"], @"w": @(f.size.width), @"h": @(f.size.height),
                             @"cs": @(cs), @"rs": @(rs), @"r": @(r0), @"c": @(c0),
                             @"base": [NSValue valueWithCGPoint:CGPointMake(CGRectGetMidX(f), CGRectGetMidY(f))] };
    }
    gCols = MAX(2, MIN(cols, 8));

    // Порядок «как сейчас»: ряд за рядом, слева направо
    NSArray<NSString *> *reading = [gInfo.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSDictionary *ia = gInfo[a], *ib = gInfo[b];
        NSComparisonResult r = [ia[@"r"] compare:ib[@"r"]];
        if (r != NSOrderedSame) return r;
        r = [ia[@"c"] compare:ib[@"c"]];
        return r != NSOrderedSame ? r : [a compare:b];
    }];
    gBaseOrder = reading;

    // Если модули уже двигали, продолжаем с накопленного порядка
    NSMutableArray<NSString *> *order = [NSMutableArray new];
    for (NSString *i in (CXPlanOrder() ?: @[])) if (gInfo[i] && ![order containsObject:i]) [order addObject:i];
    for (NSString *i in reading) if (![order containsObject:i]) [order addObject:i];
    gOrder = order;

    // Проверка: совпадает ли наша сетка с настоящей? Если нет, включаем запасной режим
    gPackMode = YES;
    NSMutableDictionary *check = CXSimulate(reading);
    for (NSString *i in reading) {
        CGPoint a = [check[i] CGPointValue], b = [gInfo[i][@"base"] CGPointValue];
        if (!check[i] || hypot(a.x - b.x, a.y - b.y) > 4) { gPackMode = NO; break; }
    }
    gDest = CXSimulate(gOrder);
    gSwapT = 0;
    return YES;
}

// Один «кадр» перетаскивания: палец ведёт модуль, остальные перестраиваются вокруг него
static void CXUpdateDrag(CCUIContentModuleContainerViewController *vc) {
    UILongPressGestureRecognizer *g = gDragGR;
    UIView *v = vc.view;
    UIView *sup = v.superview;
    UIView *space = CXSpace();
    if (!g || !sup || !space || !gOrder) return;

    CGPoint loc = [g locationInView:sup];
    CGAffineTransform tr = CGAffineTransformTranslate(gDragBase, loc.x - gDragLoc0.x, loc.y - gDragLoc0.y);
    v.transform = CGAffineTransformScale(tr, 1.08, 1.08);

    CFTimeInterval now = CACurrentMediaTime();
    if (now - gSwapT < 0.18) return;

    NSString *ident = [vc moduleIdentifier];
    CGPoint c = [sup convertPoint:CGPointMake(CGRectGetMidX(v.frame), CGRectGetMidY(v.frame)) toView:space];
    NSDictionary *me = gInfo[ident];

    // Над каким модулем сейчас находится центр тащимого (по тому месту, куда он встанет)
    NSString *over = nil;
    for (NSString *oid in gOrder) {
        if ([oid isEqualToString:ident]) continue;
        NSDictionary *oi = gInfo[oid];
        NSValue *dv = gDest[oid];
        if (!oi || !dv) continue;
        if (!gPackMode && (fabs([oi[@"w"] doubleValue] - [me[@"w"] doubleValue]) > 3 ||
                           fabs([oi[@"h"] doubleValue] - [me[@"h"] doubleValue]) > 3)) continue;   // в запасном режиме только свой размер
        CGPoint dc = dv.CGPointValue;
        CGFloat w = [oi[@"w"] doubleValue], h = [oi[@"h"] doubleValue];
        CGRect inner = CGRectInset(CGRectMake(dc.x - w / 2, dc.y - h / 2, w, h), w * 0.2, h * 0.2);
        if (CGRectContainsPoint(inner, c)) { over = oid; break; }
    }
    if (!over) return;

    NSUInteger from = [gOrder indexOfObject:ident];
    NSUInteger to = [gOrder indexOfObject:over];
    if (from == NSNotFound || to == NSNotFound || from == to) return;

    NSMutableArray<NSString *> *newOrder = [gOrder mutableCopy];
    [newOrder removeObjectAtIndex:from];
    [newOrder insertObject:ident atIndex:to];
    NSMutableDictionary<NSString *, NSValue *> *newDest = CXSimulate(newOrder);
    if (!newDest[ident]) return;

    gOrder = newOrder;
    gDest = newDest;
    gSwapT = now;

    // Остальные плавно занимают новые места
    for (NSString *oid in gOrder) {
        if ([oid isEqualToString:ident]) continue;
        NSDictionary *oi = gInfo[oid];
        NSValue *dv = newDest[oid];
        if (!oi || !dv) continue;
        CGPoint base = [oi[@"base"] CGPointValue], dest = dv.CGPointValue;
        UIView *ov = ((UIViewController *)oi[@"vc"]).view;
        [UIView animateWithDuration:0.42 delay:0 usingSpringWithDamping:0.78 initialSpringVelocity:0.3
                            options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                         animations:^{ ov.transform = CGAffineTransformMakeTranslation(dest.x - base.x, dest.y - base.y); }
                         completion:nil];
    }
    CXPlanSetOrder([gOrder isEqualToArray:gBaseOrder] ? nil : [gOrder copy]);
    [[[UISelectionFeedbackGenerator alloc] init] selectionChanged];
}

// Кадр таймера: автопрокрутка у краёв экрана + движение модуля
static void CXDragFrame(void) {
    CCUIContentModuleContainerViewController *vc = (CCUIContentModuleContainerViewController *)gDragging;
    if (!vc || !gDragGR) {
        [gDragLink invalidate];
        gDragLink = nil;
        return;
    }
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
    CXUpdateDrag(vc);
}

@interface CXTicker : NSObject
- (void)tick:(CADisplayLink *)link;
@end
@implementation CXTicker
- (void)tick:(CADisplayLink *)link { CXDragFrame(); }
@end
static CXTicker *gTicker = nil;

static void CXDragBegin(UILongPressGestureRecognizer *g, CCUIContentModuleContainerViewController *vc) {
    UIView *v = vc.view;
    UIView *sup = v.superview;
    if (!sup) return;

    if (!CXBuildGrid() || !gInfo[[vc moduleIdentifier]]) {
        CXHaptic();
        CXToast(@"Некуда переместить");
        return;
    }

    gDragging = vc;
    gDragGR = g;
    CXSetSelected([vc moduleIdentifier]);
    gDragBase = v.transform;
    gDragLoc0 = [g locationInView:sup];
    gDragScroll = CXFindScrollView();
    [v.layer removeAnimationForKey:@"cx_wobble"];
    [sup bringSubviewToFront:v];
    v.layer.zPosition = 100;
    // Если у каждого модуля своя «обёртка», поднимаем и её, чтобы соседи не перекрывали тащимый модуль
    if (sup.superview && ![sup isKindOfClass:UIScrollView.class]) {
        [sup.superview bringSubviewToFront:sup];
        sup.layer.zPosition = 100;
        gDragWrap = sup;
    }
    CXHaptic();

    if (!gTicker) gTicker = [CXTicker new];
    gDragLink = [CADisplayLink displayLinkWithTarget:gTicker selector:@selector(tick:)];
    [gDragLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    [UIView animateWithDuration:0.22 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0.3
                        options:UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        CXUpdateDrag(vc);          // модуль «приподнимается»
        v.alpha = 0.92;
    } completion:nil];
}

static void CXDragEnd(void) {
    CCUIContentModuleContainerViewController *vc = (CCUIContentModuleContainerViewController *)gDragging;
    if (!vc) return;
    UIView *v = vc.view;
    NSString *ident = [vc moduleIdentifier];
    gDragging = nil;
    [gDragLink invalidate];
    gDragLink = nil;
    UIScrollView *sv = gDragScroll;
    gDragScroll = nil;
    gDragGR = nil;

    // Модуль плавно «садится» на своё место
    NSValue *homeV = gDest[ident], *baseV = gInfo[ident][@"base"];
    CGAffineTransform end = CGAffineTransformIdentity;
    if (homeV && baseV) {
        end = CGAffineTransformMakeTranslation(homeV.CGPointValue.x - baseV.CGPointValue.x,
                                               homeV.CGPointValue.y - baseV.CGPointValue.y);
    }
    [UIView animateWithDuration:0.45 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0.3
                        options:UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        v.transform = end;
        v.alpha = 1.0;
    } completion:nil];
    CXHaptic();

    v.layer.zPosition = 0;
    gDragWrap.layer.zPosition = 0;
    gDragWrap = nil;
    CXSetSelected(nil);
    [vc cx_refreshEdit];                      // вернуть покачивание
    if (sv) CXSnapScroll(sv, 0);              // страница мягко встаёт на ближайшую «остановку»
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
    gInitialSnapDone = NO;
    gPageCache = nil;
    if (!gPagerLink) {
        gPagerLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(cx_pagerTick:)];
        gPagerLink.preferredFramesPerSecond = 60;
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

    // Страницы пересчитываем несколько раз в секунду, а не на каждый кадр
    CFTimeInterval now = CACurrentMediaTime();
    if (!gPageCache || now - gPageCacheT > 0.25) {
        gPageCache = CXPageOffsets(sv);
        gPageCacheT = now;
    }
    NSArray<NSNumber *> *offs = gPageCache;

    // При открытии Control Center сразу ставим первую страницу так, чтобы верхний ряд не залезал под статус-бар
    if (!gInitialSnapDone && !sv.isTracking && !sv.isDecelerating) {
        gInitialSnapDone = YES;
        sv.contentOffset = CGPointMake(sv.contentOffset.x, offs.firstObject.doubleValue);
    }

    CGFloat p = CXPageProgress(offs, sv.contentOffset.y);
    CXUpdateDots(offs.count, (NSInteger)lround(p));
    if (!gEditing) CXApplyPageFade(sv, offs, p);
}

%new
- (void)cx_scrollPan:(UIPanGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateEnded && g.state != UIGestureRecognizerStateCancelled) return;
    UIScrollView *sv = (UIScrollView *)g.view;
    if (![sv isKindOfClass:UIScrollView.class] || gDragging || gEditing) return;
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

        // Тап: «−» или пустое место. Зажать и тащить: двигать модуль. Свайп: листать страницы.
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(cx_hostTap:)];
        tap.delegate = host;
        [host addGestureRecognizer:tap];

        UILongPressGestureRecognizer *drag = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(cx_hostLong:)];
        drag.minimumPressDuration = 0.22;
        drag.allowableMovement = 10;
        drag.delegate = host;
        [host addGestureRecognizer:drag];

        UIPanGestureRecognizer *hp = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(cx_hostPan:)];
        hp.delegate = host;
        [host addGestureRecognizer:hp];

        host.alpha = 0;
        [parent addSubview:host];
        gHost = host;
        CXSuspendCCGestures(self.view, YES);
        CXShowShield(self);
        [self cx_refreshButtons];
        [UIView animateWithDuration:0.28 delay:0 options:UIViewAnimationOptionCurveEaseOut
                         animations:^{ host.alpha = 1; } completion:nil];
    } else {
        if (gSheet) [gSheet closeSheet];
        CXHideShield();
        CXDragEnd();
        CXHostView *old = gHost;
        gHost = nil;
        [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseInOut
                         animations:^{ old.alpha = 0; }
                         completion:^(BOOL f) { [old removeFromSuperview]; }];
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:kEditNote object:nil];
}

%new
- (void)cx_hostTap:(UITapGestureRecognizer *)g {
    if (gSheet || !gHost) return;
    CGPoint p = [g locationInView:gHost];
    CCUIContentModuleContainerViewController *vc = CXModuleAtPoint(gHost, p);
    if (vc) {
        // Тап по модулю: работает только значок «−» в его левом верхнем углу
        NSString *ident = [vc moduleIdentifier];
        CGRect r = [gHost convertRect:vc.view.bounds fromView:vc.view];
        CGRect badge = CGRectMake(r.origin.x - 4, r.origin.y - 4, 46, 46);
        if (ident && CXIsRemovable(ident) && CGRectContainsPoint(badge, p)) CXToggleRemoveOnce(ident);
        return;
    }
    [self cx_emptyTapped];
}

%new
- (void)cx_hostLong:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) {
        if (gSheet) return;
        CGPoint p = [g locationInView:gHost];
        CCUIContentModuleContainerViewController *vc = CXModuleAtPoint(gHost, p);
        if (!vc) return;
        NSString *ident = [vc moduleIdentifier];
        if (!ident || CXPlanIsRemoved(ident)) return;
        CXDragBegin(g, vc);
    } else if (g.state == UIGestureRecognizerStateChanged) {
        if (gDragging) CXDragFrame();
    } else if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled ||
               g.state == UIGestureRecognizerStateFailed) {
        CXDragEnd();
    }
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
    } else if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        CXSnapScroll(sv, [g velocityInView:g.view].y);
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

// ---------- Контейнер каждого модуля: значок «−», покачивание ----------

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

    // --- слой со значком (касаний не принимает) ---
    if (!ov) {
        [self cx_setSystemGestures:NO];

        ov = [[CXEditOverlay alloc] initWithFrame:v.bounds];
        ov.tag = kTagOverlay;
        ov.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        ov.backgroundColor = UIColor.clearColor;
        ov.alpha = 0;

        // Зажать и тащить / тап по «−». Работает параллельно со слоем окна: касание достанется одному из них.
        UILongPressGestureRecognizer *drag = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(cx_ovLong:)];
        drag.minimumPressDuration = 0.2;
        drag.allowableMovement = 10;
        [ov addGestureRecognizer:drag];
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(cx_ovTap:)];
        [ov addGestureRecognizer:tap];

        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.tag = kTagBadge;
        b.userInteractionEnabled = NO;
        b.frame = CGRectMake(0, 0, 40, 40);
        b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        b.contentVerticalAlignment = UIControlContentVerticalAlignmentTop;
        b.contentEdgeInsets = UIEdgeInsetsMake(4, 4, 0, 0);
        [ov addSubview:b];

        [v addSubview:ov];
        [UIView animateWithDuration:0.25 animations:^{ ov.alpha = 1; }];
    }
    [v bringSubviewToFront:ov];

    // --- тонкая белая обводка модуля; у выбранного (нажатого / перетаскиваемого) она ярче и толще ---
    {
        CGFloat radius = v.layer.cornerRadius;
        if (radius < 1) {
            for (UIView *sub in v.subviews) { if (sub.layer.cornerRadius > radius) radius = sub.layer.cornerRadius; }
        }
        if (radius < 1) radius = 16;
        BOOL sel = [ident isEqualToString:gSelected];
        ov.layer.cornerRadius = radius;
        UIColor *border = [UIColor colorWithWhite:1.0 alpha:sel ? 1.0 : 0.42];
        CGFloat width = sel ? 2.5 : 1.0;
        if (ov.layer.borderWidth != width) {
            CABasicAnimation *bw = [CABasicAnimation animationWithKeyPath:@"borderWidth"];
            bw.fromValue = @(ov.layer.borderWidth);
            bw.toValue = @(width);
            bw.duration = 0.2;
            [ov.layer addAnimation:bw forKey:@"bw"];
        }
        ov.layer.borderWidth = width;
        ov.layer.borderColor = border.CGColor;
    }

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
- (void)cx_setSystemGestures:(BOOL)enable {
    // На время редактирования отключаем ВСЕ системные жесты модуля, включая раскрытие по долгому нажатию
    UIView *v = self.view;
    if (!enable) {
        NSMutableArray *disabled = [NSMutableArray new];
        CXDisableGesturesIn(v, disabled);
        objc_setAssociatedObject(self, &kGestureStoreKey, disabled, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        NSArray *disabled = objc_getAssociatedObject(self, &kGestureStoreKey);
        for (UIGestureRecognizer *gr in disabled) gr.enabled = YES;
        objc_setAssociatedObject(self, &kGestureStoreKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

%new
- (void)cx_ovLong:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) {
        if (gDragging || gSheet) return;
        NSString *ident = [self moduleIdentifier];
        if (!ident || CXPlanIsRemoved(ident)) return;
        CXDragBegin(g, (CCUIContentModuleContainerViewController *)self);
    } else if (g.state == UIGestureRecognizerStateChanged) {
        if (gDragging == self) CXDragFrame();
    } else if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled ||
               g.state == UIGestureRecognizerStateFailed) {
        if (gDragging == self) CXDragEnd();
    }
}

%new
- (void)cx_ovTap:(UITapGestureRecognizer *)g {
    NSString *ident = [self moduleIdentifier];
    if (!ident || !CXIsRemovable(ident)) return;
    CGPoint p = [g locationInView:self.view];
    if (p.x <= 46 && p.y <= 46) CXToggleRemoveOnce(ident);
}

%end
