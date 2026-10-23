# 部署

本文假设：

- 公网网关主机：Debian/Ubuntu，具有公网 IPv4，已安装 `nftables`、`sudo`、`tailscale`、`caddy`、`authelia`。
- 家庭网关：OpenWrt / iStoreOS，已安装 `tailscaled`，使用 fw4/nftables。
- 目标机：Windows Pro/Enterprise/Education，已启用 RDP。
- 公网网关与家庭网关在同一个 Tailscale tailnet 内。

> 示例中的 `203.0.113.10`、`192.168.1.100`、`100.64.0.2`、`rdp.example.com` 都是占位值，必须替换。

---

## 1. 构建

```bash
git clone https://github.com/singll/SilkRDP.git
cd SilkRDP
make build
make check
```

产物：

```text
bin/rdp-gateway
bin/rdp6-agent
```

交叉编译：

```bash
make build GOOS=linux GOARCH=arm64
```

静态二进制，不依赖 libc。

---

## 2. 公网网关

### 2.1 创建运行用户与目录

```bash
sudo useradd --system --home /var/lib/rdp-gateway --shell /usr/sbin/nologin rdpgw
sudo install -d -m 0755 /opt/rdp-gateway
sudo install -d -m 0700 -o rdpgw -g rdpgw /var/lib/rdp-gateway
sudo install -m 0755 bin/rdp-gateway /opt/rdp-gateway/rdp-gateway
sudo install -d -m 0755 /etc/nftables.d
```

### 2.2 配置环境变量

```bash
sudo install -m 0640 -o root -g root deploy/gateway/rdp-gateway.env.example /etc/rdp-gateway.env
sudo editor /etc/rdp-gateway.env
```

至少替换：

- `GW_TARGET`：目标机内网地址，如 `192.168.1.100:3389`。
- `GW_PUBLIC_ADDR`：客户端实际连接的地址，如 `203.0.113.10:33890`。
- `GW_AGENT_URL` / `GW_AGENT_V4_URL`：家侧 agent 的 Tailscale 地址。
- `GW_LOGIN_URL`：Authelia 登录页。
- `RDP6_TOKEN`：高强度随机串，必须与家侧一致。

### 2.3 nftables 白名单

```bash
sudo install -m 0644 deploy/gateway/rdp_guard.nft /etc/nftables.d/rdp_guard.nft
sudo install -m 0644 deploy/gateway/nftables-rdp.service /etc/systemd/system/nftables-rdp.service
sudo systemctl daemon-reload
sudo systemctl enable --now nftables-rdp
sudo nft list table inet rdp_guard
```

确认存在 `allowed_ips` 集合，并且 TCP/UDP 33890 都有 accept + drop 两条规则。

如果不需要内嵌 DERP/STUN，可删除 `udp dport 3478 accept`。

### 2.4 sudoers

```bash
sudo install -m 0440 -o root -g root deploy/gateway/sudoers.rdp-gateway /etc/sudoers.d/rdp-gateway
sudo visudo -cf /etc/sudoers.d/rdp-gateway
```

该规则只允许 `rdpgw` 增删 `inet rdp_guard allowed_ips` 元素，不允许执行其他 root 命令。

### 2.5 systemd

```bash
sudo install -m 0644 deploy/gateway/rdp-gateway.service /etc/systemd/system/rdp-gateway.service
sudo systemctl daemon-reload
sudo systemctl enable --now rdp-gateway
sudo systemctl status rdp-gateway --no-pager
```

验证：

```bash
curl -fsS http://127.0.0.1:8090/health
# ok
```

### 2.6 Caddy + Authelia

参考 `deploy/gateway/Caddyfile.example`。关键要求：

- `forward_auth` 必须在 `reverse_proxy` 之前。
- `header_up X-Real-IP {remote_host}` 必须存在，gateway 只信任这个头。
- 授权页只监听 `127.0.0.1:8090`，不要直接暴露。

```bash
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
curl -I https://rdp.example.com
# 期望 302 到 Authelia 登录
```

---

## 3. 家庭侧代理

以下步骤在 OpenWrt / iStoreOS 上以 root 执行。

### 3.1 安装二进制与 token

```bash
install -d -m 0755 /opt/rdp6-agent
install -m 0755 rdp6-agent /opt/rdp6-agent/rdp6-agent
install -m 0600 /dev/null /opt/rdp6-agent/token
printf '%s' 'replace-with-long-random-token' > /opt/rdp6-agent/token
chmod 0600 /opt/rdp6-agent/token
```

token 必须与公网网关的 `RDP6_TOKEN` 完全相同。

