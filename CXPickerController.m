#import "CXPickerController.h"
#import "CXShared.h"

// ---------- Ячейка-плитка: рисуем модуль «1 в 1» ----------
//
// Плитка выглядит как сам модуль в Control Center: тёмный скруглённый квадрат с белым значком,
// высокий ползунок для яркости и громкости, большой квадрат с четырьмя кружками для «Связи»,
// широкая плитка «Фокусирование» и «Музыка» с кнопками управления. Размер плитки равен размеру модуля на сетке.

@interface CXTileCell : UICollectionViewCell
@property (nonatomic, strong) UIView *box;
@property (nonatomic, strong) UIView *art;
@property (nonatomic, strong) UILabel *label;
@property (nonatomic, strong) UIImageView *check;
@property (nonatomic, strong) CAGradientLayer *gloss;
@property (nonatomic, copy) NSString *kind;
@property (nonatomic, copy) NSString *symbol;
@property (nonatomic, assign) CGSize builtSize;
@property (nonatomic, copy) NSString *builtKind;
@property (nonatomic, copy) NSString *builtSymbol;
@end

static UIImageView *CXGlyph(NSString *name, CGFloat pt, UIColor *tint) {
    UIImageView *v = [UIImageView new];
    v.contentMode = UIViewContentModeCenter;
    v.tintColor = tint;
    v.preferredSymbolConfiguration =
        [UIImageSymbolConfiguration configurationWithPointSize:pt weight:UIImageSymbolWeightSemibold];
    v.image = [UIImage systemImageNamed:name] ?: [UIImage systemImageNamed:@"square.grid.2x2.fill"];
    return v;
}

@implementation CXTileCell

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _box = [UIView new];
        _box.backgroundColor = UIColor.clearColor;
        _box.layer.cornerCurve = kCACornerCurveContinuous;
        _box.clipsToBounds = YES;
        _box.layer.borderWidth = 0.5;
        _box.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.16].CGColor;

        // Фон плитки: тёмное «стекло» с лёгким градиентом, как у модулей Control Center
        CAGradientLayer *gloss = [CAGradientLayer layer];
        gloss.colors = @[(id)[UIColor colorWithWhite:0.40 alpha:0.96].CGColor,
                         (id)[UIColor colorWithWhite:0.24 alpha:0.96].CGColor];
        gloss.startPoint = CGPointMake(0.5, 0.0);
        gloss.endPoint = CGPointMake(0.5, 1.0);
        [_box.layer insertSublayer:gloss atIndex:0];
        _gloss = gloss;

        _art = [UIView new];
        [_box addSubview:_art];

        _label = [UILabel new];
        _label.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightSemibold];
        _label.textColor = [UIColor colorWithWhite:1.0 alpha:0.92];
        _label.textAlignment = NSTextAlignmentCenter;
        _label.numberOfLines = 2;
        _label.lineBreakMode = NSLineBreakByWordWrapping;
        _label.adjustsFontSizeToFitWidth = YES;
        _label.minimumScaleFactor = 0.78;

        _check = [UIImageView new];
        _check.image = [UIImage systemImageNamed:@"checkmark.circle.fill"];
        _check.contentMode = UIViewContentModeScaleAspectFit;
        _check.hidden = YES;

        [self.contentView addSubview:_box];
        [self.contentView addSubview:_label];
        [self.contentView addSubview:_check];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.contentView.bounds.size.width;
    CGFloat h = self.contentView.bounds.size.height;
    CGFloat boxH = MAX(20, h - 36);
    self.box.frame = CGRectMake(0, 0, w, boxH);
    self.box.layer.cornerRadius = MIN(w, boxH) * 0.27;          // скругление растёт вместе с плиткой
    self.art.frame = self.box.bounds;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.gloss.frame = self.box.bounds;
    [CATransaction commit];
    self.label.frame = CGRectMake(0, boxH + 5, w, 28);
    self.check.frame = CGRectMake(w - 14, -5, 20, 20);

    BOOL same = CGSizeEqualToSize(self.builtSize, self.box.bounds.size) &&
                [self.builtKind isEqualToString:self.kind ?: @""] &&
                [self.builtSymbol isEqualToString:self.symbol ?: @""];
    if (!same) [self rebuildArt];
}

