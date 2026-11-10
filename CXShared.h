#import <Foundation/Foundation.h>

// Читает массив идентификаторов модулей из ModuleConfiguration.plist (nil, если файла/ключа нет)
NSArray<NSString *> *CXReadModuleIDs(void);
// Записывает массив обратно. NO, если файла/ключа нет или запись не удалась
BOOL CXWriteModuleIDs(NSArray<NSString *> *ids);
// Все установленные модули: @{ @"id", @"name", @"category", @"icon" }
NSArray<NSDictionary *> *CXAvailableModules(void);
// Респринг (SpringBoard завершается и перезапускается launchd)
void CXRespring(void);
