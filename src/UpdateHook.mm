#import "PluginConfig.h"

#include <atomic>
#import <objc/runtime.h>
#include <os/log.h>

namespace {

static os_log_t UpdateLog() {
    static os_log_t log = os_log_create("com.cleanwechat.plugin", "update");
    return log;
}

std::atomic<bool> g_updateHookReady{false};

BOOL ShouldBlockAutoUpdate() {
    return [CWPluginConfig boolForKey:kCWDisableAutoUpdateKey];
}

// 保存 XAppUpdateManager 原始 IMP 实现指针
void (*orig_startUpdater)(id, SEL) = nullptr;
void (*orig_checkForUpdates)(id, SEL, id) = nullptr;
void (*orig_startBackgroundUpdatesCheck)(id, SEL, BOOL) = nullptr;
void (*orig_enableAutoUpdate)(id, SEL, BOOL) = nullptr;
void (*orig_setAutoChecksIfNeeded)(id, SEL, id) = nullptr;
void (*orig_setAutomaticallyDownloadsUpdates)(id, SEL, BOOL) = nullptr;
void (*orig_setCanCheckForUpdate)(id, SEL, BOOL) = nullptr;
void (*orig_setShouldAlertUserForUpdate)(id, SEL, BOOL) = nullptr;
void (*orig_setShouldShowTipsBanner)(id, SEL, BOOL) = nullptr;
BOOL (*orig_automaticallyDownloadsUpdates)(id, SEL) = nullptr;
BOOL (*orig_canCheckForUpdate)(id, SEL) = nullptr;
BOOL (*orig_shouldAlertUserForUpdate)(id, SEL) = nullptr;
BOOL (*orig_shouldShowTipsBanner)(id, SEL) = nullptr;
BOOL (*orig_isUpdateReady)(id, SEL) = nullptr;
void (*orig_quitAndInstall)(id, SEL, id) = nullptr;
void (*orig_quitAndInstallExtra)(id, SEL, id, id) = nullptr;
BOOL (*orig_shouldProceedWithUpdate)(id, SEL, id, id, NSInteger, NSError * __autoreleasing *) = nullptr;
void (*orig_didFindValidUpdate)(id, SEL, id, id) = nullptr;
void (*orig_evaluateTipsBanner)(id, SEL) = nullptr;

void hook_startUpdater(id self, SEL _cmd) {
    if (ShouldBlockAutoUpdate()) {
        os_log_info(UpdateLog(), "已拦截 -[XAppUpdateManager startUpdater]");
        return;
    }
    if (orig_startUpdater) orig_startUpdater(self, _cmd);
}

void hook_checkForUpdates(id self, SEL _cmd, id sender) {
    if (ShouldBlockAutoUpdate()) {
        os_log_info(UpdateLog(), "已拦截 -[XAppUpdateManager checkForUpdates:]");
        return;
    }
    if (orig_checkForUpdates) orig_checkForUpdates(self, _cmd, sender);
}

void hook_startBackgroundUpdatesCheck(id self, SEL _cmd, BOOL force) {
    if (ShouldBlockAutoUpdate()) {
        os_log_info(UpdateLog(), "已拦截 -[XAppUpdateManager startBackgroundUpdatesCheck:]");
        return;
    }
    if (orig_startBackgroundUpdatesCheck) orig_startBackgroundUpdatesCheck(self, _cmd, force);
}

void hook_enableAutoUpdate(id self, SEL _cmd, BOOL enable) {
    if (ShouldBlockAutoUpdate()) {
        if (orig_enableAutoUpdate) orig_enableAutoUpdate(self, _cmd, NO);
        return;
    }
    if (orig_enableAutoUpdate) orig_enableAutoUpdate(self, _cmd, enable);
}

void hook_setAutoChecksIfNeeded(id self, SEL _cmd, id updater) {
    if (ShouldBlockAutoUpdate()) return;
    if (orig_setAutoChecksIfNeeded) orig_setAutoChecksIfNeeded(self, _cmd, updater);
}

void hook_setAutomaticallyDownloadsUpdates(id self, SEL _cmd, BOOL val) {
    if (orig_setAutomaticallyDownloadsUpdates) {
        orig_setAutomaticallyDownloadsUpdates(self, _cmd, ShouldBlockAutoUpdate() ? NO : val);
    }
}

void hook_setCanCheckForUpdate(id self, SEL _cmd, BOOL val) {
    if (orig_setCanCheckForUpdate) {
        orig_setCanCheckForUpdate(self, _cmd, ShouldBlockAutoUpdate() ? NO : val);
    }
}

void hook_setShouldAlertUserForUpdate(id self, SEL _cmd, BOOL val) {
    if (orig_setShouldAlertUserForUpdate) {
        orig_setShouldAlertUserForUpdate(self, _cmd, ShouldBlockAutoUpdate() ? NO : val);
    }
}

void hook_setShouldShowTipsBanner(id self, SEL _cmd, BOOL val) {
    if (orig_setShouldShowTipsBanner) {
        orig_setShouldShowTipsBanner(self, _cmd, ShouldBlockAutoUpdate() ? NO : val);
    }
}

BOOL hook_automaticallyDownloadsUpdates(id self, SEL _cmd) {
    if (ShouldBlockAutoUpdate()) return NO;
    return orig_automaticallyDownloadsUpdates ? orig_automaticallyDownloadsUpdates(self, _cmd) : NO;
}

BOOL hook_canCheckForUpdate(id self, SEL _cmd) {
    if (ShouldBlockAutoUpdate()) return NO;
    return orig_canCheckForUpdate ? orig_canCheckForUpdate(self, _cmd) : NO;
}

BOOL hook_shouldAlertUserForUpdate(id self, SEL _cmd) {
    if (ShouldBlockAutoUpdate()) return NO;
    return orig_shouldAlertUserForUpdate ? orig_shouldAlertUserForUpdate(self, _cmd) : NO;
}

BOOL hook_shouldShowTipsBanner(id self, SEL _cmd) {
    if (ShouldBlockAutoUpdate()) return NO;
    return orig_shouldShowTipsBanner ? orig_shouldShowTipsBanner(self, _cmd) : NO;
}

BOOL hook_isUpdateReady(id self, SEL _cmd) {
    if (ShouldBlockAutoUpdate()) return NO;
    return orig_isUpdateReady ? orig_isUpdateReady(self, _cmd) : NO;
}

void hook_quitAndInstall(id self, SEL _cmd, id sender) {
    if (ShouldBlockAutoUpdate()) return;
    if (orig_quitAndInstall) orig_quitAndInstall(self, _cmd, sender);
}

void hook_quitAndInstallExtra(id self, SEL _cmd, id sender, id extraInfo) {
    if (ShouldBlockAutoUpdate()) return;
    if (orig_quitAndInstallExtra) orig_quitAndInstallExtra(self, _cmd, sender, extraInfo);
}

BOOL hook_shouldProceedWithUpdate(id self, SEL _cmd, id updater, id item, NSInteger check, NSError * __autoreleasing *err) {
    if (ShouldBlockAutoUpdate()) return NO;
    return orig_shouldProceedWithUpdate ? orig_shouldProceedWithUpdate(self, _cmd, updater, item, check, err) : YES;
}

void hook_didFindValidUpdate(id self, SEL _cmd, id updater, id item) {
    if (ShouldBlockAutoUpdate()) return;
    if (orig_didFindValidUpdate) orig_didFindValidUpdate(self, _cmd, updater, item);
}

void hook_evaluateTipsBanner(id self, SEL _cmd) {
    if (ShouldBlockAutoUpdate()) return;
    if (orig_evaluateTipsBanner) orig_evaluateTipsBanner(self, _cmd);
}

template <typename FnPtr>
void ReplaceMethod(Class cls, SEL sel, FnPtr replacement, FnPtr* outOriginal) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    IMP oldImp = method_setImplementation(m, reinterpret_cast<IMP>(replacement));
    if (outOriginal) {
        *outOriginal = reinterpret_cast<FnPtr>(oldImp);
    }
}

}  // namespace