- (void)rebuildArt {
    self.builtSize = self.box.bounds.size;
    self.builtKind = self.kind ?: @"";
    self.builtSymbol = self.symbol ?: @"";
    for (UIView *v in [self.art.subviews copy]) [v removeFromSuperview];

    CGFloat W = self.art.bounds.size.width, H = self.art.bounds.size.height;
    UIColor *white = UIColor.whiteColor;

    if ([self.kind hasPrefix:@"slider"]) {
        BOOL sun = [self.kind isEqualToString:@"slider-display"];
        UIView *fill = [[UIView alloc] initWithFrame:CGRectMake(0, H * 0.40, W, H * 0.60)];
        fill.backgroundColor = [UIColor colorWithWhite:0.97 alpha:0.96];
        [self.art addSubview:fill];
        UIImageView *g = CXGlyph(sun ? @"sun.max.fill" : @"speaker.wave.2.fill", MIN(W * 0.42, 22),
                                 [UIColor colorWithWhite:0.45 alpha:1.0]);
        g.frame = CGRectMake(0, H - W * 0.95, W, W * 0.6);
        [self.art addSubview:g];
        return;
    }

    if ([self.kind isEqualToString:@"connectivity"]) {
        CGFloat d = W * 0.38, gap = (W - 2 * d) / 3.0;
        NSArray *names = @[@"airplane", @"antenna.radiowaves.left.and.right", @"wifi", @"dot.radiowaves.left.and.right"];
        UIColor *dark = [UIColor colorWithWhite:0.16 alpha:0.9];
        UIColor *blue = [UIColor colorWithRed:0.04 green:0.52 blue:1.0 alpha:1.0];
        NSArray *colors = @[dark, dark, blue, blue];
        for (int i = 0; i < 4; i++) {
            UIView *c = [[UIView alloc] initWithFrame:CGRectMake(gap + (i % 2) * (d + gap), gap + (i / 2) * (d + gap), d, d)];
            c.backgroundColor = colors[i];
            c.layer.cornerRadius = d / 2;
            UIImageView *g = CXGlyph(names[i], d * 0.46, white);
            g.frame = c.bounds;
            [c addSubview:g];
            [self.art addSubview:c];
        }
        return;
    }

    if ([self.kind isEqualToString:@"nowplaying"]) {
        UILabel *t = [UILabel new];
        t.text = CXL(@"Не исполняется", @"Not Playing");
        t.font = [UIFont systemFontOfSize:MAX(10, W * 0.10) weight:UIFontWeightSemibold];
        t.textColor = white;
        t.adjustsFontSizeToFitWidth = YES;
        t.minimumScaleFactor = 0.7;
        t.frame = CGRectMake(W * 0.10, H * 0.12, W * 0.80, 22);
        [self.art addSubview:t];
        NSArray *names = @[@"backward.fill", @"play.fill", @"forward.fill"];
        CGFloat cw = W * 0.76 / 3.0;
        for (int i = 0; i < 3; i++) {
            UIImageView *g = CXGlyph(names[i], i == 1 ? W * 0.17 : W * 0.12, white);
            g.frame = CGRectMake(W * 0.12 + i * cw, H * 0.60, cw, H * 0.26);
            [self.art addSubview:g];
        }
        return;
    }

    if ([self.kind isEqualToString:@"focus"]) {
        CGFloat d = MIN(H * 0.62, 36);
        UIView *c = [[UIView alloc] initWithFrame:CGRectMake(H * 0.18, (H - d) / 2.0, d, d)];
        c.backgroundColor = [UIColor colorWithRed:0.37 green:0.36 blue:0.90 alpha:1.0];
        c.layer.cornerRadius = d / 2;
        UIImageView *g = CXGlyph(@"moon.fill", d * 0.5, white);
        g.frame = c.bounds;
        [c addSubview:g];
        [self.art addSubview:c];
        UILabel *t = [UILabel new];
        t.text = CXL(@"Фокусирование", @"Focus");
        t.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        t.textColor = white;
        t.adjustsFontSizeToFitWidth = YES;
        t.minimumScaleFactor = 0.7;
        t.frame = CGRectMake(CGRectGetMaxX(c.frame) + 6, 0, W - CGRectGetMaxX(c.frame) - 10, H);
        [self.art addSubview:t];
        return;
    }

    // Обычный модуль: тёмная плитка с белым значком посередине
    UIImageView *g = CXGlyph(self.symbol ?: @"square.grid.2x2.fill", MIN(W * 0.40, 24), white);
    g.frame = self.art.bounds;
    [self.art addSubview:g];
}

@end

// ---------- Заголовок секции ----------

@interface CXHeader : UICollectionReusableView
@property (nonatomic, strong) UIImageView *icon;
@property (nonatomic, strong) UILabel *title;
@end

