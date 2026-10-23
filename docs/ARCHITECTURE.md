# 架构

SilkRDP 由两个独立进程组成，中间只通过 Tailscale 内网和共享 token 通信：

```text
浏览器 ── HTTPS ──▶ Caddy ──▶ Authelia（forward_auth）
                        │
                        ▼
                  rdp-gateway（公网）
                   ├─ 授权页 :8090（仅回环）
                   ├─ nft 白名单
                   └─ TCP/UDP 代理 :33890
                        │
                        │ Tailscale
                        ▼
                  rdp6-agent（家侧）
                   ├─ /open   → IPv6 pinhole
                   ├─ /open4  → IPv4 DNAT 窗口
                   └─ /status → 只读状态
                        │
                        ▼
                  目标机 RDP :3389
```

## 组件职责

### rdp-gateway

运行在公网 VPS 或跳板机。单进程承担：

1. **授权页**：由 Caddy 经 `forward_auth` 保护，只监听 `127.0.0.1`。页面展示当前出口 IP、三条通路、TTL、长期白名单和历史记录。
2. **按需开通**：登录 2FA 不会自动开任何通路。用户分别调用：
   - `/api/open/relay`：把客户端 IPv4 写入 nft `allowed_ips`，同时写入内存白名单。
   - `/api/open/v4`：调用家侧 agent `/open4`，按客户端源 IPv4 开 DNAT 窗口。
   - `/api/open/v6`：调用家侧 agent `/open`，按目标机 GUA 开 fw4 pinhole。
3. **长期白名单**：显式加入的客户端 IPv4 持久化到 `GW_STATE_FILE`，并周期刷新 nft TTL。适合固定办公出口。
4. **TCP/UDP 代理**：把 `GW_PROXY_LISTEN` 的流量转发到 `GW_TARGET`。TCP 与 UDP 都会做应用层白名单校验。

### rdp6-agent

运行在家庭网关（OpenWrt / iStoreOS），以 root 运行以写 fw4：

1. **仅监听 Tailscale 地址**，不绑 `0.0.0.0`。
2. **token 校验**：使用常量时间比较。
3. **GUA 发现**：优先「EUI-64 计算值且邻居表已观测」→「邻居表全局地址」→「DHCPv6 租约」→「EUI-64 计算值」→「::hostid」。GUA 由服务端计算，不接受客户端传入。
4. **开窗**：
   - `/open` 把 GUA 写入 `inet fw4 rdp6_open`，带 TTL。
   - `/open4` 把客户端 IPv4 写入 `inet fw4 rdp4_clients`，带 TTL，并通过 conntrack 活跃度续期。
5. **状态查询**：`/status` 只读，不修改 fw4。

## 三条通路

| 通路 | 数据路径 | 控制面 | 执行面 | TTL |
|---|---|---|---|---|
| relay | 客户端 → 公网网关 :33890 → Tailscale → 目标机 | Caddy/Authelia → gateway | gateway nft + 内存白名单 | `GW_TTL` |
| v4 直连 | 客户端 → 家宽公网 IPv4 :33891 → DNAT → 目标机 | Caddy/Authelia → gateway → agent | agent 写 `rdp4_clients`；fw4 DNAT | `RDP4_TTL`，活跃连接续期 |
| v6 直连 | 客户端 → 目标机 GUA :3389 | Caddy/Authelia → gateway → agent | agent 写 `rdp6_open`；fw4 pinhole | `RDP6_TTL` |

> 直连路径不经过公网网关的数据面，只经过公网网关的控制面。v4 直连按客户端源 IP 精确放行，通常比 v6 更严格。

## 授权时序

1. 用户访问 `https://rdp.example.com`。
2. Caddy 将请求交给 Authelia；未登录则跳转 2FA。
3. 2FA 通过后，Caddy 把请求反代到 `rdp-gateway`，并覆写 `X-Real-IP`。
4. gateway 从 `X-Real-IP` 取得客户端 IPv4（不信任客户端自报头）。
5. 用户点击某条通路的「开通」：
   - relay：gateway 写 nft + 内存白名单。
   - v4：gateway 调 agent `/open4`，agent 写 `rdp4_clients`，返回家宽公网 IPv4。
   - v6：gateway 调 agent `/open`，agent 写 `rdp6_open`，返回目标 GUA。
6. 页面显示连接地址和剩余时间。
7. TTL 到期后，新连接被拒绝；已建立的 TCP 会话不受影响（nft `ct state established`）。

## 信任边界

| 边界 | 信任内容 | 不信任内容 |
|---|---|---|
| 浏览器 ↔ Caddy | TLS、Authelia 会话 | 客户端自报的 `X-Real-IP` |
| Caddy ↔ gateway | 回环连接、Caddy 覆写的真实对端地址 | 公网直接访问授权页 |
| gateway ↔ agent | Tailscale 内网、共享 token | 公网访问 agent |
| agent ↔ fw4 | 服务端计算的 GUA/客户端 IPv4 | 请求参数中的任意地址 |
| gateway ↔ nft | 受限 sudoers 的 add/delete | 任意 root 命令 |

## 状态与持久化

- `GW_STATE_FILE`：长期白名单和历史记录，JSON。默认 `/var/lib/rdp-gateway/state.json`。
- nft 集合：`rdp_guard.allowed_ips`、`rdp6_open`、`rdp4_clients`，均为 timeout 集合。
- agent 不持久化目标地址；每次请求实时发现。

## 失败模式

| 故障 | 行为 |
|---|---|
| Authelia 不可用 | 授权页不可达；已建立的数据面连接不受影响 |
| gateway 重启 | 长期白名单从状态文件恢复；临时白名单丢失，需要重新开通 |
| agent 不可用 | 直连路径开通失败；relay 路径不受影响 |
| Tailscale 断开 | 直连控制失败；relay 路径若依赖 Tailscale 转发也会中断 |
| nft 规则未加载 | gateway 写白名单失败并记录日志；不要在未加载 `rdp_guard` 时启动 |
| 目标机 IP/MAC 变化 | 更新 `GW_TARGET`、DNAT 目标或 `RDP6_WIN10_MAC` |

## 设计取舍

- **不使用端口敲门**：授权页 + 2FA 更直观，且能与现有 Authelia 会话复用。
- **不做 fail-open**：nft 规则在 `policy accept` 下仍显式 drop 33890 未授权流量。
- **直连默认关闭**：登录不自动开任何路径，降低误暴露。
- **v4 优先 TCP**：避免 PPPoE MTU 对 RDP-UDP 的 PMTUD 黑洞；v6 仍可按需启用。
- **agent 最小权限**：只监听 Tailscale，只做单一动作，避免把家侧 root 暴露给公网主机。
