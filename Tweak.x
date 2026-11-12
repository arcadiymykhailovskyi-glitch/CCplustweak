#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "CXShared.h"
#import "CXPickerController.h"

static BOOL gEditing = NO;
static NSString *const kEditNote = @"com.ccplus.editChanged";
enum { kTagPlus = 7001, kTagDone = 7002, kTagCancel = 7003, kTagOverlay = 7010, kTagBadge = 7011 };

static char kGestureStoreKey, kSnapKey, kOrigInsetKey;

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
static void CXToggleRemoveOnce(NSString *ident) {
    CFTimeInterval now = CACurrentMediaTime();
    if ([ident isEqualToString:gLastToggleId] && now - gLastToggleT < 0.35) return;
    gLastToggleId = ident;
    gLastToggleT = now;
    CXHaptic();
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
// На странице помещается не весь экран: сверху остаётся место под статус-бар и кнопки,
// снизу небольшой отступ. Страницы набираются из целых рядов модулей.
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
    CGFloat bottomMargin = 44;
    CGFloat capacity = H - topMargin - bottomMargin;

    CGFloat firstY = frames.firstObject.CGRectValue.origin.y;
    NSMutableArray<NSNumber *> *offs = [NSMutableArray arrayWithObject:@(firstY - topMargin)];
    CGFloat start = firstY;
    for (NSValue *v in frames) {
        CGRect f = v.CGRectValue;
        if (CGRectGetMaxY(f) - start > capacity && f.origin.y > start + 1) {
            start = f.origin.y;
            [offs addObject:@(start - topMargin)];
        }
    }
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
// Как в iOS 18: палец держит поднятый модуль, остальные плавно «расступаются» и занимают соседние места.
// Меняются местами только модули одного размера: каждый такой модуль занимает один из «слотов»
// (его место на сетке), а при перетаскивании идёт вставка в нужный слот со сдвигом остальных.

static NSMutableArray<UIViewController *> *gGroupVCs = nil;                 // модули группы
static NSMutableArray<NSValue *> *gSlotCenters = nil;                       // центры слотов (сверху вниз, слева направо)
static NSMutableArray<NSString *> *gGroupIdents = nil;                      // кто сейчас в каком слоте
static NSMutableDictionary<NSString *, NSValue *> *gBaseCenters = nil;      // собственный центр модуля без сдвигов
static NSInteger gDragSlot = 0;

// Собираем группу модулей того же размера, что и тащимый
static BOOL CXBuildGroup(CCUIContentModuleContainerViewController *vc) {
    UIView *sup = vc.view.superview;
    if (!sup) return NO;
    CGSize sz = CXBaseFrame(vc.view).size;

    NSMutableArray<NSDictionary *> *items = [NSMutableArray new];
    for (UIViewController *o in gContainers.allObjects) {
        if (!o.isViewLoaded || o.view.superview != sup) continue;
        NSString *oid = [(CCUIContentModuleContainerViewController *)o moduleIdentifier];
        if (!oid || !CXIsRemovable(oid) || CXPlanIsRemoved(oid)) continue;
        CGRect f = CXBaseFrame(o.view);
        if (fabs(f.size.width - sz.width) > 2 || fabs(f.size.height - sz.height) > 2) continue;
        [items addObject:@{ @"vc": o, @"id": oid,
                            @"y": @(round(f.origin.y)), @"x": @(f.origin.x),
                            @"c": [NSValue valueWithCGPoint:CGPointMake(CGRectGetMidX(f), CGRectGetMidY(f))] }];
    }
    if (items.count < 2) return NO;
    [items sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSComparisonResult r = [a[@"y"] compare:b[@"y"]];
        return r != NSOrderedSame ? r : [a[@"x"] compare:b[@"x"]];
    }];

    gGroupVCs = [NSMutableArray new];
    gSlotCenters = [NSMutableArray new];
    gBaseCenters = [NSMutableDictionary new];
    NSMutableSet<NSString *> *groupIds = [NSMutableSet new];
    for (NSDictionary *d in items) {
        [gGroupVCs addObject:d[@"vc"]];
        [gSlotCenters addObject:d[@"c"]];
        gBaseCenters[d[@"id"]] = d[@"c"];
        [groupIds addObject:d[@"id"]];
    }

    // Кто в каком слоте сейчас: по уже накопленному порядку (если модули уже двигали), иначе по сетке
    NSArray<NSString *> *order = CXPlanOrder() ?: CXVisualOrder(sup);
    gGroupIdents = [NSMutableArray new];
    for (NSString *i in order) if ([groupIds containsObject:i]) [gGroupIdents addObject:i];
    for (NSDictionary *d in items) if (![gGroupIdents containsObject:d[@"id"]]) [gGroupIdents addObject:d[@"id"]];

    NSUInteger me = [gGroupIdents indexOfObject:[vc moduleIdentifier]];
    if (me == NSNotFound) return NO;
    gDragSlot = (NSInteger)me;
    return YES;
}