void CWInstallUpdateHooksIfNeeded(void) {
    if (g_updateHookReady.load(std::memory_order_acquire)) {
        return;
    }

    Class cls = NSClassFromString(@"XAppUpdateManager");
    if (!cls) {
        return;
    }

    static std::atomic<bool> s_hooking{false};
    if (s_hooking.exchange(true)) {
        return;
    }

    ReplaceMethod(cls, @selector(startUpdater), hook_startUpdater, &orig_startUpdater);
    ReplaceMethod(cls, @selector(checkForUpdates:), hook_checkForUpdates, &orig_checkForUpdates);
    ReplaceMethod(cls, @selector(startBackgroundUpdatesCheck:), hook_startBackgroundUpdatesCheck, &orig_startBackgroundUpdatesCheck);
    ReplaceMethod(cls, @selector(enableAutoUpdate:), hook_enableAutoUpdate, &orig_enableAutoUpdate);
    ReplaceMethod(cls, @selector(setAutomaticallyChecksForUpdatesIfNeeded:), hook_setAutoChecksIfNeeded, &orig_setAutoChecksIfNeeded);
    ReplaceMethod(cls, @selector(setAutomaticallyDownloadsUpdates:), hook_setAutomaticallyDownloadsUpdates, &orig_setAutomaticallyDownloadsUpdates);
    ReplaceMethod(cls, @selector(setCanCheckForUpdate:), hook_setCanCheckForUpdate, &orig_setCanCheckForUpdate);
    ReplaceMethod(cls, @selector(setShouldAlertUserForUpdate:), hook_setShouldAlertUserForUpdate, &orig_setShouldAlertUserForUpdate);
    ReplaceMethod(cls, @selector(setShouldShowTipsBanner:), hook_setShouldShowTipsBanner, &orig_setShouldShowTipsBanner);
    ReplaceMethod(cls, @selector(automaticallyDownloadsUpdates), hook_automaticallyDownloadsUpdates, &orig_automaticallyDownloadsUpdates);
    ReplaceMethod(cls, @selector(canCheckForUpdate), hook_canCheckForUpdate, &orig_canCheckForUpdate);
    ReplaceMethod(cls, @selector(shouldAlertUserForUpdate), hook_shouldAlertUserForUpdate, &orig_shouldAlertUserForUpdate);
    ReplaceMethod(cls, @selector(shouldShowTipsBanner), hook_shouldShowTipsBanner, &orig_shouldShowTipsBanner);
    ReplaceMethod(cls, @selector(isUpdateReady), hook_isUpdateReady, &orig_isUpdateReady);
    ReplaceMethod(cls, @selector(quitAndInstallIfNeeded:), hook_quitAndInstall, &orig_quitAndInstall);
    ReplaceMethod(cls, @selector(quitAndInstallIfNeeded:extraInfo:), hook_quitAndInstallExtra, &orig_quitAndInstallExtra);
    ReplaceMethod(cls, @selector(updater:shouldProceedWithUpdate:updateCheck:error:), hook_shouldProceedWithUpdate, &orig_shouldProceedWithUpdate);
    ReplaceMethod(cls, @selector(updater:didFindValidUpdate:), hook_didFindValidUpdate, &orig_didFindValidUpdate);
    ReplaceMethod(cls, @selector(evaluateShouldShowTipsBanner), hook_evaluateTipsBanner, &orig_evaluateTipsBanner);

    g_updateHookReady.store(true, std::memory_order_release);
    os_log_info(UpdateLog(), "XAppUpdateManager 自动更新拦截 Hook 安装完成");
}

BOOL CWIsUpdateHookReady(void) {
    return g_updateHookReady.load(std::memory_order_acquire) ? YES : NO;
}
