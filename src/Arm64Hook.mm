#include "Arm64Hook.hpp"

#include <cstring>
#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <os/log.h>
#include <sys/mman.h>
#include <unistd.h>
#include <vector>

namespace CleanWeChat {

#if defined(__aarch64__)
static os_log_t HookLog() {
    static os_log_t log = os_log_create("com.cleanwechat.plugin", "hook");
    return log;
}
#endif

bool InspectMachOImage(const struct mach_header* mh, LoadedImageInfo* outInfo) {
    if (!mh || !outInfo || mh->magic != MH_MAGIC_64 || mh->cputype != CPU_TYPE_ARM64) {
        return false;
    }

    const auto* mh64 = reinterpret_cast<const struct mach_header_64*>(mh);
    const uint8_t* cursor = reinterpret_cast<const uint8_t*>(mh64 + 1);

    intptr_t slide = 0;
    bool foundTextSeg = false;
    const uint8_t* textStart = nullptr;
    size_t textSize = 0;

    for (uint32_t i = 0; i < mh64->ncmds; ++i) {
        const auto* lc = reinterpret_cast<const struct load_command*>(cursor);
        if (lc->cmd == LC_SEGMENT_64) {
            const auto* seg = reinterpret_cast<const struct segment_command_64*>(cursor);
            if (std::strncmp(seg->segname, "__TEXT", 16) == 0) {
                slide = reinterpret_cast<intptr_t>(mh64) - static_cast<intptr_t>(seg->vmaddr);
                foundTextSeg = true;
                const auto* sects = reinterpret_cast<const struct section_64*>(seg + 1);
                for (uint32_t s = 0; s < seg->nsects; ++s) {
                    if (std::strncmp(sects[s].sectname, "__text", 16) == 0) {
                        textStart = reinterpret_cast<const uint8_t*>(slide + static_cast<intptr_t>(sects[s].addr));
                        textSize = static_cast<size_t>(sects[s].size);
                        break;
                    }
                }
                break;
            }
        }
        cursor += lc->cmdsize;
    }

    if (!foundTextSeg || !textStart || textSize == 0) {
        return false;
    }

    outInfo->header = mh64;
    outInfo->slide = slide;
    outInfo->textStart = textStart;
    outInfo->textSize = textSize;
    return true;
}

namespace {

struct PatternToken {
    bool isWildcard;
    uint8_t value;
};

int HexCharToInt(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

bool ParseIdaPattern(const char* pattern, std::vector<PatternToken>& outTokens) {
    outTokens.clear();
    if (!pattern) return false;

    const char* p = pattern;
    while (*p) {
        while (*p == ' ' || *p == '\t') ++p;
        if (!*p) break;

        if (*p == '?') {
            outTokens.push_back({true, 0});
            while (*p == '?') ++p;
        } else {
            int hi = HexCharToInt(p[0]);
            int lo = p[1] ? HexCharToInt(p[1]) : -1;
            if (hi < 0 || lo < 0) return false;
            outTokens.push_back({false, static_cast<uint8_t>((hi << 4) | lo)});
            p += 2;
        }
    }
    return !outTokens.empty();
}

#if defined(__aarch64__)
void EmitU32(std::vector<uint32_t>& out, uint32_t insn) {
    out.push_back(insn);
}

void EmitLoadImm64(std::vector<uint32_t>& out, uint32_t reg, uint64_t val) {
    EmitU32(out, 0xD2800000U | (static_cast<uint32_t>(val & 0xFFFFU) << 5) | (reg & 0x1FU));
    uint16_t h1 = static_cast<uint16_t>((val >> 16) & 0xFFFFU);
    uint16_t h2 = static_cast<uint16_t>((val >> 32) & 0xFFFFU);
    uint16_t h3 = static_cast<uint16_t>((val >> 48) & 0xFFFFU);
    if (h1) EmitU32(out, 0xF2A00000U | (static_cast<uint32_t>(h1) << 5) | (reg & 0x1FU));
    if (h2) EmitU32(out, 0xF2C00000U | (static_cast<uint32_t>(h2) << 5) | (reg & 0x1FU));
    if (h3) EmitU32(out, 0xF2E00000U | (static_cast<uint32_t>(h3) << 5) | (reg & 0x1FU));
}

void EmitAbsJumpX16(std::vector<uint32_t>& out, uintptr_t target) {
    // 16 字节绝对跳转序列：LDR X16, #8; BR X16; .quad target
    EmitU32(out, 0x58000050U);
    EmitU32(out, 0xD61F0200U);
    EmitU32(out, static_cast<uint32_t>(target & 0xFFFFFFFFULL));
    EmitU32(out, static_cast<uint32_t>((target >> 32) & 0xFFFFFFFFULL));
}

bool RelocatePrologue4Insns(uintptr_t srcAddr, std::vector<uint32_t>& out, const char* label) {
    const uint32_t* insns = reinterpret_cast<const uint32_t*>(srcAddr);
    for (int i = 0; i < 4; ++i) {
        const uint32_t w = insns[i];
        const uintptr_t pc = srcAddr + static_cast<uintptr_t>(i * 4);

        // 将 PC 相对寻址 ADRP / ADR 重定位为绝对 MOVZ/MOVK 加载序列。
        if ((w & 0x1F000000U) == 0x10000000U) {
            const uint32_t rd = w & 0x1FU;
            const bool isAdrp = (w & 0x80000000U) != 0;
            const int64_t immlo = static_cast<int64_t>((w >> 29) & 0x3U);
            const int64_t immhi = static_cast<int64_t>((w >> 5) & 0x7FFFFU);
            int64_t imm = (immhi << 2) | immlo;
            if (imm & (1LL << 20)) imm -= (1LL << 21);

            uint64_t val = isAdrp
                ? ((pc & ~0xFFFULL) + static_cast<uint64_t>(imm << 12))
                : (pc + static_cast<uint64_t>(imm));
            if (rd != 31U) {
                EmitLoadImm64(out, rd, val);
            }
            continue;
        }

        const bool isUncondBranch = (w & 0x7C000000U) == 0x14000000U;
        const bool isCondBranch = (w & 0xFF000010U) == 0x54000000U;
        const bool isCbzTbz = (w & 0x7E000000U) == 0x34000000U || (w & 0x7E000000U) == 0x36000000U;
        const bool isLdrLiteral = (w & 0x3B000000U) == 0x18000000U;
        if (isUncondBranch || isCondBranch || isCbzTbz || isLdrLiteral) {
            os_log_error(HookLog(),
                         "暂不支持的 PC 相对指令 0x%{public}08x（%{public}s+%d）",
                         w, label ? label : "unknown", i * 4);
            return false;
        }

        EmitU32(out, w);
    }

    EmitAbsJumpX16(out, srcAddr + 16);
    return true;
}
#endif

}  // namespace

const uint8_t* ScanPattern(const uint8_t* start,
                           size_t size,
                           const char* idaPattern,
                           size_t* outMatchCount) {
    if (outMatchCount) *outMatchCount = 0;
    if (!start || size == 0) return nullptr;

    std::vector<PatternToken> tokens;
    if (!ParseIdaPattern(idaPattern, tokens) || size < tokens.size()) {
        return nullptr;
    }

    size_t bestStart = 0;
    size_t bestLen = 0;
    size_t curStart = 0;
    size_t curLen = 0;
    for (size_t i = 0; i < tokens.size(); ++i) {
        if (!tokens[i].isWildcard) {
            if (curLen == 0) curStart = i;
            ++curLen;
            if (curLen > bestLen) {
                bestStart = curStart;
                bestLen = curLen;
            }
        } else {
            curLen = 0;
        }
    }
    if (bestLen == 0) return nullptr;

    std::vector<uint8_t> anchor(bestLen);
    for (size_t i = 0; i < bestLen; ++i) {
        anchor[i] = tokens[bestStart + i].value;
    }

    const uint8_t* firstMatch = nullptr;
    size_t count = 0;
    const size_t patLen = tokens.size();
    const uint8_t* end = start + size;
    const uint8_t* cursor = start + bestStart;

    while (cursor <= end - (patLen - bestStart)) {
        const void* found = ::memmem(cursor, static_cast<size_t>(end - cursor), anchor.data(), bestLen);
        if (!found) break;

        const uint8_t* foundPtr = static_cast<const uint8_t*>(found);
        const uint8_t* candidate = foundPtr - bestStart;
        if (candidate >= start && candidate + patLen <= end) {
            bool matched = true;
            for (size_t i = 0; i < patLen; ++i) {
                if (!tokens[i].isWildcard && candidate[i] != tokens[i].value) {
                    matched = false;
                    break;
                }
            }
            if (matched) {
                if (!firstMatch) firstMatch = candidate;
                ++count;
            }
        }
        cursor = foundPtr + 1;
    }

    if (outMatchCount) *outMatchCount = count;
    return firstMatch;
}

uintptr_t DecodeBranchTarget(const void* insnAddr) {
    if (!insnAddr) return 0;
    uint32_t insn = *reinterpret_cast<const uint32_t*>(insnAddr);
    if ((insn & 0x7C000000U) != 0x14000000U) {
        return 0;
    }
    int32_t imm26 = static_cast<int32_t>(insn & 0x03FFFFFFU);
    if (imm26 & 0x02000000) {
        imm26 -= 0x04000000;
    }
    intptr_t base = reinterpret_cast<intptr_t>(insnAddr);
    return static_cast<uintptr_t>(base + (static_cast<intptr_t>(imm26) << 2));
}

bool PatchCodeMemory(void* dest, const void* src, size_t len) {
#if !defined(__aarch64__)
    (void)dest;
    (void)src;
    (void)len;
    return false;
#else
    if (!dest || !src || len == 0) return false;

    const size_t pageSize = static_cast<size_t>(sysconf(_SC_PAGESIZE));
    const uintptr_t startAddr = reinterpret_cast<uintptr_t>(dest);
    const uintptr_t endAddr = startAddr + len;
    const uint8_t* srcBytes = static_cast<const uint8_t*>(src);

    uintptr_t cur = startAddr;
    size_t offset = 0;
    while (cur < endAddr) {
        const uintptr_t pageAddr = cur & ~(pageSize - 1);
        const uintptr_t nextPage = pageAddr + pageSize;
        const size_t chunkLen = (endAddr < nextPage ? endAddr : nextPage) - cur;

        mach_vm_address_t regionAddr = static_cast<mach_vm_address_t>(pageAddr);
        mach_vm_size_t regionSize = 0;
        natural_t depth = 0;
        vm_region_submap_short_info_data_64_t info{};
        mach_msg_type_number_t count = VM_REGION_SUBMAP_SHORT_INFO_COUNT_64;

        kern_return_t kr = mach_vm_region_recurse(
            mach_task_self(), &regionAddr, &regionSize, &depth,
            reinterpret_cast<vm_region_recurse_info_t>(&info), &count);
        while (kr == KERN_SUCCESS && info.is_submap) {
            ++depth;
            count = VM_REGION_SUBMAP_SHORT_INFO_COUNT_64;
            kr = mach_vm_region_recurse(
                mach_task_self(), &regionAddr, &regionSize, &depth,
                reinterpret_cast<vm_region_recurse_info_t>(&info), &count);
        }
        if (kr != KERN_SUCCESS) {
            os_log_error(HookLog(), "mach_vm_region_recurse 查询内存区域失败: %{public}d", kr);
            return false;
        }

        const bool needRemap =
            ((info.protection & (VM_PROT_READ | VM_PROT_EXECUTE)) == (VM_PROT_READ | VM_PROT_EXECUTE)) &&
            (info.share_mode != SM_PRIVATE);

        if (!needRemap) {
            kr = mach_vm_protect(mach_task_self(), pageAddr, pageSize, FALSE,
                                 VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
            if (kr != KERN_SUCCESS) {
                os_log_error(HookLog(), "mach_vm_protect 设置可写权限失败: %{public}d", kr);
                return false;
            }
            std::memcpy(reinterpret_cast<void*>(cur), srcBytes + offset, chunkLen);
            kr = mach_vm_protect(mach_task_self(), pageAddr, pageSize, FALSE,
                                 static_cast<vm_prot_t>(info.protection));
            if (kr != KERN_SUCCESS) {
                os_log_error(HookLog(), "mach_vm_protect 恢复原始权限失败: %{public}d", kr);
                return false;
            }
        } else {
            mach_vm_address_t stagePage = 0;
            kr = mach_vm_allocate(mach_task_self(), &stagePage, pageSize, VM_FLAGS_ANYWHERE);
            if (kr != KERN_SUCCESS) {
                os_log_error(HookLog(), "mach_vm_allocate 分配暂存页失败: %{public}d", kr);
                return false;
            }
            std::memcpy(reinterpret_cast<void*>(stagePage), reinterpret_cast<const void*>(pageAddr), pageSize);
            std::memcpy(reinterpret_cast<void*>(stagePage + (cur - pageAddr)), srcBytes + offset, chunkLen);

            kr = mach_vm_protect(mach_task_self(), stagePage, pageSize, FALSE,
                                 VM_PROT_READ | VM_PROT_EXECUTE);
            if (kr != KERN_SUCCESS) {
                mach_vm_deallocate(mach_task_self(), stagePage, pageSize);
                os_log_error(HookLog(), "mach_vm_protect 设置暂存页 R|X 失败: %{public}d", kr);
                return false;
            }

            mach_vm_address_t targetRemap = static_cast<mach_vm_address_t>(pageAddr);
            vm_prot_t curProt = VM_PROT_NONE;
            vm_prot_t maxProt = VM_PROT_NONE;
            kr = mach_vm_remap(mach_task_self(), &targetRemap, pageSize, 0,
                               VM_FLAGS_OVERWRITE, mach_task_self(), stagePage, TRUE,
                               &curProt, &maxProt, VM_INHERIT_COPY);
            mach_vm_deallocate(mach_task_self(), stagePage, pageSize);
            if (kr != KERN_SUCCESS) {
                os_log_error(HookLog(), "mach_vm_remap 覆盖映射失败: %{public}d", kr);
                return false;
            }
        }

        cur += chunkLen;
        offset += chunkLen;
    }

    sys_icache_invalidate(dest, len);
    return true;
#endif
}

bool InlineHookBatch::Stage(void* target, void* replacement, void** outOriginal, const char* label) {
#if !defined(__aarch64__)
    (void)target;
    (void)replacement;
    (void)outOriginal;
    (void)label;
    return false;
#else
    if (committed_ || !target || !replacement || pendingCount_ >= 16) return false;

    if (!poolPage_) {
        poolSize_ = static_cast<size_t>(sysconf(_SC_PAGESIZE));
        void* page = mmap(nullptr, poolSize_, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
        if (page == MAP_FAILED) {
            os_log_error(HookLog(), "mmap 申请跳板内存池失败");
            return false;
        }
        poolPage_ = static_cast<uint8_t*>(page);
        poolCursor_ = 0;
    }

    const uintptr_t srcAddr = reinterpret_cast<uintptr_t>(target);
    std::vector<uint32_t> tramp;
    tramp.reserve(24);
    if (!RelocatePrologue4Insns(srcAddr, tramp, label)) {
        return false;
    }

    const size_t alignedOff = (poolCursor_ + 15U) & ~size_t(15U);
    const size_t trampBytes = tramp.size() * sizeof(uint32_t);
    if (alignedOff + trampBytes > poolSize_) {
        os_log_error(HookLog(), "跳板页容量已满（%{public}s）", label ? label : "");
        return false;
    }

    uint8_t* trampDst = poolPage_ + alignedOff;
    std::memcpy(trampDst, tramp.data(), trampBytes);
    poolCursor_ = alignedOff + trampBytes;

    PendingDetour& entry = pending_[pendingCount_++];
    entry.target = target;
    entry.replacement = replacement;
    entry.outOriginal = outOriginal;
    entry.trampoline = trampDst;
    entry.label = label;
    return true;
#endif
}

bool InlineHookBatch::Commit() {
#if !defined(__aarch64__)
    return false;
#else
    if (committed_ || !poolPage_ || pendingCount_ == 0) return false;

    // 1. 在改写任何目标函数入口之前，先将跳板页权限切换为可读可执行 (R|X)。
    kern_return_t kr = mach_vm_protect(
        mach_task_self(),
        reinterpret_cast<mach_vm_address_t>(poolPage_),
        poolSize_,
        FALSE,
        VM_PROT_READ | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS) {
        os_log_error(HookLog(), "mach_vm_protect 设置跳板页 R|X 失败: %{public}d", kr);
        return false;
    }
    sys_icache_invalidate(poolPage_, poolCursor_);

    // 2. 先回填原函数跳板指针，随后再向目标函数入口写入 16 字节绝对跳转补丁。
    for (size_t i = 0; i < pendingCount_; ++i) {
        if (pending_[i].outOriginal) {
            *pending_[i].outOriginal = pending_[i].trampoline;
        }
    }

    bool allOk = true;
    for (size_t i = 0; i < pendingCount_; ++i) {
        std::vector<uint32_t> detour;
        EmitAbsJumpX16(detour, reinterpret_cast<uintptr_t>(pending_[i].replacement));
        if (!PatchCodeMemory(pending_[i].target, detour.data(), detour.size() * sizeof(uint32_t))) {
            os_log_error(HookLog(), "写入跳转补丁失败（%{public}s）",
                         pending_[i].label ? pending_[i].label : "unknown");
            allOk = false;
        } else {
            os_log_info(HookLog(), "已成功 Hook %{public}s（%{public}p）",
                        pending_[i].label ? pending_[i].label : "fn", pending_[i].target);
        }
    }

    committed_ = true;
    return allOk;
#endif
}

}  // namespace CleanWeChat
