# Magic Bay LTE 2 for macOS · v0.2.6

这是针对联想 Lenovo Magic Bay LTE 触点式 4G 上网设备的非官方 macOS 原生客户端与 MBIM/NCM 数据面源码。设备原可通过 ThinkBook 的 Pogo-Pin 弹簧触点连接；此适配使用设备 USB-C 接口，仓库根目录另有 Ubuntu/Linux 配置说明。

## 平台与状态

- 目标：Apple Silicon、macOS 14 及以上。当前实机验证为一台 Mac；其他机器、系统版本及长期 USB 稳定性仍待验证。
- 版本：0.2.6/build 9。内嵌静态构建的 libusb 1.0.30；其原始源码与 LGPL 2.1 许可在 `backend/libusb-1.0.30.tar.bz2` 中。再分发静态链接二进制时请核对许可证的相关要求。
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

构建完成后，在输出的 `dist/build-*.noindex/` 中打开 `Magic Bay LTE 2.app`。首次使用时展开“设置与诊断”，选择“设置权限”，阅读提示后由 macOS 管理员授权安装限定联网组件；然后按运营商要求确认 APN 并使用“连接 LTE”。连接可能切换系统默认路由和 DNS，FlClash、VPN 与 Wi-Fi 的实际共存需在各自环境验证。关闭窗口不会主动断开 LTE；结束使用请在主界面或菜单中选择“断开 LTE”。

构建目录中另有 `恢复家庭网络.app`，可在需要时停止 LTE 并尝试回到已保存的 Wi-Fi；它不能保证目标机器一定存在可用 Wi-Fi 或可用 DNS。更换现有联网组件之前，请先准备并实际验证可用的备用网络。历史诊断、修复和清洁安装辅助脚本可能绑定旧版本或特定维护场景，不能直接当作 0.2.6 的升级/降级工具。

## English quick start

On an Apple Silicon Mac with macOS 14 or later, run the build commands above from the repository root. Open the generated app, expand its settings, and authorize installation of the network helper. Set the APN supplied by your carrier, then connect LTE. The current interface and detailed instructions are primarily Chinese. The app is ad-hoc signed and not notarized; builds and real-device behavior on other machines are not yet verified.

## 隐私与仓库范围

发布目录包含构建、客户端、后端、资源和离线测试源码；不包含本机连接日志、设备身份、SIM 资料、IP 记录、个人回退文件或本机专用维护脚本。项目源码本身尚未声明统一的开源许可证；第三方 libusb 保留其原始许可证。
