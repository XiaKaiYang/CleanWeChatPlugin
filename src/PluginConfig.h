#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// NSUserDefaults 配置键名（原生持久化存储于 macOS 微信用户偏好设置中）
extern NSString *const kCWHideSidebarDiscoverKey;
extern NSString *const kCWHideSidebarMomentsKey;
extern NSString *const kCWHideSidebarChannelsKey;
extern NSString *const kCWHideSidebarSearchKey;
extern NSString *const kCWHideSidebarMiniProgramKey;
extern NSString *const kCWHideSidebarGameKey;
extern NSString *const kCWHideSidebarMoreKey;

extern NSString *const kCWHideDiscoverMomentsKey;
extern NSString *const kCWHideDiscoverChannelsKey;
extern NSString *const kCWHideDiscoverSearchKey;
extern NSString *const kCWHideDiscoverGameKey;
extern NSString *const kCWHideDiscoverMiniProgramKey;

extern NSString *const kCWDisableAutoUpdateKey;

@interface CWPluginConfig : NSObject

+ (void)registerDefaultSettings;
+ (BOOL)boolForKey:(NSString *)key;
+ (void)setBool:(BOOL)value forKey:(NSString *)key;
+ (void)resetAllToShow;

@end

// 分别实现于 NavigationHook.mm / UpdateHook.mm / PluginMenu.mm
FOUNDATION_EXTERN void CWInstallNavigationHookMonitor(void);
FOUNDATION_EXTERN void CWRefreshNavigationUI(void);
FOUNDATION_EXTERN BOOL CWAreNavigationHooksReady(void);

FOUNDATION_EXTERN void CWInstallUpdateHooksIfNeeded(void);
FOUNDATION_EXTERN BOOL CWIsUpdateHookReady(void);

FOUNDATION_EXTERN void CWInstallPluginMenu(void);

NS_ASSUME_NONNULL_END
