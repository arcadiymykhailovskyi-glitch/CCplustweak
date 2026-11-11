#import <Foundation/Foundation.h>

// Читает массив идентификаторов модулей из ModuleConfiguration.plist (nil, если файла/ключа нет)
NSArray<NSString *> *CXReadModuleIDs(void);
// Записывает массив обратно. NO, если файла/ключа нет или запись не удалась
BOOL CXWriteModuleIDs(NSArray<NSString *> *ids);
// Все установленные модули: @{ @"id", @"name", @"category", @"icon" }
NSArray<NSDictionary *> *CXAvailableModules(void);
// Респринг (SpringBoard завершается и перезапускается launchd)
void CXRespring(void);

// Отложенное применение: изменения пишутся в конфиг сразу,
// а респринг делается один раз, когда нажата «Применить» / закрыт Control Center
extern NSString *const CXPendingNote;
BOOL CXHasPending(void);
void CXMarkPending(void);
void CXMarkRemoved(NSString *ident);
void CXMarkAdded(NSString *ident);
BOOL CXIsRemoved(NSString *ident);