@implementation CXHeader

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _icon = [UIImageView new];
        _icon.tintColor = UIColor.whiteColor;
        _icon.contentMode = UIViewContentModeScaleAspectFit;
        _title = [UILabel new];
        _title.font = [UIFont systemFontOfSize:19 weight:UIFontWeightBold];
        _title.textColor = UIColor.whiteColor;
        [self addSubview:_icon];
        [self addSubview:_title];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.icon.frame = CGRectMake(18, 10, 24, 24);
    self.title.frame = CGRectMake(50, 8, self.bounds.size.width - 66, 28);
}

@end

// ---------- Шторка ----------

@interface CXPickerController () <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UISearchBarDelegate>
@property (nonatomic, strong) UIView *header;
@property (nonatomic, strong) UISearchBar *search;
@property (nonatomic, strong) UICollectionView *grid;
@property (nonatomic, strong) UIView *backdrop;
@property (nonatomic, copy) NSArray<NSDictionary *> *all;
@property (nonatomic, copy) NSSet<NSString *> *enabled;
@property (nonatomic, copy) NSArray<NSString *> *sectionTitles;
@property (nonatomic, copy) NSDictionary<NSString *, NSArray<NSDictionary *> *> *sections;
@property (nonatomic, assign) CGRect compactFrame;
@property (nonatomic, assign) CGRect expandedFrame;
@property (nonatomic, assign) BOOL expanded;
@property (nonatomic, assign) CGFloat panStartY;
@end

@implementation CXPickerController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = UIColor.clearColor;
    self.view.clipsToBounds = YES;
    self.view.layer.cornerRadius = 24;
    self.view.layer.cornerCurve = kCACornerCurveContinuous;
    self.view.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;

    // Фон шторки: плотный тёмный, без размытия (размытие смотрелось грязно и слепило)
    UIView *bg = [[UIView alloc] initWithFrame:self.view.bounds];
    bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    bg.backgroundColor = [UIColor colorWithRed:0.10 green:0.10 blue:0.12 alpha:0.97];
    [self.view addSubview:bg];

    self.all = CXAvailableModules();
    self.enabled = CXCurrentEnabledIDs();

    // Верхняя полоса: «ручка» + поиск (за неё шторку можно тянуть)
    self.header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 70)];
    self.header.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:self.header];

    UIView *grabber = [[UIView alloc] initWithFrame:CGRectMake(0, 8, 38, 5)];
    grabber.center = CGPointMake(self.view.bounds.size.width / 2, 10);
    grabber.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    grabber.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.35];
    grabber.layer.cornerRadius = 2.5;
    [self.header addSubview:grabber];

    self.search = [[UISearchBar alloc] initWithFrame:CGRectMake(8, 20, self.view.bounds.size.width - 16, 44)];
    self.search.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.search.searchBarStyle = UISearchBarStyleMinimal;
    self.search.delegate = self;
    self.search.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.search.searchTextField.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.16];
    self.search.searchTextField.textColor = UIColor.whiteColor;
    self.search.searchTextField.attributedPlaceholder =
        [[NSAttributedString alloc] initWithString:CXL(@"Поиск элементов", @"Search controls")
                                        attributes:@{ NSForegroundColorAttributeName: [UIColor colorWithWhite:1.0 alpha:0.55] }];
    [self.header addSubview:self.search];

    [self.header addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(headerPan:)]];

    // Сетка с плитками
    UICollectionViewFlowLayout *layout = [UICollectionViewFlowLayout new];
    layout.minimumInteritemSpacing = 6;
    layout.minimumLineSpacing = 14;
    layout.sectionInset = UIEdgeInsetsMake(2, 16, 14, 16);
    layout.headerReferenceSize = CGSizeMake(0, 44);

    CGRect gf = CGRectMake(0, 70, self.view.bounds.size.width, self.view.bounds.size.height - 70);
    self.grid = [[UICollectionView alloc] initWithFrame:gf collectionViewLayout:layout];
    self.grid.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.grid.backgroundColor = UIColor.clearColor;
    self.grid.dataSource = self;
    self.grid.delegate = self;
    self.grid.alwaysBounceVertical = YES;
    self.grid.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.grid.contentInset = UIEdgeInsetsMake(0, 0, 24, 0);
    [self.grid registerClass:CXTileCell.class forCellWithReuseIdentifier:@"tile"];
    [self.grid registerClass:CXHeader.class
  forSupplementaryViewOfKind:UICollectionElementKindSectionHeader
         withReuseIdentifier:@"head"];
    [self.view addSubview:self.grid];

    [self rebuildWithQuery:nil];
}

// ---------- Показ / скрытие ----------

