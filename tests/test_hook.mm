#import "../src/Arm64Hook.hpp"

#include <cassert>
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <fcntl.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

static int g_globalValue = 41;

__attribute__((noinline))
static int SampleAddWithGlobal(int x, int y) {
    // 保持函数体不小于 32 字节，并在前 16 字节内刻意触发 ADRP 重定位逻辑。
    int base = g_globalValue;
    int sum = x + y + base;
    if (sum == -999999) {
        return sum * 3;
    }
    asm volatile("nop\n nop\n nop\n nop\n");
    return sum;
}

__attribute__((noinline))
static int SampleBranchCaller(int v) {
    return SampleAddWithGlobal(v, 10);
}

static int (*g_origSampleAdd)(int, int) = nullptr;

static int HookedSampleAdd(int x, int y) {
    return g_origSampleAdd(x, y) + 1000;
}

static void VerifyWeChatDylibPatternsAndPrologues() {
    const char* wechatPath = "/Applications/WeChat.app/Contents/Resources/wechat.dylib";
    int fd = open(wechatPath, O_RDONLY);
    if (fd < 0) {
        std::printf("跳过微信 4.2.1 特征验真（未找到本地微信动态库）\n");
        return;
    }

    struct stat st{};
    assert(fstat(fd, &st) == 0);
    void* mapped = mmap(nullptr, static_cast<size_t>(st.st_size), PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    assert(mapped != MAP_FAILED);

    const uint8_t* base = static_cast<const uint8_t*>(mapped);
    uint64_t sliceOff = 0;
    const auto* fh = reinterpret_cast<const struct fat_header*>(base);
    if (OSSwapBigToHostInt32(fh->magic) == FAT_MAGIC) {
        uint32_t nfat = OSSwapBigToHostInt32(fh->nfat_arch);
        const auto* archs = reinterpret_cast<const struct fat_arch*>(base + sizeof(struct fat_header));
        for (uint32_t i = 0; i < nfat; ++i) {
            if (OSSwapBigToHostInt32(archs[i].cputype) == CPU_TYPE_ARM64) {
                sliceOff = OSSwapBigToHostInt32(archs[i].offset);
                break;
            }
        }
    }

    const uint8_t* slice = base + sliceOff;
    const auto* mh = reinterpret_cast<const struct mach_header_64*>(slice);
    assert(mh->magic == MH_MAGIC_64 && mh->cputype == CPU_TYPE_ARM64);

    // 在原始二进制切片中定位 __TEXT,__text 段的文件偏移与大小
    const uint8_t* textStart = nullptr;
    size_t textSize = 0;
    const uint8_t* cur = slice + sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < mh->ncmds; ++i) {
        const auto* lc = reinterpret_cast<const struct load_command*>(cur);
        if (lc->cmd == LC_SEGMENT_64) {
            const auto* seg = reinterpret_cast<const struct segment_command_64*>(cur);
            if (std::strncmp(seg->segname, "__TEXT", 16) == 0) {
                const auto* sects = reinterpret_cast<const struct section_64*>(seg + 1);
                for (uint32_t s = 0; s < seg->nsects; ++s) {
                    if (std::strncmp(sects[s].sectname, "__text", 16) == 0) {
                        textStart = slice + sects[s].offset;
                        textSize = static_cast<size_t>(sects[s].size);
                        break;
                    }
                }
                break;
            }
        }
        cur += lc->cmdsize;
    }
    assert(textStart != nullptr && textSize > (50ULL * 1024ULL * 1024ULL));

    size_t dbHits = 0, drHits = 0, ddHits = 0, srHits = 0, sdHits = 0;
    const uint8_t* db = CleanWeChat::ScanPattern(
        textStart, textSize,
        "20 01 80 52 01 00 80 52 ?? ?? ?? ?? ?? ?? ?? ?? 28 00 80 52 E8 1F 00 B9", &dbHits);
    const uint8_t* dr = CleanWeChat::ScanPattern(
        textStart, textSize,
        "?? ?? ?? ?? E0 03 13 AA ?? ?? ?? ?? 68 1E 40 F9 13 09 40 F9 00 81 C0 3C E0 03 80 3D 93 00 00 B4", &drHits);
    const uint8_t* dd = CleanWeChat::ScanPattern(
        textStart, textSize,
        "FF C3 00 D1 F4 4F 01 A9 FD 7B 02 A9 FD 83 00 91 F3 03 00 AA ?? ?? ?? ?? ?? ?? ?? ?? 08 00 00 F9 08 C1 01 91 08 08 00 F9 14 90 40 F9", &ddHits);
    const uint8_t* sr = CleanWeChat::ScanPattern(
        textStart, textSize,
        "F3 03 00 AA 00 D0 40 F9 ?? ?? ?? ?? C1 00 80 52 ?? ?? ?? ?? ?? ?? ?? ?? F4 03 00 AA A0 00 80 52", &srHits);
    const uint8_t* sd = CleanWeChat::ScanPattern(
        textStart, textSize,
        "09 54 00 F9 ?? ?? ?? ?? ?? ?? ?? ?? 09 A8 12 A9 ?? ?? ?? ?? 08 BC 00 F9 14 24 41 F9 88 02 40 B9 1F 05 00 31", &sdHits);

    assert(dbHits == 1 && drHits == 1 && ddHits == 1 && srHits == 1 && sdHits == 1);

    const uint8_t* discoverBuild = db - 0x2c;
    const uint8_t* discoverRefresh = dr - 0x24;
    const uint8_t* discoverDtor = dd;
    const uint8_t* sidebarRefresh = sr - 0x10;
    const uint8_t* sidebarDtor = sd - 0x44;

    uintptr_t shouldDiscover = CleanWeChat::DecodeBranchTarget(db + 0x08);
    uintptr_t gameFromDiscover = CleanWeChat::DecodeBranchTarget(discoverBuild + 0x148);
    uintptr_t getTabItem = CleanWeChat::DecodeBranchTarget(sr + 0x10);
    uintptr_t shouldSidebar = CleanWeChat::DecodeBranchTarget(sr + 0x20);
    uintptr_t gameFromSidebar = CleanWeChat::DecodeBranchTarget(sidebarRefresh + 0x10c);

    assert(gameFromDiscover == gameFromSidebar);
    assert(static_cast<uintptr_t>(discoverBuild - slice) == 0xd72268);
    assert(static_cast<uintptr_t>(discoverRefresh - slice) == 0xd76280);
    assert(static_cast<uintptr_t>(discoverDtor - slice) == 0xd72768);
    assert(static_cast<uintptr_t>(sidebarRefresh - slice) == 0xf8d124);
    assert(static_cast<uintptr_t>(sidebarDtor - slice) == 0xf8d9b0);
    assert((shouldDiscover - reinterpret_cast<uintptr_t>(slice)) == 0x1a56fc0);
    assert((shouldSidebar - reinterpret_cast<uintptr_t>(slice)) == 0x1a572d8);
    assert((gameFromDiscover - reinterpret_cast<uintptr_t>(slice)) == 0x19ced38);
    assert((getTabItem - reinterpret_cast<uintptr_t>(slice)) == 0x1d53fd8);

    std::printf("微信 4.2.1 特征验真通过（已解析 9/9 个目标符号）\n");
    munmap(mapped, static_cast<size_t>(st.st_size));
}

