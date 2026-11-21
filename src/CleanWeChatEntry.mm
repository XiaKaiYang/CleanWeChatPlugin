#import "PluginConfig.h"
#include <os/log.h>

__attribute__((constructor))
static void CleanWeChatPluginInit(void) {
#if defined(__aarch64__)
    [CWPluginConfig registerDefaultSettings];
    CWInstallNavigationHookMonitor();
    CWInstallUpdateHooksIfNeeded();
    CWInstallPluginMenu();
    os_log(OS_LOG_DEFAULT, "[CleanWeChat] 已加载极简微信插件 (arm64)");
#endif
}