### 3.2 配置 agent

```bash
install -m 0755 deploy/agent/rdp6-agent.init /etc/init.d/rdp6-agent
vi /etc/init.d/rdp6-agent
```

至少修改：

| 变量 | 说明 | 示例 |
|---|---|---|
| `RDP6_LISTEN` | 只监听 Tailscale 地址 | `100.64.0.2:8091` |
| `RDP6_WIN10_MAC` | 目标机 MAC，用于发现 GUA | `AA:BB:CC:DD:EE:FF` |
| `RDP6_LAN_IF` | 家庭局域网接口 | `br-lan` |
| `RDP6_HOSTID` | 目标机 IPv6 host id | `129` |
| `RDP6_RDP_PORT` | 目标机 RDP 端口 | `3389` |
| `RDP4_WAN_IFACE` | 家宽 WAN 接口 | `pppoe-wan` 或 `wan` |

启动：

```bash
/etc/init.d/rdp6-agent enable
/etc/init.d/rdp6-agent start
logread | grep rdp6 | tail -20
ss -tlnp | grep 100.64.0.2:8091
```

### 3.3 fw4 集合与转发规则

把 `deploy/agent/firewall.uci.example` 中需要的内容合并到 `/etc/config/firewall`：

```bash
uci commit firewall
fw4 reload
nft list set inet fw4 rdp6_open
nft list set inet fw4 rdp4_clients
```

两个集合初始为空，表示直连窗口关闭。

### 3.4 IPv4 直连 DNAT

参考 `deploy/agent/90-rdp4-dnat.nft.example`，按实际接口、内网地址、公网端口修改后安装：

```bash
install -m 0644 90-rdp4-dnat.nft /etc/nftables.d/90-rdp4-dnat.nft
nft -c -f /etc/nftables.d/90-rdp4-dnat.nft
fw4 reload
```

不同 OpenWrt 版本的 fw4 链名可能不同，安装前先用 `nft list ruleset` 确认。只保留 TCP，不建议重新打开 UDP（PPPoE MTU 可能导致断连）。

---

## 4. 目标 Windows

推荐直接运行：

```powershell
# 完整加固（低权账户、NLA、锁定、TCP-only、GPU、防火墙）
powershell -ExecutionPolicy Bypass -File .\rdp-win10-hardening.ps1

# 只修连接/画质（TCP-only + KeepAlive + GPU + 60fps）
powershell -ExecutionPolicy Bypass -File .\rdp-win10-tuning.ps1
```

Windows 11 重装后：

```powershell
powershell -ExecutionPolicy Bypass -File .\rdp-win11-recovery.ps1
```

详见 [WINDOWS.md](WINDOWS.md)。

---

## 5. 验证

### 公网网关

```bash
curl -fsS http://127.0.0.1:8090/health
sudo systemctl is-active rdp-gateway nftables-rdp
sudo nft list table inet rdp_guard
sudo journalctl -u rdp-gateway -n 50 --no-pager
```

### 家侧 agent

```bash
logread | grep rdp6 | tail -20
curl -fsS http://100.64.0.2:8091/health
curl -fsS "http://100.64.0.2:8091/status?token=$RDP6_TOKEN"
```

### 端到端

1. 浏览器访问 `https://rdp.example.com`，完成 2FA。
2. 分别点击「中转」「v4 直连」「v6 直连」。
3. 用 `mstsc` 连接页面显示的地址。
4. 等待 TTL 到期，确认新连接被拒绝、已建立会话不中断。

---

## 6. 升级与卸载

### 升级

```bash
make build
sudo install -m 0755 bin/rdp-gateway /opt/rdp-gateway/rdp-gateway
sudo systemctl restart rdp-gateway

# 家侧
install -m 0755 bin/rdp6-agent /opt/rdp6-agent/rdp6-agent
/etc/init.d/rdp6-agent restart
```

升级不会修改 `/etc/rdp-gateway.env`、状态文件或 fw4 集合。

### 卸载

```bash
sudo systemctl disable --now rdp-gateway nftables-rdp
sudo rm -f /etc/systemd/system/rdp-gateway.service /etc/systemd/system/nftables-rdp.service
sudo rm -f /etc/sudoers.d/rdp-gateway
sudo nft delete table inet rdp_guard
sudo rm -rf /opt/rdp-gateway /var/lib/rdp-gateway
# 按需删除 /etc/rdp-gateway.env

/etc/init.d/rdp6-agent stop
/etc/init.d/rdp6-agent disable
rm -rf /opt/rdp6-agent
```

卸载前先确认没有正在使用的 RDP 会话。
