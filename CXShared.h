#import <Foundation/Foundation.h>

// Уведомление: план изменений (удаления / добавления / порядок) изменился
extern NSString *const CXPlanNote;

// ---------- Данные о модулях ----------
// Все доступные для добавления модули: @{ @"id", @"name", @"category", @"icon" }
NSArray<NSDictionary *> *CXAvailableModules(void);
// Всё, что сейчас включено или зафиксировано
NSSet<NSString *> *CXCurrentEnabledIDs(void);
// Модуль можно убрать (он не фиксированный)
BOOL CXIsRemovable(NSString *ident);
// Модуль можно двигать (он в пользовательском списке)
BOOL CXIsMovable(NSString *ident);
// Текущий порядок пользовательских модулей
NSArray<NSString *> *CXUserOrder(void);
// Сбросить кэш списков (вызывается при входе/выходе из режима редактирования)
void CXInvalidateCache(void);
NSString *CXShortID(NSString *ident);
NSString *CXCategoryIcon(NSString *category);
void CXDebugLog(NSString *msg);

// ---------- План изменений ----------
// Изменения копятся в памяти и записываются только по «Применить».
BOOL CXPlanHasChanges(void);
NSUInteger CXPlanCount(void);
BOOL CXPlanIsRemoved(NSString *ident);
BOOL CXPlanIsAdded(NSString *ident);
void CXPlanToggleRemove(NSString *ident);
void CXPlanToggleAdd(NSString *ident);
void CXPlanSetOrder(NSArray<NSString *> *order);
NSArray<NSString *> *CXPlanOrder(void);
void CXPlanReset(void);    // отмена всех изменений
void CXPlanCommit(void);   // записать всё и перезапустить SpringBoard
