#import "CXPickerController.h"
#import "CXShared.h"

@interface CXPickerController () <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate>
@property (nonatomic, strong) UISearchBar *search;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, copy) NSArray<NSDictionary *> *all;
@property (nonatomic, copy) NSSet<NSString *> *current;
@property (nonatomic, copy) NSArray<NSString *> *sectionTitles;
@property (nonatomic, copy) NSDictionary<NSString *, NSArray<NSDictionary *> *> *sections;
@end

@implementation CXPickerController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = [UIColor colorWithWhite:0.11 alpha:1.0];

    self.all = CXAvailableModules();
    self.current = CXCurrentEnabledIDs();

    self.search = [UISearchBar new];
    self.search.placeholder = @"Поиск элементов";
    self.search.searchBarStyle = UISearchBarStyleMinimal;
    self.search.delegate = self;
    self.search.translatesAutoresizingMaskIntoConstraints = NO;

    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.backgroundColor = UIColor.clearColor;
    self.table.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.table.translatesAutoresizingMaskIntoConstraints = NO;

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:26 weight:UIImageSymbolWeightRegular];
    [close setImage:[UIImage systemImageNamed:@"xmark.circle.fill" withConfiguration:cfg] forState:UIControlStateNormal];
    close.tintColor = [UIColor colorWithWhite:1.0 alpha:0.45];
    [close addTarget:self action:@selector(closeSheet) forControlEvents:UIControlEventTouchUpInside];
    close.translatesAutoresizingMaskIntoConstraints = NO;

    [self.view addSubview:self.search];
    [self.view addSubview:close];
    [self.view addSubview:self.table];

    [NSLayoutConstraint activateConstraints:@[
        [close.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:12],
        [close.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [close.widthAnchor constraintEqualToConstant:34],
        [close.heightAnchor constraintEqualToConstant:34],
        [self.search.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:8],
        [self.search.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [self.search.trailingAnchor constraintEqualToAnchor:close.leadingAnchor constant:-4],
        [self.table.topAnchor constraintEqualToAnchor:self.search.bottomAnchor],
        [self.table.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.table.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.table.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    [self rebuildWithQuery:nil];
}

- (void)rebuildWithQuery:(NSString *)q {
    NSMutableDictionary<NSString *, NSMutableArray *> *groups = [NSMutableDictionary new];
    for (NSDictionary *m in self.all) {
        if (q.length && [m[@"name"] rangeOfString:q options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
        NSMutableArray *list = groups[m[@"category"]];
        if (!list) { list = [NSMutableArray new]; groups[m[@"category"]] = list; }
        [list addObject:m];
    }
    self.sections = groups;
    self.sectionTitles = [groups.allKeys sortedArrayUsingSelector:@selector(localizedCompare:)];
    [self.table reloadData];
}

- (NSDictionary *)moduleAt:(NSIndexPath *)ip {
    return self.sections[self.sectionTitles[ip.section]][ip.row];
}

#pragma mark - Search

- (void)searchBar:(UISearchBar *)bar textDidChange:(NSString *)text {
    [self rebuildWithQuery:text];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)bar {
    [bar resignFirstResponder];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    return self.sectionTitles.count;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return self.sections[self.sectionTitles[s]].count;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return self.sectionTitles[s];
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *rid = @"cx";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:rid]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:rid];
    NSDictionary *m = [self moduleAt:ip];
    BOOL added = [self.current containsObject:m[@"id"]];

    c.textLabel.text = m[@"name"];
    c.textLabel.textColor = added ? UIColor.secondaryLabelColor : UIColor.labelColor;
    c.imageView.image = [UIImage systemImageNamed:m[@"icon"]];
    c.imageView.tintColor = UIColor.whiteColor;
    c.accessoryType = added ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    c.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSDictionary *m = [self moduleAt:ip];
    if ([self.current containsObject:m[@"id"]]) return; // уже добавлен

    NSString *res = CXAddModule(m[@"id"]);
    CXDebugLog(res);

    // Респринга здесь нет: можно добавить несколько модулей подряд.
    // Применится по кнопке «Применить» в Control Center.
    CXMarkAdded(m[@"id"]);
    self.current = [self.current setByAddingObject:m[@"id"]];
    [tv reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
}

- (void)fail:(NSString *)msg {
    NSLog(@"[CCPlus] %@", msg);
    self.search.placeholder = msg;
}

- (void)closeSheet {
    UIView *v = self.view;
    if (!v.superview) return;
    [self.search resignFirstResponder];
    CGRect f = v.frame;
    f.origin.y = v.superview.bounds.size.height;
    [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
        v.frame = f;
    } completion:^(BOOL done) {
        [self willMoveToParentViewController:nil];
        [v removeFromSuperview];
        [self removeFromParentViewController];
        if (self.onClose) self.onClose();
    }];
}

@end
