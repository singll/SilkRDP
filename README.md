# SilkRDP

> 面向原生 RDP 的双路径安全接入网关：公网中转兜底 + IPv4/IPv6 直连，2FA 授权后按需开窗。
> 一个 Go 二进制作为公网网关，一个 Go 二进制作为家庭侧执行代理；不依赖任何外部编排平台。

SilkRDP 解决的是「临时设备只能使用原生 `mstsc`，但不能直接把 RDP 暴露到公网」的场景：

- **公网中转**：客户端 → 公网网关 `:33890` → 内网目标机 `:3389`，任意 IPv4 网络可用。
- **IPv4 直连**：2FA 后按客户端源 IP 打开家宽 DNAT 窗口，流量不经过公网中转。
- **IPv6 直连**：2FA 后按目标机当前 GUA 打开 fw4 pinhole，延迟最低。
- **最小授权**：登录 2FA 不自动开通任何通路，三条通路各自按需开通、各自 TTL。
- **纵深防御**：内核 nft 白名单 + 应用层白名单 + NLA + 低权账户 + 账户锁定。

本项目是独立、可单独部署的工具。仓库内不包含其他项目的代码、配置或文档。

---

## 架构

```
                          ┌──────────────────────────────┐
   浏览器 2FA ──────────▶ │  Caddy + Authelia            │
                          │  forward_auth                │
                          └──────────────┬───────────────┘
                                         │
                          ┌──────────────▼───────────────┐
                          │  rdp-gateway（公网主机）      │
                          │  HTTP 授权页 + TCP/UDP 代理   │
                          │  nft 白名单 + 长期白名单      │
                          └───────┬──────────────┬───────┘
                                  │              │
                    TCP/UDP :33890│              │ Tailscale
                                  │              │（/open、/open4）
                                  ▼              ▼
                          ┌──────────────┐  ┌─────────────────────┐
                          │ 目标机 :3389 │  │ rdp6-agent（家侧）   │
                          │ RDP + NLA    │  │ fw4 动态开窗         │
                          └──────────────┘  └─────────────────────┘
                                  ▲
                                  │ IPv4 DNAT / IPv6 pinhole
                                  └──────── 直连路径 ────────
```

### 两个组件

| 组件 | 部署位置 | 职责 |
|---|---|---|
| `rdp-gateway` | 公网 VPS / 跳板机 | 2FA 授权页、按需开通三条通路、nft 白名单、TCP/UDP 代理、长期白名单持久化 |
| `rdp6-agent` | 家庭网关（OpenWrt/iStoreOS） | 仅监听 Tailscale，校验 token，动态写 fw4 集合，发现目标机 GUA/家宽公网 IPv4 |

### 三条通路

| 通路 | 入口 | 适用条件 | 授权粒度 |
|---|---|---|---|
| `relay` | `GW_PUBLIC_ADDR`（默认 `:33890`） | 任意 IPv4 客户端 | 客户端源 IPv4 写入 nft，TTL |
| `v4` | 家宽公网 IPv4 `:33891` | 家宽有公网 IPv4 | 客户端源 IPv4 精确 DNAT，带连接保活 |
| `v6` | 目标机 GUA `:3389` | 客户端有 IPv6，目标机有 GUA | 目标 GUA 写入 fw4 pinhole，TTL |

> 默认不自动开通任何通路；用户通过授权页分别点击开通。`relay` 的长期白名单可持久化，适用于常用客户端。

---

## 快速开始

### 构建

要求 Go 1.25+，Linux amd64（其他架构可通过 `GOARCH` 交叉编译）：

```bash
make build
# 产物：bin/rdp-gateway、bin/rdp6-agent
make check   # go vet + go test
```

### 部署公网网关