- (void)showInView:(UIView *)host parent:(UIViewController *)parent {
    [parent addChildViewController:self];

    CGRect b = host.bounds;
    CGFloat h = floor(b.size.height * 0.64);
    CGFloat top = MAX(host.safeAreaInsets.top, 20) + 10;
    self.compactFrame = CGRectMake(0, b.size.height - h, b.size.width, h);
    self.expandedFrame = CGRectMake(0, top, b.size.width, b.size.height - top);

    UIView *back = [[UIView alloc] initWithFrame:b];
    back.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    back.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.38];
    back.alpha = 0;
    [back addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(closeSheet)]];
    self.backdrop = back;
    [host addSubview:back];

    self.view.frame = CGRectMake(0, b.size.height, b.size.width, h);
    [host addSubview:self.view];
    [self didMoveToParentViewController:parent];

    [UIView animateWithDuration:0.5 delay:0 usingSpringWithDamping:0.86 initialSpringVelocity:0.3
                        options:UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        back.alpha = 1;
        self.view.frame = self.compactFrame;
    } completion:nil];
}

- (void)setExpanded:(BOOL)e animated:(BOOL)animated {
    self.expanded = e;
    CGRect f = e ? self.expandedFrame : self.compactFrame;
    void (^change)(void) = ^{ self.view.frame = f; };
    if (animated) {
        [UIView animateWithDuration:0.4 delay:0 usingSpringWithDamping:0.88 initialSpringVelocity:0.2
                            options:UIViewAnimationOptionAllowUserInteraction animations:change completion:nil];
    } else {
        change();
    }
}

- (void)forceClose {
    [self.search resignFirstResponder];
    [self.backdrop removeFromSuperview];
    [self.view removeFromSuperview];
    [self willMoveToParentViewController:nil];
    [self removeFromParentViewController];
    void (^cb)(void) = self.onClose;
    self.onClose = nil;
    if (cb) cb();
}

- (void)closeSheet {
    UIView *v = self.view;
    if (!v.superview) { [self forceClose]; return; }   // иначе шторка «залипала» и «+» переставал работать
    [self.search resignFirstResponder];
    [UIView animateWithDuration:0.28 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
        v.frame = CGRectMake(0, v.superview.bounds.size.height, v.frame.size.width, v.frame.size.height);
        self.backdrop.alpha = 0;
    } completion:^(BOOL finished) {
        [self willMoveToParentViewController:nil];
        [self.backdrop removeFromSuperview];
        [v removeFromSuperview];
        [self removeFromParentViewController];
        if (self.onClose) self.onClose();
    }];
}

- (void)headerPan:(UIPanGestureRecognizer *)g {
    UIView *v = self.view;
    UIView *sup = v.superview;
    if (!sup) return;
    CGFloat dy = [g translationInView:sup].y;

    if (g.state == UIGestureRecognizerStateBegan) {
        self.panStartY = v.frame.origin.y;
    } else if (g.state == UIGestureRecognizerStateChanged) {
        CGRect f = v.frame;
        f.origin.y = MAX(self.expandedFrame.origin.y, self.panStartY + dy);
        v.frame = f;
    } else if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        CGFloat vy = [g velocityInView:sup].y;
        CGFloat moved = v.frame.origin.y - self.panStartY;
        if (moved > 90 || vy > 900) {
            [self closeSheet];
        } else if (moved < -50 || vy < -900) {
            [self setExpanded:YES animated:YES];
        } else {
            [self setExpanded:self.expanded animated:YES];
        }
    }
}

// ---------- Данные ----------

- (void)rebuildWithQuery:(NSString *)q {
    NSMutableDictionary<NSString *, NSMutableArray *> *groups = [NSMutableDictionary new];
    for (NSDictionary *m in self.all) {
        if (q.length && [m[@"name"] rangeOfString:q options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
        NSMutableArray *list = groups[m[@"category"]];
        if (!list) { list = [NSMutableArray new]; groups[m[@"category"]] = list; }
        [list addObject:m];
    }
    NSArray *order = @[@"Захват", @"Часы", @"Связь", @"Экран и звук", @"Фокус и питание",
                       @"Медиа", @"Универсальный доступ", @"Дом", @"Другое"];
    NSMutableArray *titles = [NSMutableArray new];
    for (NSString *t in order) if (groups[t]) [titles addObject:t];
    self.sections = groups;
    self.sectionTitles = titles;
    [self.grid reloadData];
}

- (NSDictionary *)moduleAt:(NSIndexPath *)ip {
    return self.sections[self.sectionTitles[ip.section]][ip.item];
}

// ---------- Поиск ----------

- (void)searchBar:(UISearchBar *)bar textDidChange:(NSString *)text {
    [self rebuildWithQuery:text];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)bar {
    [bar resignFirstResponder];
}

- (void)searchBarTextDidBeginEditing:(UISearchBar *)bar {
    [self setExpanded:YES animated:YES];
    UIEdgeInsets i = self.grid.contentInset;
    i.bottom = 300;
    self.grid.contentInset = i;
}

- (void)searchBarTextDidEndEditing:(UISearchBar *)bar {
    UIEdgeInsets i = self.grid.contentInset;
    i.bottom = 24;
    self.grid.contentInset = i;
}

// ---------- Сетка ----------

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)cv {
    return self.sectionTitles.count;
}

- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)s {
    return self.sections[self.sectionTitles[s]].count;
}

