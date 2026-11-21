# 安全策略与审计指南

## 作用域与安全承诺

CleanWeChatPlugin 从设计上坚持每一行源码都清晰可审：

- **零网络行为**：不链接任何网络框架（`CFNetwork`、`Network`、`NSURLSession`、BSD Socket、`libcurl`）。
- **零凭据与数据库访问**：不包含任何钥匙串调用（`SecItem*`、`SecKeychain*`）、`SQLCipher` / SQLite 读取或 macOS 辅助功能（Accessibility）控制接口。
- **零混淆与零闭源模块**：不加密字符串、不内嵌加壳存根，也不引入任何闭源第三方 Hook 库。
- **最小化拦截面**：仅拦截侧边栏与发现页显隐函数（`ShouldShowDiscover`、`ShouldShowSidebar`、`IsGameEnabled`、刷新与析构函数）以及 `XAppUpdateManager` 更新相关 Objective-C 方法。

## 自行审计编译产物

运行 `./build.sh` 编译后，可直接对生成的动态库执行逐项验真：

```bash
otool -L build/libCleanWeChat.dylib
nm -arch arm64 -u build/libCleanWeChat.dylib
codesign --verify --strict --verbose=2 build/libCleanWeChat.dylib
```

所有外部链接依赖应仅限于苹果原生系统框架与基础库：`Cocoa`、`Foundation`、`AppKit`、`CoreFoundation`、`libobjc`、`libc++` 与 `libSystem`。

## 问题反馈

如在新版本 macOS 微信上遇到崩溃、异常符号链接或特征匹配失效，请在 [GitHub Issues](https://github.com/XiaKaiYang/CleanWeChatPlugin/issues) 提交说明，并附上您的 macOS 版本、微信版本号（`CFBundleShortVersionString` / `CFBundleVersion`）及编译测试输出。