```bash
sudo install -d -m 0755 /opt/rdp-gateway
sudo install -m 0755 bin/rdp-gateway /opt/rdp-gateway/rdp-gateway

sudo install -d -m 0700 -o rdpgw -g rdpgw /var/lib/rdp-gateway
sudo install -m 0640 -o root -g root deploy/gateway/rdp-gateway.env.example /etc/rdp-gateway.env
sudo editor /etc/rdp-gateway.env

sudo install -m 0644 deploy/gateway/rdp-gateway.service /etc/systemd/system/rdp-gateway.service
sudo install -m 0644 deploy/gateway/nftables-rdp.service /etc/systemd/system/nftables-rdp.service
sudo install -m 0644 deploy/gateway/rdp_guard.nft /etc/nftables.d/rdp_guard.nft
sudo install -m 0440 deploy/gateway/sudoers.rdp-gateway /etc/sudoers.d/rdp-gateway
sudo visudo -cf /etc/sudoers.d/rdp-gateway

sudo systemctl daemon-reload
sudo systemctl enable --now nftables-rdp rdp-gateway
```

### 部署家庭侧代理

```bash
sudo install -d -m 0755 /opt/rdp6-agent
sudo install -m 0755 bin/rdp6-agent /opt/rdp6-agent/rdp6-agent
sudo install -m 0600 /dev/null /opt/rdp6-agent/token
printf '%s' 'replace-with-long-random-token' | sudo tee /opt/rdp6-agent/token >/dev/null

sudo install -m 0755 deploy/agent/rdp6-agent.init /etc/init.d/rdp6-agent
# 按实际网络修改 RDP6_LISTEN / RDP6_WIN10_MAC / RDP6_LAN_IF / RDP6_HOSTID
sudo editor /etc/init.d/rdp6-agent

sudo /etc/init.d/rdp6-agent enable
sudo /etc/init.d/rdp6-agent start
```

> `rdp6-agent` 只监听 Tailscale 地址，不绑 `0.0.0.0`。公网网关与家侧代理必须使用同一个 `RDP6_TOKEN`。

### 接入 Caddy + Authelia

示例见 `deploy/gateway/Caddyfile.example`。授权页只监听回环地址，Caddy 负责 TLS、`forward_auth` 和写入可信的 `X-Real-IP`：

```caddyfile
rdp.example.com {
    forward_auth 127.0.0.1:9091 {
        uri /api/verify?rd=https://auth.example.com/
    }
    reverse_proxy 127.0.0.1:8090 {
        header_up X-Real-IP {remote_host}
    }
}
```

---

## 仓库结构

```text
SilkRDP/
├── cmd/
│   ├── rdp-gateway/          # 公网网关
│   └── rdp6-agent/           # 家庭侧代理
├── deploy/
│   ├── gateway/              # systemd、nft、sudoers、env、Caddy 示例
│   └── agent/                # OpenWrt procd、fw4 集合、DNAT 示例
├── docs/
│   ├── ARCHITECTURE.md       # 架构、通路、信任边界
│   ├── DEPLOYMENT.md         # 从零部署
│   ├── OPERATIONS.md         # 环境变量、接口、排障
│   ├── SECURITY.md           # 威胁模型与加固清单
│   └── WINDOWS.md            # 目标 Windows 加固/恢复
├── scripts/windows/          # PowerShell 加固、调优、Win11 恢复
├── .github/workflows/ci.yml  # vet + test + build
├── Makefile
└── go.mod
```

## 文档

| 文档 | 内容 |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | 组件职责、三条通路、授权时序、失败模式 |
| [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) | 公网网关、家庭代理、Caddy/Authelia、Windows 的完整部署步骤 |
| [docs/OPERATIONS.md](docs/OPERATIONS.md) | 环境变量、HTTP 接口、状态文件、日志、排障 |
| [docs/SECURITY.md](docs/SECURITY.md) | 威胁模型、最小权限、检查清单 |
| [docs/WINDOWS.md](docs/WINDOWS.md) | RDP/NLA/TCP-only/GPU 加固与 Win11 恢复 |

## 安全说明

- 不要把 `rdp-gateway` 直接暴露在公网而跳过 Authelia/Caddy；授权页必须置于 `forward_auth` 之后。
- 不要把 `rdp6-agent` 绑定到公网地址；它只应监听 Tailscale 接口。
- `deploy/gateway/rdp_guard.nft` 中的 `udp dport 33890 drop` 不可删除，否则 UDP 转发会 fail-open。
- `RDP6_TOKEN`、`/etc/rdp-gateway.env`、`/opt/rdp6-agent/token` 不得提交到 Git。
- 建议为目标机使用低权账户、强制 NLA、账户锁定，并保持系统补丁更新。

## License

MIT