// Один «кадр» перетаскивания: палец ведёт модуль, остальные уступают место
static void CXUpdateDrag(CCUIContentModuleContainerViewController *vc) {
    UILongPressGestureRecognizer *g = gDragGR;
    UIView *v = vc.view;
    UIView *sup = v.superview;
    if (!g || !sup) return;

    CGPoint loc = [g locationInView:sup];
    CGAffineTransform tr = CGAffineTransformTranslate(gDragBase, loc.x - gDragLoc0.x, loc.y - gDragLoc0.y);
    v.transform = CGAffineTransformScale(tr, 1.1, 1.1);

    if (gSlotCenters.count < 2) return;

    // Ближайший к модулю слот
    CGPoint c = CGPointMake(CGRectGetMidX(v.frame), CGRectGetMidY(v.frame));
    NSInteger target = gDragSlot;
    CGFloat best = CGFLOAT_MAX;
    for (NSInteger k = 0; k < (NSInteger)gSlotCenters.count; k++) {
        CGPoint sc = gSlotCenters[k].CGPointValue;
        CGFloat d = hypot(c.x - sc.x, c.y - sc.y);
        if (d < best) { best = d; target = k; }
    }
    if (target == gDragSlot) return;

    // Небольшой «гистерезис», чтобы модули не дёргались туда-сюда на границе слотов
    CGPoint cur = gSlotCenters[gDragSlot].CGPointValue;
    if (best > hypot(c.x - cur.x, c.y - cur.y) * 0.8) return;

    NSString *ident = [vc moduleIdentifier];
    NSUInteger from = [gGroupIdents indexOfObject:ident];
    if (from == NSNotFound) return;
    [gGroupIdents removeObjectAtIndex:from];
    [gGroupIdents insertObject:ident atIndex:target];
    gDragSlot = target;
    gDragHome = gSlotCenters[target].CGPointValue;

    // Остальные плавно занимают новые слоты (вставка со сдвигом, как в iOS 18)
    for (UIViewController *o in gGroupVCs) {
        if (o == vc) continue;
        NSString *oid = [(CCUIContentModuleContainerViewController *)o moduleIdentifier];
        NSUInteger slot = [gGroupIdents indexOfObject:oid];
        NSValue *baseV = gBaseCenters[oid];
        if (slot == NSNotFound || !baseV) continue;
        CGPoint base = baseV.CGPointValue;
        CGPoint dest = gSlotCenters[slot].CGPointValue;
        UIView *ov = o.view;
        [UIView animateWithDuration:0.42 delay:0 usingSpringWithDamping:0.78 initialSpringVelocity:0.3
                            options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                         animations:^{ ov.transform = CGAffineTransformMakeTranslation(dest.x - base.x, dest.y - base.y); }
                         completion:nil];
    }

    // Обновляем общий порядок: те же позиции, но группа расставлена по-новому
    NSMutableArray<NSString *> *order = [(CXPlanOrder() ?: CXVisualOrder(sup)) mutableCopy];
    NSMutableArray<NSNumber *> *positions = [NSMutableArray new];
    for (NSUInteger i = 0; i < order.count; i++) if ([gGroupIdents containsObject:order[i]]) [positions addObject:@(i)];
    for (NSUInteger k = 0; k < positions.count && k < gGroupIdents.count; k++) {
        order[positions[k].unsignedIntegerValue] = gGroupIdents[k];
    }
    // Если модуль вернули на исходное место, изменения по порядку не считаем
    CXPlanSetOrder([order isEqualToArray:CXVisualOrder(sup)] ? nil : order);
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

    if (!CXBuildGroup(vc)) {
        CXHaptic();
        CXToast(@"Для этого элемента нет другого места такого же размера");
        return;
    }

    gDragging = vc;
    gDragGR = g;
    gDragBase = v.transform;
    gDragHome = gSlotCenters[gDragSlot].CGPointValue;
    gDragLoc0 = [g locationInView:sup];
    gDragScroll = CXFindScrollView();
    [v.layer removeAnimationForKey:@"cx_wobble"];
    [sup bringSubviewToFront:v];
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

    // Модуль плавно «садится» в свой слот
    CGPoint base = gBaseCenters[ident] ? gBaseCenters[ident].CGPointValue : gDragHome;
    CGAffineTransform end = CGAffineTransformMakeTranslation(gDragHome.x - base.x, gDragHome.y - base.y);
    [UIView animateWithDuration:0.45 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0.3
                        options:UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        v.transform = end;
        v.alpha = 1.0;
    } completion:nil];
    CXHaptic();

    gGroupVCs = nil; gSlotCenters = nil; gGroupIdents = nil; gBaseCenters = nil;
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

    NSArray<NSNumber *> *offs = CXPageOffsets(sv);

    // При открытии Control Center сразу ставим первую страницу так, чтобы верхний ряд не залезал под статус-бар
    if (!gInitialSnapDone && !sv.isTracking && !sv.isDecelerating) {
        gInitialSnapDone = YES;
        sv.contentOffset = CGPointMake(sv.contentOffset.x, offs.firstObject.doubleValue);
    }
    CXUpdateDots(offs.count, CXNearestIndex(offs, sv.contentOffset.y));
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
        [self cx_refreshButtons];
        [UIView animateWithDuration:0.28 delay:0 options:UIViewAnimationOptionCurveEaseOut
                         animations:^{ host.alpha = 1; } completion:nil];

        // Служебная строка: помогает понять, видит ли твик прокрутку и сколько страниц получилось
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIScrollView *sv = CXFindScrollView();
            NSUInteger count = 0;
            for (UIViewController *o in gContainers.allObjects) if (o.isViewLoaded && o.view.window) count++;
            NSString *msg = sv ? [NSString stringWithFormat:@"модулей: %lu · страниц: %lu · прокрутка: да",
                                  (unsigned long)count, (unsigned long)CXPageOffsets(sv).count]
                               : [NSString stringWithFormat:@"модулей: %lu · прокрутка: не найдена", (unsigned long)count];
            CXToastFor(msg, 3.0);
        });
    } else {
        if (gSheet) [gSheet closeSheet];
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
        if (!CXIsRemovable(ident)) {
            CXHaptic();
            CXToast(@"Этот элемент закреплён, его нельзя двигать");
            return;
        }
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
        if (!CXIsRemovable(ident)) {
            CXHaptic();
            CXToast(@"Этот элемент закреплён, его нельзя двигать");
            return;
        }
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

// ---------- Раскрытие модуля по долгому нажатию в режиме редактирования запрещено ----------

%hook CCUIModuleInstanceManager

- (void)requestExpandModuleForContentModuleContext:(id)context {
    if (gEditing) return;
    %orig;
}

%end
