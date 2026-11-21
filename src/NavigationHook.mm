#import "PluginConfig.h"
#import "Arm64Hook.hpp"

#include <atomic>
#include <cstring>
#include <mach-o/dyld.h>
#include <os/log.h>

namespace {

std::atomic<bool> g_navHooksReady{false};

#if defined(__aarch64__)

static os_log_t NavLog() {
    static os_log_t log = os_log_create("com.cleanwechat.plugin", "nav");
    return log;
}

std::atomic<void*> g_sidebarController{nullptr};
std::atomic<void*> g_discoverModel{nullptr};

uintptr_t g_sidebarRefreshStart = 0;
uintptr_t g_sidebarRefreshEnd = 0;
uintptr_t g_discoverRangeStart = 0;
uintptr_t g_discoverRangeEnd = 0;

using ShouldShowDiscoverFn = uint8_t (*)(int key, int mode);
using ShouldShowSidebarFn = uint8_t (*)(int key);
using IsGameEnabledFn = uint8_t (*)();
using VoidThisFn = void (*)(void* self);
using XTabBarGetItemFn = void* (*)(void* container, int tabId);
using TabItemSetVisibleFn = void (*)(void* tabItem, uint8_t visible);

ShouldShowDiscoverFn g_origShouldShowDiscover = nullptr;
ShouldShowSidebarFn g_origShouldShowSidebar = nullptr;
IsGameEnabledFn g_origIsGameEnabled = nullptr;
VoidThisFn g_origDiscoverBuild = nullptr;
VoidThisFn g_origDiscoverRefresh = nullptr;
VoidThisFn g_origDiscoverDtor = nullptr;
VoidThisFn g_origSidebarRefresh = nullptr;
VoidThisFn g_origSidebarDtor = nullptr;
XTabBarGetItemFn g_xTabBarGetItem = nullptr;

// 微信 wechat.dylib (4.2.1 / 270596) 实测发现页与侧栏功能键值：
//   5 -> 小程序，6 -> 视频号，8 -> 搜一搜，9 -> 朋友圈
//   游戏入口通过 IsGameEnabled() -> ShouldShowSidebar(7) 控制
enum FeatureKey : int {
    kFeatureMiniProgram = 5,
    kFeatureChannels = 6,
    kFeatureSearch = 8,
    kFeatureMoments = 9,
};

uint8_t Hook_ShouldShowDiscover(int key, int mode) {
    NSString* defaultsKey = nil;
    switch (key) {
        case kFeatureMiniProgram:
            defaultsKey = kCWHideDiscoverMiniProgramKey;
            break;
        case kFeatureChannels:
            defaultsKey = kCWHideDiscoverChannelsKey;
            break;
        case kFeatureSearch:
            defaultsKey = kCWHideDiscoverSearchKey;
            break;
        case kFeatureMoments:
            defaultsKey = kCWHideDiscoverMomentsKey;
            break;
        default:
            break;
    }

    if (defaultsKey && [CWPluginConfig boolForKey:defaultsKey]) {
        return 0;
    }
    return g_origShouldShowDiscover ? g_origShouldShowDiscover(key, mode) : 1;
}

uint8_t Hook_ShouldShowSidebar(int key) {
    NSString* defaultsKey = nil;
    switch (key) {
        case kFeatureMiniProgram:
            defaultsKey = kCWHideSidebarMiniProgramKey;
            break;
        case kFeatureChannels:
            defaultsKey = kCWHideSidebarChannelsKey;
            break;
        case kFeatureSearch:
            defaultsKey = kCWHideSidebarSearchKey;
            break;
        case kFeatureMoments:
            defaultsKey = kCWHideSidebarMomentsKey;
            break;
        default:
            break;
    }

    if (defaultsKey && [CWPluginConfig boolForKey:defaultsKey]) {
        return 0;
    }
    return g_origShouldShowSidebar ? g_origShouldShowSidebar(key) : 1;
}

uint8_t Hook_IsGameEnabled() {
    const uintptr_t caller = reinterpret_cast<uintptr_t>(__builtin_return_address(0));
    if (caller >= g_sidebarRefreshStart && caller < g_sidebarRefreshEnd) {
        if ([CWPluginConfig boolForKey:kCWHideSidebarGameKey]) {
            return 0;
        }
    } else if (caller >= g_discoverRangeStart && caller < g_discoverRangeEnd) {
        if ([CWPluginConfig boolForKey:kCWHideDiscoverGameKey]) {
            return 0;
        }
    }
    return g_origIsGameEnabled ? g_origIsGameEnabled() : 0;
}

void ApplyTabVisibility(void* container, int tabId, BOOL visible) {
    if (!container || !g_xTabBarGetItem) return;
    void* tabItem = g_xTabBarGetItem(container, tabId);
    if (!tabItem) return;

    void** vtable = *reinterpret_cast<void***>(tabItem);
    if (!vtable || !vtable[13]) return;  // 虚表偏移 +0x68 对应 XTabBarItem::setVisible(bool)
    auto setVisible = reinterpret_cast<TabItemSetVisibleFn>(vtable[13]);
    setVisible(tabItem, visible ? 1 : 0);
}

void Hook_SidebarRefreshVisibility(void* self) {
    if (self) {
        g_sidebarController.store(self, std::memory_order_release);

        // 在 SidebarRefreshVisibility 末尾调用 SidebarLayoutUpdate 之前，
        // 先设置主栏「发现」图标 (id=3) 与扩展栏「更多 (…)」按钮 (id=8) 的可见性。
        void* primaryContainer = *reinterpret_cast<void**>(reinterpret_cast<uintptr_t>(self) + 0x190);
        ApplyTabVisibility(primaryContainer, 3, ![CWPluginConfig boolForKey:kCWHideSidebarDiscoverKey]);

        void* secondaryContainer = *reinterpret_cast<void**>(reinterpret_cast<uintptr_t>(self) + 0x1a0);
        ApplyTabVisibility(secondaryContainer, 8, ![CWPluginConfig boolForKey:kCWHideSidebarMoreKey]);
    }
    if (g_origSidebarRefresh) {
        g_origSidebarRefresh(self);
    }
}

void Hook_SidebarDtor(void* self) {
    void* expected = self;
    g_sidebarController.compare_exchange_strong(expected, nullptr, std::memory_order_acq_rel);
    if (g_origSidebarDtor) {
        g_origSidebarDtor(self);
    }
}

void Hook_DiscoverBuild(void* self) {
    if (self) {
        g_discoverModel.store(self, std::memory_order_release);
    }
    if (g_origDiscoverBuild) {
        g_origDiscoverBuild(self);
    }
}

void Hook_DiscoverRefresh(void* self) {
    if (self) {
        g_discoverModel.store(self, std::memory_order_release);
    }
    if (g_origDiscoverRefresh) {
        g_origDiscoverRefresh(self);
    }
}

void Hook_DiscoverDtor(void* self) {
    void* expected = self;
    g_discoverModel.compare_exchange_strong(expected, nullptr, std::memory_order_acq_rel);
    if (g_origDiscoverDtor) {
        g_origDiscoverDtor(self);
    }
}

bool IsInsideText(const CleanWeChat::LoadedImageInfo& info, uintptr_t addr) {
    const uintptr_t start = reinterpret_cast<uintptr_t>(info.textStart);
    return addr >= start && addr < start + info.textSize;
}

void InstallHooksForWeChatMain(const struct mach_header* mh) {
    if (g_navHooksReady.load(std::memory_order_acquire)) {
        return;
    }

    CleanWeChat::LoadedImageInfo info{};
    if (!CleanWeChat::InspectMachOImage(mh, &info)) {
        return;
    }

    // 仅真正的 Resources/wechat.dylib 包含超过 50 MB 的 __TEXT,__text 代码段
    // （Frameworks/wechat.dylib 壳体不足 100 KB）。先校验体积可避免不必要的 dyld 锁重入。
    if (info.textSize < (50ULL * 1024ULL * 1024ULL)) {
        return;
    }

    // 1. DiscoverModelBuildItems、ShouldShowDiscover 与 IsGameEnabled
    size_t discoverBuildHits = 0;
    const uint8_t* discoverBuildMatch = CleanWeChat::ScanPattern(
        info.textStart, info.textSize,
        "20 01 80 52 01 00 80 52 ?? ?? ?? ?? ?? ?? ?? ?? 28 00 80 52 E8 1F 00 B9",
        &discoverBuildHits);

    // 2. DiscoverModelRefresh
    size_t discoverRefreshHits = 0;
    const uint8_t* discoverRefreshMatch = CleanWeChat::ScanPattern(
        info.textStart, info.textSize,
        "?? ?? ?? ?? E0 03 13 AA ?? ?? ?? ?? 68 1E 40 F9 13 09 40 F9 00 81 C0 3C E0 03 80 3D 93 00 00 B4",
        &discoverRefreshHits);

    // 3. DiscoverModel::~DiscoverModel 析构函数
    size_t discoverDtorHits = 0;
    const uint8_t* discoverDtorMatch = CleanWeChat::ScanPattern(
        info.textStart, info.textSize,
        "FF C3 00 D1 F4 4F 01 A9 FD 7B 02 A9 FD 83 00 91 F3 03 00 AA ?? ?? ?? ?? ?? ?? ?? ?? 08 00 00 F9 08 C1 01 91 08 08 00 F9 14 90 40 F9",
        &discoverDtorHits);

    // 4. SidebarRefreshVisibility、XTabBarGetItem 与 ShouldShowSidebar
    size_t sidebarRefreshHits = 0;
    const uint8_t* sidebarRefreshMatch = CleanWeChat::ScanPattern(
        info.textStart, info.textSize,
        "F3 03 00 AA 00 D0 40 F9 ?? ?? ?? ?? C1 00 80 52 ?? ?? ?? ?? ?? ?? ?? ?? F4 03 00 AA A0 00 80 52",
        &sidebarRefreshHits);

    // 5. SidebarController::~SidebarController 析构函数
    size_t sidebarDtorHits = 0;
    const uint8_t* sidebarDtorMatch = CleanWeChat::ScanPattern(
        info.textStart, info.textSize,
        "09 54 00 F9 ?? ?? ?? ?? ?? ?? ?? ?? 09 A8 12 A9 ?? ?? ?? ?? 08 BC 00 F9 14 24 41 F9 88 02 40 B9 1F 05 00 31",
        &sidebarDtorHits);

    if (discoverBuildHits != 1 || discoverRefreshHits != 1 || discoverDtorHits != 1 ||
        sidebarRefreshHits != 1 || sidebarDtorHits != 1) {
        os_log_error(NavLog(),
                     "特征匹配未达到唯一命中 (db=%zu dr=%zu dd=%zu sr=%zu sd=%zu)，跳过导航 Hook",
                     discoverBuildHits, discoverRefreshHits, discoverDtorHits,
                     sidebarRefreshHits, sidebarDtorHits);
        return;
    }

    uintptr_t discoverBuildAddr = reinterpret_cast<uintptr_t>(discoverBuildMatch - 0x2c);
    uintptr_t discoverRefreshAddr = reinterpret_cast<uintptr_t>(discoverRefreshMatch - 0x24);
    uintptr_t discoverDtorAddr = reinterpret_cast<uintptr_t>(discoverDtorMatch);
    uintptr_t sidebarRefreshAddr = reinterpret_cast<uintptr_t>(sidebarRefreshMatch - 0x10);
    uintptr_t sidebarDtorAddr = reinterpret_cast<uintptr_t>(sidebarDtorMatch - 0x44);

    uintptr_t shouldShowDiscoverAddr = CleanWeChat::DecodeBranchTarget(discoverBuildMatch + 0x08);
    uintptr_t isGameEnabledFromDiscover = CleanWeChat::DecodeBranchTarget(
        reinterpret_cast<const void*>(discoverBuildAddr + 0x148));
    uintptr_t xTabBarGetItemAddr = CleanWeChat::DecodeBranchTarget(sidebarRefreshMatch + 0x10);
    uintptr_t shouldShowSidebarAddr = CleanWeChat::DecodeBranchTarget(sidebarRefreshMatch + 0x20);
    uintptr_t isGameEnabledFromSidebar = CleanWeChat::DecodeBranchTarget(
        reinterpret_cast<const void*>(sidebarRefreshAddr + 0x10c));

    if (!IsInsideText(info, discoverBuildAddr) ||
        !IsInsideText(info, discoverRefreshAddr) ||
        !IsInsideText(info, discoverDtorAddr) ||
        !IsInsideText(info, sidebarRefreshAddr) ||
        !IsInsideText(info, sidebarDtorAddr) ||
        !IsInsideText(info, shouldShowDiscoverAddr) ||
        !IsInsideText(info, shouldShowSidebarAddr) ||
        !IsInsideText(info, isGameEnabledFromDiscover) ||
        !IsInsideText(info, xTabBarGetItemAddr) ||
        isGameEnabledFromDiscover != isGameEnabledFromSidebar) {
        os_log_error(NavLog(), "已解析的目标地址未通过范围或一致性校验");
        return;
    }

    static std::atomic<bool> s_attempted{false};
    if (s_attempted.exchange(true)) {
        return;
    }

    g_sidebarRefreshStart = sidebarRefreshAddr;
    g_sidebarRefreshEnd = sidebarRefreshAddr + 0x180;
    g_discoverRangeStart = discoverBuildAddr - 0x400;
    g_discoverRangeEnd = discoverRefreshAddr + 0x3500;
    g_xTabBarGetItem = reinterpret_cast<XTabBarGetItemFn>(xTabBarGetItemAddr);

    CleanWeChat::InlineHookBatch batch;
    bool staged = true;
    staged &= batch.Stage(reinterpret_cast<void*>(shouldShowDiscoverAddr),
                          reinterpret_cast<void*>(&Hook_ShouldShowDiscover),
                          reinterpret_cast<void**>(&g_origShouldShowDiscover),
                          "ShouldShowDiscover");
    staged &= batch.Stage(reinterpret_cast<void*>(shouldShowSidebarAddr),
                          reinterpret_cast<void*>(&Hook_ShouldShowSidebar),
                          reinterpret_cast<void**>(&g_origShouldShowSidebar),
                          "ShouldShowSidebar");
    staged &= batch.Stage(reinterpret_cast<void*>(isGameEnabledFromDiscover),
                          reinterpret_cast<void*>(&Hook_IsGameEnabled),
                          reinterpret_cast<void**>(&g_origIsGameEnabled),
                          "IsGameEnabled");
    staged &= batch.Stage(reinterpret_cast<void*>(discoverBuildAddr),
                          reinterpret_cast<void*>(&Hook_DiscoverBuild),
                          reinterpret_cast<void**>(&g_origDiscoverBuild),
                          "DiscoverModelBuildItems");
    staged &= batch.Stage(reinterpret_cast<void*>(discoverRefreshAddr),
                          reinterpret_cast<void*>(&Hook_DiscoverRefresh),
                          reinterpret_cast<void**>(&g_origDiscoverRefresh),
                          "DiscoverModelRefresh");
    staged &= batch.Stage(reinterpret_cast<void*>(discoverDtorAddr),
                          reinterpret_cast<void*>(&Hook_DiscoverDtor),
                          reinterpret_cast<void**>(&g_origDiscoverDtor),
                          "DiscoverModelDtor");
    staged &= batch.Stage(reinterpret_cast<void*>(sidebarRefreshAddr),
                          reinterpret_cast<void*>(&Hook_SidebarRefreshVisibility),
                          reinterpret_cast<void**>(&g_origSidebarRefresh),
                          "SidebarRefreshVisibility");
    staged &= batch.Stage(reinterpret_cast<void*>(sidebarDtorAddr),
                          reinterpret_cast<void*>(&Hook_SidebarDtor),
                          reinterpret_cast<void**>(&g_origSidebarDtor),
                          "SidebarControllerDtor");

    if (staged && batch.Commit()) {
        g_navHooksReady.store(true, std::memory_order_release);
        os_log_info(NavLog(), "全部导航与发现页精简 Hook 安装完成");
    } else {
        os_log_error(NavLog(), "导航 Hook 批量提交失败");
    }
}

void OnDyldImageAdded(const struct mach_header* mh, intptr_t /* slide */) {
    InstallHooksForWeChatMain(mh);
    // wechat.dylib 映射完成后立即并在主队列再次检查安装 Objective-C 更新拦截 Hook。
    CWInstallUpdateHooksIfNeeded();
    dispatch_async(dispatch_get_main_queue(), ^{
        CWInstallUpdateHooksIfNeeded();
    });
}

#endif  // __aarch64__

}  // namespace

void CWInstallNavigationHookMonitor(void) {
#if defined(__aarch64__)
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _dyld_register_func_for_add_image(OnDyldImageAdded);
    });
#endif
}

void CWRefreshNavigationUI(void) {
#if defined(__aarch64__)
    dispatch_async(dispatch_get_main_queue(), ^{
        void* sidebar = g_sidebarController.load(std::memory_order_acquire);
        if (sidebar && g_origSidebarRefresh) {
            Hook_SidebarRefreshVisibility(sidebar);
        }
        void* discover = g_discoverModel.load(std::memory_order_acquire);
        if (discover && g_origDiscoverRefresh) {
            Hook_DiscoverRefresh(discover);
        }
    });
#endif
}

BOOL CWAreNavigationHooksReady(void) {
    return g_navHooksReady.load(std::memory_order_acquire) ? YES : NO;
}