- (CGSize)collectionView:(UICollectionView *)cv layout:(UICollectionViewLayout *)l sizeForItemAtIndexPath:(NSIndexPath *)ip {
    NSDictionary *m = [self moduleAt:ip];
    CGFloat avail = cv.bounds.size.width - 32;
    CGFloat gap = 6;
    CGFloat u = floor((avail - 5 * gap) / 6);          // ширина одной «клетки»: плитки мельче реальных, пропорции те же
    CGFloat uh = floor(u * 0.92);                        // высота одной «клетки»
    NSInteger cs = [m[@"cs"] integerValue];
    NSInteger rs = [m[@"rs"] integerValue];
    if (cs < 1) cs = 1;
    if (rs < 1) rs = 1;
    cs = MIN(cs, 6);
    rs = MIN(rs, 3);
    CGFloat w = cs * u + (cs - 1) * gap;
    CGFloat boxH = rs * uh + (rs - 1) * gap;
    return CGSizeMake(w, boxH + 36);
}

- (UICollectionReusableView *)collectionView:(UICollectionView *)cv
           viewForSupplementaryElementOfKind:(NSString *)kind
                                 atIndexPath:(NSIndexPath *)ip {
    CXHeader *h = [cv dequeueReusableSupplementaryViewOfKind:kind withReuseIdentifier:@"head" forIndexPath:ip];
    NSString *title = self.sectionTitles[ip.section];
    h.title.text = CXCategoryTitle(title);
    h.icon.image = [UIImage systemImageNamed:CXCategoryIcon(title)];
    return h;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)ip {
    CXTileCell *c = [cv dequeueReusableCellWithReuseIdentifier:@"tile" forIndexPath:ip];
    NSDictionary *m = [self moduleAt:ip];
    NSString *ident = m[@"id"];

    BOOL planned = CXPlanIsAdded(ident);
    BOOL already = [self.enabled containsObject:ident] && !CXPlanIsRemoved(ident);

    c.kind = m[@"kind"] ?: @"icon";
    c.symbol = m[@"icon"];
    c.label.text = m[@"name"];
    c.check.hidden = !(planned || already);
    c.check.tintColor = planned ? [UIColor colorWithRed:0.20 green:0.78 blue:0.35 alpha:1.0]
                                : [UIColor colorWithWhite:1.0 alpha:0.7];
    c.box.alpha = (already && !planned) ? 0.45 : 1.0;
    c.box.layer.borderWidth = planned ? 2.0 : 0.5;
    c.box.layer.borderColor = (planned ? [UIColor colorWithRed:0.20 green:0.78 blue:0.35 alpha:1.0]
                                       : [UIColor colorWithWhite:1.0 alpha:0.16]).CGColor;
    [c setNeedsLayout];
    return c;
}

- (void)collectionView:(UICollectionView *)cv didSelectItemAtIndexPath:(NSIndexPath *)ip {
    NSDictionary *m = [self moduleAt:ip];
    NSString *ident = m[@"id"];

    BOOL planned = CXPlanIsAdded(ident);
    BOOL removedInPlan = CXPlanIsRemoved(ident);
    BOOL already = [self.enabled containsObject:ident] && !removedInPlan;
    if (already && !planned) return;                  // этот элемент уже на экране

    CXPlanToggleAdd(ident);                           // добавить / убрать из плана / вернуть убранный

    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    [cv reloadItemsAtIndexPaths:@[ip]];
    dispatch_async(dispatch_get_main_queue(), ^{
        CXTileCell *cell = (CXTileCell *)[cv cellForItemAtIndexPath:ip];
        if (!cell) return;
        cell.box.transform = CGAffineTransformMakeScale(0.86, 0.86);
        [UIView animateWithDuration:0.45 delay:0 usingSpringWithDamping:0.5 initialSpringVelocity:0.8
                            options:0 animations:^{ cell.box.transform = CGAffineTransformIdentity; } completion:nil];
    });
}

@end
