#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
OUT_DYLIB="${BUILD_DIR}/libCleanWeChat.dylib"
OUT_TEST="${BUILD_DIR}/test_hook"

mkdir -p "${BUILD_DIR}"

echo "[1/3] 正在编译通用动态库 libCleanWeChat.dylib（arm64 + x86_64 存根）..."
clang++ \
  -std=c++17 \
  -O2 \
  -Wall -Wextra -Werror \
  -fobjc-arc \
  -dynamiclib \
  -mmacosx-version-min=12.0 \
  -arch arm64 -arch x86_64 \
  -install_name "@executable_path/../Frameworks/libCleanWeChat.dylib" \
  -framework Cocoa \
  -framework Foundation \
  "${ROOT_DIR}/src/Arm64Hook.mm" \
  "${ROOT_DIR}/src/PluginConfig.mm" \
  "${ROOT_DIR}/src/NavigationHook.mm" \
  "${ROOT_DIR}/src/UpdateHook.mm" \
  "${ROOT_DIR}/src/PluginMenu.mm" \
  "${ROOT_DIR}/src/CleanWeChatEntry.mm" \
  -o "${OUT_DYLIB}"

codesign -f -s - "${OUT_DYLIB}"

echo "[2/3] 正在编译 arm64 单元测试程序..."
clang++ \
  -std=c++17 \
  -O2 \
  -Wall -Wextra -Werror \
  -fobjc-arc \
  -mmacosx-version-min=12.0 \
  -arch arm64 \
  -framework Foundation \
  "${ROOT_DIR}/src/Arm64Hook.mm" \
  "${ROOT_DIR}/tests/test_hook.mm" \
  -o "${OUT_TEST}"

codesign -f -s - "${OUT_TEST}"

echo "[3/3] 正在运行单元测试..."
"${OUT_TEST}"

echo "编译完成：${OUT_DYLIB}"
