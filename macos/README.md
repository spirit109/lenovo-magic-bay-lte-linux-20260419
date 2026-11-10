# Magic Bay LTE 2 for macOS · v0.2.6

这是 Lenovo Magic Bay LTE 的 macOS 原生客户端与 MBIM/NCM 数据面源码。它与仓库根目录保留的 Ubuntu/Linux 配置记录分别使用各自平台的网络适配方式。

## 平台与状态

- 目标：Apple Silicon、macOS 14 及以上。当前实机验证为一台 Mac；其他机器、系统版本及长期 USB 稳定性仍待验证。
- 版本：0.2.6/build 9。内嵌静态构建的 libusb 1.0.30；其原始源码和许可在 `backend/libusb-1.0.30.tar.bz2` 中。
- 真实设备初始化及一次连接后的三轮 HTTPS 直连/代理共 18/18 通过。这是 2026-10-31 的单机初始检查，不保证所有环境或长期使用无断线。
- 此目录为 macOS 源码，不提供 Linux 驱动或 Linux 安装程序。Linux 使用方法请看仓库根目录的 README。

## 从源码构建

需要 Xcode 或兼容的 Apple 命令行构建工具。首次本地构建会从仓库内固定校验值的 libusb 源码编译静态库，无需通过 Homebrew 安装动态库。

```sh
cd macos
/bin/sh scripts/build.sh
/bin/sh scripts/test.sh
```

构建输出位于 `dist/build-*.noindex/`；测试使用模拟设备和本地测试数据，不打开真实 USB 设备或修改网络。`scripts/verify-release.sh` 可检查指定构建目录的签名、架构、版本和归档。

应用采用 ad-hoc 签名，未做 Apple 公证；其他 Mac 上的 Gatekeeper 行为尚未验收。安装限定联网组件需要管理员授权。为支持回退，构建时会把本机的源码目录写入应用安装器，安装后应保留该目录及 `_RecycleBin`；请在目标 Mac 上从源码重新构建，不要把另一台机器生成的 ZIP 当作可迁移安装包。

主界面提供连接和断开 LTE 的入口。更换现有联网组件之前，请先准备并实际验证可用的备用网络。历史诊断、修复和清洁安装辅助脚本可能绑定旧版本或特定维护场景，不能直接当作 0.2.6 的升级/降级工具。

## 隐私与仓库范围

本次提交包含构建、客户端、后端、资源和离线测试源码；不包含本机连接日志、设备身份、SIM 资料、IP 记录、个人回退文件或本机专用维护脚本。项目源码本身尚未声明统一的开源许可证；第三方 libusb 保留其原始许可证。