int main() {
    // 1. 测试 IDA 字节特征扫描与唯一命中计数
    const uint8_t sampleBytes[] = {0x10, 0x20, 0x33, 0x44, 0x55, 0x99, 0x10, 0x20, 0x77, 0x44, 0x55};
    size_t hits = 0;
    const uint8_t* m1 = CleanWeChat::ScanPattern(sampleBytes, sizeof(sampleBytes), "10 20 ?? 44 55", &hits);
    assert(hits == 2 && m1 == sampleBytes);

    const uint8_t* m2 = CleanWeChat::ScanPattern(sampleBytes, sizeof(sampleBytes), "10 20 77 44 55", &hits);
    assert(hits == 1 && m2 == sampleBytes + 6);

    // 2. 测试对模拟指令 BL +0x100 (0x94000040) 的分支目标解码
    alignas(4) uint32_t blBuf[2] = {0x94000040U, 0};
    uintptr_t decoded = CleanWeChat::DecodeBranchTarget(&blBuf[0]);
    assert(decoded == reinterpret_cast<uintptr_t>(&blBuf[0]) + 0x100);

    // 3. 测试在当前进程可执行代码页上运行 ARM64 InlineHookBatch 活体 Hook
    assert(SampleAddWithGlobal(1, 2) == 44);
    assert(SampleBranchCaller(5) == 56);

    CleanWeChat::InlineHookBatch batch;
    bool ok = batch.Stage(reinterpret_cast<void*>(&SampleAddWithGlobal),
                          reinterpret_cast<void*>(&HookedSampleAdd),
                          reinterpret_cast<void**>(&g_origSampleAdd),
                          "SampleAddWithGlobal");
    assert(ok);
    assert(batch.Commit());
    assert(g_origSampleAdd != nullptr);

    assert(SampleAddWithGlobal(1, 2) == 1044);
    assert(SampleBranchCaller(5) == 1056);

    // 4. 对本机已安装的微信 4.2.1 wechat.dylib 执行只读符号校验
    VerifyWeChatDylibPatternsAndPrologues();

    std::printf("全部单元测试通过\n");
    return 0;
}
