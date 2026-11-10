# Lenovo Magic Bay LTE · Linux 与 macOS 适配

这是针对 **联想 Lenovo Magic Bay LTE 4G 上网设备**的非官方适配项目。该设备原本可通过 ThinkBook 的 Pogo-Pin 弹簧触点连接，也提供 USB-C 接口；本仓库整理通过 USB-C 在其他系统使用它的方式。联想官方资料见 [Magic Bay LTE 产品说明](https://support.lenovo.com/uu/en/accessories/acc500287-lenovo-magic-bay-lte-overview-and-service-parts)。

This is a community project for using the Lenovo Magic Bay LTE 4G accessory on Linux and macOS through its USB-C port. The accessory also has the ThinkBook Pogo-Pin connector. It is not an official Lenovo driver or release.

## 支持范围 / Support

| 系统 | 内容 | 当前验证范围 |
| --- | --- | --- |
| Linux | 使用内核 `cdc_mbim`、ModemManager 和 NetworkManager；本仓库提供配置说明与只读状态脚本 | Ubuntu 24.04、一个 Magic Bay LTE 设备的历史实机记录；不同发行版、运营商和多设备环境待验证 |
| macOS | [Magic Bay LTE 2 客户端与 MBIM/NCM 后端源码](./macos/README.md) | Apple Silicon、macOS 14+；一台 Mac 上 0.2.6 初始连接通过，长期稳定性与其他机型仍待验证 |
| Windows / WSL / 其他系统 | 本项目未提供适配程序 | 未验收；WSL 的 USB/蜂窝网络还依赖宿主与设备直通 |

macOS 版目前需要在目标 Mac 上从源码构建，使用 ad-hoc 签名，**没有公证的通用安装包**。Linux 方案依赖系统软件，并非本仓库提供的独立驱动。不要将设备声称为 5G、Wi-Fi 网卡或经过联想认证的第三方驱动。

## Linux：快速开始

以下历史示例基于 USB ID `17ef:7240`、Ubuntu 24.04 和中国联通；APN、设备节点和路由优先级因运营商与机器而异。操作前先准备可用的备用网络。安装相应发行版的 `usbutils`、`modemmanager`、`network-manager` 后，先做只读检查：

```bash
bash ./check_modem_status.sh
mmcli -L
nmcli device status
```

状态脚本的模拟验证可运行 `python3 tests/test_linux_status.py`；该测试不打开真实设备，也不改变网络。

调制解调器编号由系统动态分配，不应照搬其他机器上的编号。若需要查看完整 `mmcli -m <编号>` 输出，请先注意其中可能包含 IMEI、SIM 等标识，不要直接公开原始输出。

确认当前运营商 APN 后，可以通过 NetworkManager 建立连接。例如，下列 `3gnet` 仅为上述中国联通测试环境的示例，**不是所有运营商的默认值**。示例的 `ifname '*'` 适用于只有一个蜂窝调制解调器的情况；若有多个，请先核对 Magic Bay 对应的 NetworkManager 设备并绑定正确设备，避免误用其他 SIM：

```bash
nmcli radio wwan on
nmcli connection add type gsm ifname '*' con-name 'MagicBay LTE' apn '3gnet' connection.autoconnect no
nmcli connection modify 'MagicBay LTE' ipv6.method ignore
nmcli connection up 'MagicBay LTE'
```

这些命令会启用系统蜂窝无线、创建并启动连接，可能消耗 SIM 流量，也可能改变默认路由；请先确认 SIM 套餐与现有网络。示例保留历史测试的IPv6关闭设置，其他网络应按实际情况调整。停止该连接可运行 `nmcli connection down 'MagicBay LTE'`。原测试中使用 `3gnet` 且不填用户名/密码成功；实际认证方式请以运营商为准。不要盲目尝试 SIM PIN/PIN2 解锁。

## macOS：构建与使用

请进入 [macOS 说明](./macos/README.md)，在目标 Apple Silicon Mac 本地构建。客户端安装联网组件需要管理员授权；连接可能改变默认路由和 DNS，先验证备用网络及回退。现有源码仅在一台机器完成有限实测，断线原因和跨机器兼容性仍在排查。

连接不稳定时，可在备用网络可用后，比较设备直连电脑和经过 Hub 的情况。供电不足、线缆、Hub 数据链路、无线质量和软件都可能影响稳定性；单个错误码不足以区分原因。可参考 [Apple 的 USB 连接排查建议](https://support.apple.com/en-ae/102204)。

## 隐私与授权

提交问题前请删除 IMEI、IMSI、ICCID、电话号码、序列号、IP、APN 凭据和其他个人网络信息；不要上传原始 USB 数据包。状态脚本尽量只显示基本状态，但不同系统工具的输出仍应在分享前人工检查。

项目源码公开供查阅和测试；尚未指定项目级开源许可证，修改、再分发及商业使用的授权范围待维护者明确。第三方 libusb 源码使用随附的 LGPL 2.1 许可证；再分发静态链接二进制时请核对该许可证中适用的重新链接等要求。
