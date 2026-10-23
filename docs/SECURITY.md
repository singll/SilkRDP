# 安全模型

## 威胁模型

| 资产 | 主要威胁 | 控制 |
|---|---|---|
| 目标机 RDP | 公网扫描、爆破、RDP 漏洞 | 不直接暴露；2FA 门控；NLA；低权账户；账户锁定 |
| 公网网关 | 未授权使用代理、nft 规则被绕过 | Caddy + Authelia；nft 白名单；应用层白名单；sudoers 最小权限 |
| 家侧 agent | token 泄露、越权开窗 | 只监听 Tailscale；常量时间 token；只接受服务端计算的 GUA；单动作 |
| 家宽 IPv4 DNAT | 未授权源进入 | 按客户端源 IP 精确放行；集合空即关闭；TCP-only |
| 家宽 IPv6 pinhole | 窗口期任意源 | 短 TTL；GUA 不公开；NLA + 锁定；可升级为源限制 |
| 控制面凭据 | token/env 泄露 | 文件权限 0600/0640；不入 Git；定期轮换 |

## 关键安全属性

1. **默认关闭**：登录 2FA 不自动开任何通路。
2. **最小授权**：relay 按客户端 v4；v4 直连按客户端 v4；v6 按目标 GUA。
3. **短时窗口**：所有动态集合带 TTL；长期白名单必须显式加入。
4. **无 fail-open**：`policy accept` 下仍显式 drop 33890 未授权 TCP/UDP。
5. **控制面/数据面分离**：直连路径不经公网网关的数据面。
6. **agent 不可公网访问**：只监听 Tailscale。
7. **GUA 不可注入**：agent 不接受客户端传入的目标地址。
8. **已建立会话不被 TTL 打断**：nft `ct state established,related accept`。

## 残余风险

- **v6 直连窗口不限源**：窗口期内任何知道当前 GUA 的 IPv6 源都可能到达 3389。依靠 GUA 不可枚举、短 TTL、NLA、账户锁定、低权账户降低风险。若需要更严格，应在 agent 中扩展为「源 IPv6 + 目标 GUA」双匹配。
- **公共 DERP 绕行**：如果未部署内嵌 DERP，Tailscale 可能走公共中继，延迟较高。DERP 只中继 WireGuard 密文，不增加 RDP 明文暴露。
- **公网网关是单点**：失陷后攻击者可控制白名单和代理。应保持系统补丁、SSH 最小暴露、fail2ban/防火墙、密钥登录。
- **token 共享**：agent 与 gateway 共享一个 token；泄露后可在 Tailscale 内开窗。应定期轮换，并限制 Tailscale ACL。

## 加固清单

- [ ] 授权页只监听 `127.0.0.1`，由 Caddy `forward_auth` 保护。
- [ ] Caddy 覆写 `X-Real-IP`，gateway 不信任其他来源。
- [ ] `/etc/rdp-gateway.env` 权限 `0640 root:root`。
- [ ] `/opt/rdp6-agent/token` 权限 `0600 root:root`。
- [ ] `RDP6_TOKEN` 使用 32 字节以上随机值，定期轮换。
- [ ] sudoers 只允许 `nft add/delete element inet rdp_guard allowed_ips`。
- [ ] `rdp_guard.nft` 保留 TCP/UDP 33890 的显式 drop。
- [ ] agent 不监听 `0.0.0.0`。
- [ ] 目标机使用低权账户，不在 Administrators 组。
- [ ] 目标机强制 NLA、账户锁定、系统补丁。
- [ ] RDP 传输优先 TCP-only，避免 PPPoE UDP 黑洞。
- [ ] 定期检查 `/api/state` 历史记录和 gateway 日志。
- [ ] Tailscale ACL 限制 gateway 只能访问 agent 的 8091 端口。

## 事件响应

1. 立即停止 `rdp-gateway` 和 `rdp6-agent`。
2. 清空 nft 集合：
   ```bash
   nft flush set inet rdp_guard allowed_ips
   nft flush set inet fw4 rdp6_open
   nft flush set inet fw4 rdp4_clients
   ```
3. 轮换 `RDP6_TOKEN`，同步更新两端。
4. 检查 `GW_STATE_FILE` 和 journal，确认异常来源。
5. 检查目标机登录日志、账户锁定记录和 RDP 会话。
6. 修复后重新验证三条通路。
