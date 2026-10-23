# 运维手册

## rdp-gateway 环境变量

| 变量 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `GW_HTTP_LISTEN` | 是 | — | 授权页监听地址，建议 `127.0.0.1:8090` |
| `GW_PROXY_LISTEN` | 是 | — | TCP/UDP 中转监听地址，如 `0.0.0.0:33890` |
| `GW_TARGET` | 是 | — | 目标机 RDP 地址，如 `192.168.1.100:3389` |
| `GW_PUBLIC_ADDR` | 是 | — | 对外展示的中转地址 |
| `GW_AGENT_URL` | 是 | — | 家侧 `/open` 完整 URL |
| `GW_AGENT_V4_URL` | 是 | — | 家侧 `/open4` 完整 URL |
| `GW_LOGIN_URL` | 是 | — | 2FA 登录页地址 |
| `RDP6_TOKEN` | 是 | — | 与家侧共享的 token；agent 也要求非空 |
| `GW_NFT_SET` | 否 | `rdp_guard` | nft 表名 |
| `GW_NFT_BIN` | 否 | `/usr/sbin/nft` | nft 可执行文件 |
| `GW_TTL` | 否 | `180` | 中转白名单 TTL（秒） |
| `GW_UDP_IDLE` | 否 | `1800` | UDP 会话空闲回收（秒） |
| `GW_STATE_FILE` | 否 | `/var/lib/rdp-gateway/state.json` | 长期白名单与历史 |
| `GW_HISTORY_LIMIT` | 否 | `160` | 历史记录上限 |
| `GW_PERMANENT_REFRESH` | 否 | `max(20, GW_TTL/2)` | 长期白名单刷新周期（秒） |

## rdp6-agent 环境变量

| 变量 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `RDP6_LISTEN` | 是 | — | 只监听 Tailscale 地址 |
| `RDP6_WIN10_MAC` | 是 | — | 目标机 MAC，用于 GUA 发现 |
| `RDP6_LAN_IF` | 是 | — | 局域网接口，如 `br-lan` |
| `RDP6_HOSTID` | 是 | — | 目标机 IPv6 host id，如 `129` |
| `RDP6_TOKEN` | 是 | — | 与公网网关共享；为空拒绝启动 |
| `RDP6_NFT_SET` | 否 | `rdp6_open` | IPv6 目标集合 |
| `RDP6_RDP_PORT` | 否 | `3389` | 目标机 RDP 端口 |
| `RDP6_TTL` | 否 | `180` | IPv6 pinhole TTL |
| `RDP4_NFT_SET` | 否 | `rdp4_clients` | IPv4 源集合 |
| `RDP4_EXT_PORT` | 否 | `33891` | 家宽公网入口端口 |
| `RDP4_WAN_IFACE` | 否 | `wan` | 家宽 WAN 接口 |
| `RDP4_TTL` | 否 | `300` | v4 直连窗口 TTL |
| `RDP4_REFRESH` | 否 | `60` | v4 连接保活续期周期 |

## HTTP 接口

### gateway

| 路径 | 方法 | 说明 |
|---|---|---|
| `/` | GET | 授权页；需要 Caddy `forward_auth` |
| `/health` | GET | 健康检查，返回 `ok` |
| `/api/state` | GET | 当前状态、历史、白名单 |
| `/api/whitelist/current` | GET | 当前临时/长期白名单 |
| `/api/whitelist/remove` | POST | 移除长期白名单 |
| `/api/open/relay` | POST | 开通 IPv4 中转 |
| `/api/open/v4` | POST | 开通家宽 IPv4 直连 |
| `/api/open/v6` | POST | 开通 IPv6 直连 |

### agent

| 路径 | 方法 | 说明 |
|---|---|---|
| `/health` | GET | 健康检查 |
| `/status?token=...` | GET | 只读状态 |
| `/open?token=...` | GET | 开 IPv6 pinhole，返回 GUA |
| `/open4?token=...&client=<v4>` | GET | 开 IPv4 DNAT 窗口，返回家宽公网 IPv4 |

> token 建议通过请求头或受控内网传递；不要把带 token 的 URL 写入公网日志。

## 状态与日志

| 内容 | 位置 |
|---|---|
| gateway 长期白名单/历史 | `GW_STATE_FILE` |
| gateway journal | `journalctl -u rdp-gateway` |
| gateway nft | `nft list table inet rdp_guard` |
| agent 日志 | `logread \| grep rdp6`（OpenWrt）或进程 stdout |
| agent fw4 集合 | `nft list set inet fw4 rdp6_open`、`nft list set inet fw4 rdp4_clients` |
| 当前 v4 窗口 | `/status` 的 `v4_nft_set` / 最近一次开窗 |

## 常见问题

| 现象 | 排查 |
|---|---|
| gateway 启动即退出 | 必填 env 缺失；`journalctl -u rdp-gateway` 查看 `Environment variable ... is required` |
| 授权页 502 | Caddy 反代目标不对，或 gateway 未监听 `127.0.0.1:8090` |
| 中转连不上 | `nft list set inet rdp_guard allowed_ips` 是否含客户端 IP；`ct state established` 是否存在；UDP 是否被显式 drop |
| 直连开通失败 | agent 是否在线；Tailscale 是否通；token 是否一致；`/status` 是否正常 |
| v6 连不上 | `nft list set inet fw4 rdp6_open` 是否有 GUA；agent 是否发现正确 GUA；客户端是否有 IPv6 |
| v4 连不上 | `rdp4_clients` 是否含客户端 IP；DNAT 目标/端口是否正确；`fw4 reload` 是否执行 |
| 3 分钟后新连接被拒 | 这是预期行为；TTL 只限制新会话，已建立会话保持 |
| 活跃 v4 会话掉线 | 检查 conntrack 是否可见；`RDP4_REFRESH`/`RDP4_TTL` 是否过小 |
| 目标机换 IP/MAC | 更新 `GW_TARGET`、DNAT 示例、`RDP6_WIN10_MAC`，再重启对应服务 |

## 变更检查清单

1. 修改 `/etc/rdp-gateway.env` 后 `systemctl restart rdp-gateway`。
2. 修改 nft 后 `nft -c -f` 或 `nft list ruleset` 验证，再 `systemctl restart nftables-rdp`。
3. 修改 sudoers 后必须 `visudo -cf`。
4. 修改 agent init 后 `/etc/init.d/rdp6-agent restart`。
5. 修改 fw4 后 `fw4 reload`，并确认两个集合仍存在。
6. 每次变更后做一次端到端 2FA + 三条通路验证。
