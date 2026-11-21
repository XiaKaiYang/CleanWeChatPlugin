#import "PluginConfig.h"
#import <Cocoa/Cocoa.h>

static NSInteger const kCWMenuTag = 0x43574D55;  // 'CWMU'

@interface CWMenuController : NSObject <NSMenuDelegate>
@property(nonatomic, weak) NSMenuItem *statusItem;
@property(nonatomic, strong) NSArray<NSMenuItem *> *toggleItems;
+ (instancetype)sharedController;
- (void)attachMenuIfNeeded;
@end

@implementation CWMenuController

+ (instancetype)sharedController {
    static CWMenuController *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[CWMenuController alloc] init];
    });
    return instance;
}

- (NSMenuItem *)makeToggleItemWithTitle:(NSString *)title key:(NSString *)key {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                  action:@selector(onToggleOption:)
                                           keyEquivalent:@""];
    item.target = self;
    item.representedObject = key;
    item.state = [CWPluginConfig boolForKey:key] ? NSControlStateValueOn : NSControlStateValueOff;
    return item;
}

- (NSMenuItem *)makeSectionHeader:(NSString *)title {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
    item.enabled = NO;
    return item;
}

- (NSMenu *)buildSubmenu {
    NSMenu *submenu = [[NSMenu alloc] initWithTitle:@"极简微信"];
    submenu.delegate = self;

    NSMenuItem *status = [self makeSectionHeader:@"CleanWeChat · 初始化中…"];
    self.statusItem = status;
    [submenu addItem:status];
    [submenu addItem:[NSMenuItem separatorItem]];

    NSMutableArray<NSMenuItem *> *toggles = [NSMutableArray array];

    [submenu addItem:[self makeSectionHeader:@"—— 侧边栏精简 ——"]];
    NSArray<NSArray<NSString *> *> *sidebarEntries = @[
        @[@"隐藏侧栏「发现」图标", kCWHideSidebarDiscoverKey],
        @[@"隐藏侧栏「朋友圈」", kCWHideSidebarMomentsKey],
        @[@"隐藏侧栏「视频号」", kCWHideSidebarChannelsKey],
        @[@"隐藏侧栏「搜一搜」", kCWHideSidebarSearchKey],
        @[@"隐藏侧栏「游戏」", kCWHideSidebarGameKey],
        @[@"隐藏侧栏「小程序」", kCWHideSidebarMiniProgramKey],
        @[@"隐藏侧栏「更多 (…)」", kCWHideSidebarMoreKey],
    ];
    for (NSArray<NSString *> *pair in sidebarEntries) {
        NSMenuItem *item = [self makeToggleItemWithTitle:pair[0] key:pair[1]];
        [toggles addObject:item];
        [submenu addItem:item];
    }

    [submenu addItem:[NSMenuItem separatorItem]];
    [submenu addItem:[self makeSectionHeader:@"—— 发现页精简 ——"]];
    NSArray<NSArray<NSString *> *> *discoverEntries = @[
        @[@"隐藏发现页「视频号」", kCWHideDiscoverChannelsKey],
        @[@"隐藏发现页「搜一搜」", kCWHideDiscoverSearchKey],
        @[@"隐藏发现页「游戏」", kCWHideDiscoverGameKey],
        @[@"隐藏发现页「小程序」", kCWHideDiscoverMiniProgramKey],
        @[@"隐藏发现页「朋友圈」", kCWHideDiscoverMomentsKey],
    ];
    for (NSArray<NSString *> *pair in discoverEntries) {
        NSMenuItem *item = [self makeToggleItemWithTitle:pair[0] key:pair[1]];
        [toggles addObject:item];
        [submenu addItem:item];
    }

    [submenu addItem:[NSMenuItem separatorItem]];
    [submenu addItem:[self makeSectionHeader:@"—— 系统 ——"]];
    NSMenuItem *updateItem = [self makeToggleItemWithTitle:@"禁止微信自动更新 (建议重启生效)"
                                                       key:kCWDisableAutoUpdateKey];
    [toggles addObject:updateItem];
    [submenu addItem:updateItem];

    [submenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *refreshNow = [[NSMenuItem alloc] initWithTitle:@"立即刷新侧栏与发现页"
                                                        action:@selector(onRefreshUI:)
                                                 keyEquivalent:@""];
    refreshNow.target = self;
    [submenu addItem:refreshNow];

    NSMenuItem *resetItem = [[NSMenuItem alloc] initWithTitle:@"恢复显示全部入口"
                                                       action:@selector(onResetAll:)
                                                keyEquivalent:@""];
    resetItem.target = self;
    [submenu addItem:resetItem];

    self.toggleItems = [toggles copy];
    return submenu;
}

- (void)attachMenuIfNeeded {
    NSMenu *mainMenu = [NSApp mainMenu];
    if (!mainMenu || mainMenu.numberOfItems == 0) {
        return;
    }

    for (NSMenuItem *existing in mainMenu.itemArray) {
        if (existing.tag == kCWMenuTag) {
            return;
        }
    }

    NSMenuItem *topItem = [[NSMenuItem alloc] initWithTitle:@"极简微信" action:nil keyEquivalent:@""];
    topItem.tag = kCWMenuTag;
    topItem.submenu = [self buildSubmenu];
    [mainMenu addItem:topItem];
}

#pragma mark - NSMenuDelegate

- (void)menuNeedsUpdate:(NSMenu *)menu {
    (void)menu;
    BOOL navReady = CWAreNavigationHooksReady();
    BOOL updReady = CWIsUpdateHookReady();
    self.statusItem.title = [NSString stringWithFormat:@"CleanWeChat v1.0 · 导航:%@ · 更新拦截:%@",
                             navReady ? @"已就绪" : @"未匹配",
                             updReady ? @"已就绪" : @"未加载"];

    for (NSMenuItem *item in self.toggleItems) {
        NSString *key = item.representedObject;
        if ([key isKindOfClass:[NSString class]]) {
            item.state = [CWPluginConfig boolForKey:key] ? NSControlStateValueOn : NSControlStateValueOff;
        }
    }
}

#pragma mark - Actions

- (void)onToggleOption:(NSMenuItem *)sender {
    NSString *key = sender.representedObject;
    if (![key isKindOfClass:[NSString class]]) return;

    BOOL nextValue = ![CWPluginConfig boolForKey:key];
    [CWPluginConfig setBool:nextValue forKey:key];
    sender.state = nextValue ? NSControlStateValueOn : NSControlStateValueOff;

    if (![key isEqualToString:kCWDisableAutoUpdateKey]) {
        CWRefreshNavigationUI();
    }
}

- (void)onRefreshUI:(id)sender {
    (void)sender;
    CWRefreshNavigationUI();
}

- (void)onResetAll:(id)sender {
    (void)sender;
    [CWPluginConfig resetAllToShow];
    CWRefreshNavigationUI();
}

@end

void CWInstallPluginMenu(void) {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserverForName:NSApplicationDidFinishLaunchingNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification * _Nonnull note) {
        (void)note;
        [[CWMenuController sharedController] attachMenuIfNeeded];
    }];

    [nc addObserverForName:NSApplicationDidBecomeActiveNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification * _Nonnull note) {
        (void)note;
        [[CWMenuController sharedController] attachMenuIfNeeded];
    }];

    // 短暂延时重试，防止 Qt 在启动稍晚阶段重建 NSApp.mainMenu。
    double delays[] = {0.5, 1.5, 3.5, 6.0};
    for (double delay : delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [[CWMenuController sharedController] attachMenuIfNeeded];
        });
    }
}
