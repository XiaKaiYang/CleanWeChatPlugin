#pragma once

#include <cstddef>
#include <cstdint>
#include <mach-o/loader.h>

namespace CleanWeChat {

struct LoadedImageInfo {
    const struct mach_header_64* header = nullptr;
    intptr_t slide = 0;
    const uint8_t* textStart = nullptr;
    size_t textSize = 0;
};

/// 解析已加载的 Mach-O 头部并提取运行时 slide 与 __TEXT,__text 代码段范围。
bool InspectMachOImage(const struct mach_header* mh, LoadedImageInfo* outInfo);

/// 在 [start, start + size) 内按 IDA 特征串（例如 "F3 03 ?? AA"）扫描匹配。
/// 返回首个匹配地址，并通过 outMatchCount 输出总命中次数。
const uint8_t* ScanPattern(const uint8_t* start,
                           size_t size,
                           const char* idaPattern,
                           size_t* outMatchCount = nullptr);

/// 从运行时指令地址解码 ARM64 BL (0x94000000) 或 B (0x14000000) 的跳转目标。
uintptr_t DecodeBranchTarget(const void* insnAddr);

/// 通过 mach_vm_protect / mach_vm_remap 以线程安全及 W^X 合规方式改写代码页内存。
bool PatchCodeMemory(void* dest, const void* src, size_t len);

/// 批量管理 ARM64 内联 Hook 安装流程：
/// 1. Stage(...) 将重定位后的原函数入口写入可写暂存跳板页
/// 2. Commit() 先将跳板内存页切换为 R|X 可执行权限，随后再覆写目标函数入口。
class InlineHookBatch {
public:
    bool Stage(void* target, void* replacement, void** outOriginal, const char* label);
    bool Commit();

private:
#if defined(__aarch64__)
    struct PendingDetour {
        void* target = nullptr;
        void* replacement = nullptr;
        void** outOriginal = nullptr;
        uint8_t* trampoline = nullptr;
        const char* label = nullptr;
    };

    uint8_t* poolPage_ = nullptr;
    size_t poolSize_ = 0;
    size_t poolCursor_ = 0;
    bool committed_ = false;
    // 固定最大容量使批量管理器可保持纯头文件定义。
    PendingDetour pending_[16]{};
    size_t pendingCount_ = 0;
#endif
};

}  // namespace CleanWeChat
