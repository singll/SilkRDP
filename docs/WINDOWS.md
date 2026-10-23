# Windows 目标机

本目录的 PowerShell 脚本用于目标 Windows 的 RDP 加固、连接调优和重装恢复。

## 脚本

| 脚本 | 用途 | 风险 |
|---|---|---|
| `rdp-win10-hardening.ps1` | 创建低权账户、强制 NLA、账户锁定、TCP-only、KeepAlive、GPU 硬编、防火墙 | 中；会改账户与登录策略 |
| `rdp-win10-tuning.ps1` | 只改传输/编码：TCP-only、KeepAlive、GPU 硬编、约 60fps | 低；不改账户/防火墙 |
| `rdp-win11-recovery.ps1` | Win11 重装后恢复 RDP、IPv6 稳定化、NLA、TCP-only、GPU、防火墙 | 中；可能需要重启 |

## 推荐流程

### 新机或完整加固

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\rdp-win10-hardening.ps1
```

### 只修翻页断连/画质

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\rdp-win10-tuning.ps1
```

运行后彻底断开 RDP 再重连，或重启一次。

### Windows 11 重装恢复

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\rdp-win11-recovery.ps1
```

脚本会打印 MAC / IPv4 / IPv6 GUA 报告。把新的 MAC/地址同步到：

- `GW_TARGET`（公网网关 env）
- `RDP6_WIN10_MAC`（家侧 agent）
- `90-rdp4-dnat.nft`（家侧 DNAT 目标）

## 关键策略

- **RDP 只走 TCP**：`SelectTransport=1`。避免家宽 PPPoE MTU 对 RDP-UDP 的 PMTUD 黑洞。
- **KeepAlive + 自动重连**：短暂丢包不掉线，断线可自动恢复。
- **GPU 硬件编码**：`AVCHardwareEncodePreferred=1`，优先物理 GPU；`AVC444ModePreferred=0` 使用更稳的 AVC420。
- **约 60fps**：`DWMFRAMEINTERVAL=15`。
- **低权账户**：只加入 `Remote Desktop Users` 和 `Users`，绝不加入 `Administrators`。
- **账户锁定**：5 次失败锁 15 分钟。

## 注意

- Windows Home/家庭版不支持 RDP 服务端。
- 远程修改防火墙/网络前先确认本地控制台或带外访问可用，避免把自己关在门外。
- 如果目标机使用 NVIDIA 直通，硬件编码需要 GPU 是活动显示适配器（HDMI dummy plug 或虚拟显示器）。
- 如果出现 AVC444 花屏，保持 `AVC444ModePreferred=0`。
- 重装后若 IP/MAC 变化，必须同步更新家侧 DNAT 和 agent 配置。
