#import <UIKit/UIKit.h>

// Нижняя шторка «Поиск элементов» в стиле iOS 18
@interface CXPickerController : UIViewController
@property (nonatomic, copy) void (^onClose)(void);
- (void)showInView:(UIView *)host parent:(UIViewController *)parent;
- (void)closeSheet;
@end
