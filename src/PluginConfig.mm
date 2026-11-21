#import "PluginConfig.h"

NSString *const kCWHideSidebarDiscoverKey = @"CleanWeChat_HideSidebarDiscover";
NSString *const kCWHideSidebarMomentsKey = @"CleanWeChat_HideSidebarMoments";
NSString *const kCWHideSidebarChannelsKey = @"CleanWeChat_HideSidebarChannels";
NSString *const kCWHideSidebarSearchKey = @"CleanWeChat_HideSidebarSearch";
NSString *const kCWHideSidebarMiniProgramKey = @"CleanWeChat_HideSidebarMiniProgram";
NSString *const kCWHideSidebarGameKey = @"CleanWeChat_HideSidebarGame";
NSString *const kCWHideSidebarMoreKey = @"CleanWeChat_HideSidebarMore";

NSString *const kCWHideDiscoverMomentsKey = @"CleanWeChat_HideDiscoverMoments";
NSString *const kCWHideDiscoverChannelsKey = @"CleanWeChat_HideDiscoverChannels";
NSString *const kCWHideDiscoverSearchKey = @"CleanWeChat_HideDiscoverSearch";
NSString *const kCWHideDiscoverGameKey = @"CleanWeChat_HideDiscoverGame";
NSString *const kCWHideDiscoverMiniProgramKey = @"CleanWeChat_HideDiscoverMiniProgram";

NSString *const kCWDisableAutoUpdateKey = @"CleanWeChat_DisableAutoUpdate";

@implementation CWPluginConfig

+ (void)registerDefaultSettings {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSDictionary<NSString *, id> *defaults = @{
            // 侧边栏默认项：隐藏冗余功能标签，保留发现入口与朋友圈按需显示。
            kCWHideSidebarDiscoverKey: @NO,
            kCWHideSidebarMomentsKey: @NO,
            kCWHideSidebarChannelsKey: @YES,
            kCWHideSidebarSearchKey: @YES,
            kCWHideSidebarMiniProgramKey: @YES,
            kCWHideSidebarGameKey: @YES,
            kCWHideSidebarMoreKey: @NO,

            // 发现页默认项：保留朋友圈，隐藏视频号 / 搜一搜 / 游戏 / 小程序。
            kCWHideDiscoverMomentsKey: @NO,
            kCWHideDiscoverChannelsKey: @YES,
            kCWHideDiscoverSearchKey: @YES,
            kCWHideDiscoverGameKey: @YES,
            kCWHideDiscoverMiniProgramKey: @YES,

            // 默认开启禁止微信自动更新。
            kCWDisableAutoUpdateKey: @YES,
        };
        [[NSUserDefaults standardUserDefaults] registerDefaults:defaults];
    });
}

+ (BOOL)boolForKey:(NSString *)key {
    [self registerDefaultSettings];
    return [[NSUserDefaults standardUserDefaults] boolForKey:key];
}

+ (void)setBool:(BOOL)value forKey:(NSString *)key {
    [self registerDefaultSettings];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:value forKey:key];
    [defaults synchronize];
}

+ (void)resetAllToShow {
    NSArray<NSString *> *hideKeys = @[
        kCWHideSidebarDiscoverKey,
        kCWHideSidebarMomentsKey,
        kCWHideSidebarChannelsKey,
        kCWHideSidebarSearchKey,
        kCWHideSidebarMiniProgramKey,
        kCWHideSidebarGameKey,
        kCWHideSidebarMoreKey,
        kCWHideDiscoverMomentsKey,
        kCWHideDiscoverChannelsKey,
        kCWHideDiscoverSearchKey,
        kCWHideDiscoverGameKey,
        kCWHideDiscoverMiniProgramKey,
    ];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    for (NSString *key in hideKeys) {
        [defaults setBool:NO forKey:key];
    }
    [defaults synchronize];
}

@end
