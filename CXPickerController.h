#import <UIKit/UIKit.h>

@interface CXPickerController : UIViewController
// Вызывается, когда шторку закрыли
@property (nonatomic, copy) void (^onClose)(void);
- (void)closeSheet;
@end
