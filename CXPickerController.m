#import "CXPickerController.h"
#import "CXShared.h"

// ---------- Ячейка-плитка ----------

@interface CXTileCell : UICollectionViewCell
@property (nonatomic, strong) UIView *box;
@property (nonatomic, strong) UIImageView *icon;
@property (nonatomic, strong) UILabel *label;
@property (nonatomic, strong) UIImageView *check;
@end

@implementation CXTileCell

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _box = [UIView new];
        _box.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.14];
        _box.layer.cornerRadius = 17;
        _box.layer.cornerCurve = kCACornerCurveContinuous;

        _icon = [UIImageView new];
        _icon.contentMode = UIViewContentModeCenter;
        _icon.tintColor = UIColor.whiteColor;
        _icon.preferredSymbolConfiguration =
            [UIImageSymbolConfiguration configurationWithPointSize:27 weight:UIImageSymbolWeightMedium];

        _label = [UILabel new];
        _label.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
        _label.textColor = [UIColor colorWithWhite:1.0 alpha:0.88];
        _label.textAlignment = NSTextAlignmentCenter;
        _label.numberOfLines = 2;

        _check = [UIImageView new];
        _check.image = [UIImage systemImageNamed:@"checkmark.circle.fill"];
        _check.contentMode = UIViewContentModeScaleAspectFit;
        _check.hidden = YES;

        [self.contentView addSubview:_box];
        [_box addSubview:_icon];
        [self.contentView addSubview:_label];
        [self.contentView addSubview:_check];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.contentView.bounds.size.width;
    CGFloat s = MIN(w, 64);
    self.box.frame = CGRectMake((w - s) / 2, 0, s, s);
    self.icon.frame = self.box.bounds;
    self.check.frame = CGRectMake(CGRectGetMaxX(self.box.frame) - 14, -5, 22, 22);
    self.label.frame = CGRectMake(0, s + 6, w, 30);
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

    UIVisualEffectView *blur =
        [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark]];
    blur.frame = self.view.bounds;
    blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:blur];

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
        [[NSAttributedString alloc] initWithString:@"Поиск элементов"
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

- (void)closeSheet {
    UIView *v = self.view;
    if (!v.superview) return;
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
    CGFloat avail = cv.bounds.size.width - 32;
    CGFloat w = floor((avail - 3 * 6) / 4);
    return CGSizeMake(w, 64 + 6 + 30);
}

- (UICollectionReusableView *)collectionView:(UICollectionView *)cv
           viewForSupplementaryElementOfKind:(NSString *)kind
                                 atIndexPath:(NSIndexPath *)ip {
    CXHeader *h = [cv dequeueReusableSupplementaryViewOfKind:kind withReuseIdentifier:@"head" forIndexPath:ip];
    NSString *title = self.sectionTitles[ip.section];
    h.title.text = title;
    h.icon.image = [UIImage systemImageNamed:CXCategoryIcon(title)];
    return h;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)ip {
    CXTileCell *c = [cv dequeueReusableCellWithReuseIdentifier:@"tile" forIndexPath:ip];
    NSDictionary *m = [self moduleAt:ip];
    NSString *ident = m[@"id"];

    BOOL planned = CXPlanIsAdded(ident);
    BOOL already = [self.enabled containsObject:ident] && !CXPlanIsRemoved(ident);

    c.label.text = m[@"name"];
    c.icon.image = [UIImage systemImageNamed:m[@"icon"]] ?: [UIImage systemImageNamed:@"square.grid.2x2.fill"];
    c.check.hidden = !(planned || already);
    c.check.tintColor = planned ? [UIColor colorWithRed:0.20 green:0.78 blue:0.35 alpha:1.0]
                                : [UIColor colorWithWhite:1.0 alpha:0.55];
    c.box.alpha = (already && !planned) ? 0.45 : 1.0;
    c.box.backgroundColor = planned ? [UIColor colorWithRed:0.20 green:0.78 blue:0.35 alpha:0.35]
                                    : [UIColor colorWithWhite:1.0 alpha:0.14];
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
