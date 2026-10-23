# 部署文件

## gateway/

| 文件 | 用途 |
|---|---|
| `rdp-gateway.env.example` | `/etc/rdp-gateway.env` 模板 |
| `rdp-gateway.service` | 公网网关 systemd unit |
| `nftables-rdp.service` | 加载 `rdp_guard` 表的 oneshot unit |
| `rdp_guard.nft` | 公网入口白名单 nftables 规则 |
| `sudoers.rdp-gateway` | 只允许 `rdpgw` 增删 `allowed_ips` |
| `Caddyfile.example` | Caddy + Authelia `forward_auth` 示例 |

## agent/

| 文件 | 用途 |
|---|---|
| `rdp6-agent.init` | OpenWrt / iStoreOS procd 服务 |
| `firewall.uci.example` | fw4 的 `rdp6_open` / `rdp4_clients` 集合与转发规则 |
| `90-rdp4-dnat.nft.example` | 家宽 IPv4 直连 DNAT 示例，必须按实际环境修改 |
| `token.example` | 与公网网关共享的 token 占位 |

> 所有示例中的 IP、接口名、MAC、域名都是占位值。部署前逐项替换，并在目标机上先做 `nft -c -f` / `caddy validate` / `visudo -cf` 校验。
