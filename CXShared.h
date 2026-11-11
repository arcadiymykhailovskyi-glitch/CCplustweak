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

// Диагностика (показывается маленькой панелью внизу в режиме редактирования)
extern NSString *const CXDebugNote;
void CXDebugLog(NSString *msg);
NSString *CXLastDebug(void);
NSString *CXConfigSummary(void);
NSString *CXShortID(NSString *ident);
// Находит в списке идентификатор, соответствующий ident (точно или по хвосту), иначе nil
NSString *CXMatchModuleID(NSString *ident, NSArray<NSString *> *ids);
// Подробный отчёт для отладки (конфиг, список файлов, показанные модули, рантайм-данные CC)
NSString *CXBuildReport(NSArray<NSString *> *shownIDs);

// Официальный путь изменения списка модулей (через CCSModuleSettingsProvider + живое обновление менеджера)
// ok = YES, если модуль можно было убрать. Возвращает строку-отчёт для панели.
NSString *CXRemoveModule(NSString *ident, BOOL *ok);
NSString *CXAddModule(NSString *ident);
// Всё, что сейчас включено/зафиксировано (live + настройки)
NSSet<NSString *> *CXCurrentEnabledIDs(void);
