# Iptables / Nftables Traffic Forwarding Panel

[中文](#中文) | [English](#english)

## 中文

轻量级 TCP/UDP 流量中转面板，通过 Web UI 管理 Linux 内核端口转发规则。

![液态玻璃面板](docs/ui-glass.svg)

### 快速安装

适用于使用 `systemd` 的 Debian / Ubuntu，需要 root 权限和 IPv4。

```bash
wget -O setup.sh https://raw.githubusercontent.com/wcfbxw/iptables-web-panel/main/setup.sh && sudo bash setup.sh
```

安装完成后访问：

```text
http://服务器IP:面板端口
```

默认面板端口为 `5000`，默认用户名为 `admin`；首次安装留空密码会自动生成随机密码。

### 版本选择

| 版本 | 组合 | 建议 |
| --- | --- | --- |
| 稳定版 | Python + iptables | 推荐大多数用户 |
| 实验版 | Python/Rust + iptables/nftables | 需要自定义运行时或后端时使用 |

直接安装指定版本：

```bash
# 稳定版
wget -O install.sh https://raw.githubusercontent.com/wcfbxw/iptables-web-panel/main/install.sh && sudo bash install.sh

# 实验版
wget -O install-v2.sh https://raw.githubusercontent.com/wcfbxw/iptables-web-panel/main/install-v2.sh && sudo bash install-v2.sh
```

实验版可选择：

- `Python + iptables`
- `Python + nftables`
- `Rust + iptables`
- `Rust + nftables`

Rust 编译时若可用内存低于约 384 MB 且没有 swap，安装器会临时创建 512 MB swap，并在编译后删除。

### 核心能力

- 管理 TCP、UDP 或 TCP+UDP 双栈转发
- 支持目标 IP 或域名，域名 IPv4 变化后每 60 秒自动更新规则
- 显示每条规则的上行与下行总流量
- 支持流量上限和 UTC+8 到期时间，到达条件后自动停用
- 支持中转入口域名，并显示为 `域名:监听端口`
- 每个监听端口只能属于一条逻辑转发，且不能占用面板端口
- 升级默认保留规则，卸载时可选择保留或删除规则

### 规则配置

| 字段 | 说明 |
| --- | --- |
| 中转入口域名 | 选填，例如 `relay.example.com`；必须已能解析出 IPv4 |
| 监听端口 | 客户端连接的端口，范围 `1-65535` |
| 目标 IP / 域名 | 实际落地服务器 |
| 目标端口 | 落地服务端口 |
| 流量上限 | 选填，单位 MB；统计上行 + 下行 |
| 到期时间 | 选填，按 UTC+8 解释 |

运行路径：

```text
客户端 → 中转域名:监听端口 → 内核 DNAT → 目标地址:目标端口
```

入口域名只是规则标识，DNS 仍需自行解析到中转服务器。所有指向同一中转服务器的域名共享监听端口，不能通过更换域名重复使用同一个端口。普通 TCP/UDP 转发建议使用仅 DNS（灰云），不要开启普通 CDN 代理。

需要同时转发 TCP 和 UDP 时，请一次选择 `TCP + UDP 双栈`。未填写入口域名的规则显示为 `*:监听端口`。

### 升级与切换

重新执行快速安装命令并选择当前版本即可升级。安装器会沿用当前运行时、后端、面板端口和管理账号，已有内核规则默认保留。

- 同一实验后端内切换 Python / Rust：保留流量统计和限制
- 稳定版与实验版互换：内核规则保留，但限制元数据不保证迁移
- iptables 与 nftables 互换：旧后端规则仍可能生效，但不会显示在新面板中；切换时需要输入 `SWITCH`

### 日常维护

```bash
sudo systemctl status iptables-panel        # 状态
sudo systemctl restart iptables-panel       # 重启
sudo journalctl -u iptables-panel -f        # 实时日志
```

主要文件：

```text
/opt/iptables-panel                 程序和规则限制元数据
/etc/iptables-panel/panel.env       运行配置（权限 600）
/etc/systemd/system/iptables-panel.service
```

### 卸载

重新运行稳定版安装器：

```bash
wget -O install.sh https://raw.githubusercontent.com/wcfbxw/iptables-web-panel/main/install.sh && sudo bash install.sh
```

- 选择 `2`：删除面板和服务，保留当前内核规则
- 选择 `3`：删除面板、服务和面板规则；必须输入 `DELETE` 确认

保留规则只表示卸载脚本不会主动删除它们。卸载后流量限制、到期时间和域名刷新都会停止，规则也可能在服务器重启或防火墙重载后消失。

---

## English

A lightweight Web UI for managing TCP/UDP forwarding rules in the Linux kernel.

![Liquid Glass panel](docs/ui-glass.svg)

### Quick Install

Designed for Debian / Ubuntu with `systemd`. Root access and IPv4 are required.

```bash
wget -O setup.sh https://raw.githubusercontent.com/wcfbxw/iptables-web-panel/main/setup.sh && sudo bash setup.sh
```

Open the panel after installation:

```text
http://server-ip:panel-port
```

The default port is `5000` and the default username is `admin`. Leaving the password empty on the first install generates a random password.

### Versions

| Channel | Combination | Recommendation |
| --- | --- | --- |
| Stable | Python + iptables | Recommended for most users |
| Experimental | Python/Rust + iptables/nftables | For custom runtime or backend requirements |

Install a channel directly:

```bash
# Stable
wget -O install.sh https://raw.githubusercontent.com/wcfbxw/iptables-web-panel/main/install.sh && sudo bash install.sh

# Experimental
wget -O install-v2.sh https://raw.githubusercontent.com/wcfbxw/iptables-web-panel/main/install-v2.sh && sudo bash install-v2.sh
```

Experimental combinations:

- `Python + iptables`
- `Python + nftables`
- `Rust + iptables`
- `Rust + nftables`

When compiling Rust with less than about 384 MB available memory and no swap, the installer creates a temporary 512 MB swap file and removes it afterward.

### Features

- Manage TCP, UDP, or TCP+UDP forwarding
- Use a target IP or domain; IPv4 DNS changes refresh the rule every 60 seconds
- Display upload + download traffic for each rule
- Disable rules after a traffic quota or UTC+8 expiration time is reached
- Store a relay entry domain and display `domain:listening-port`
- Allow each listening port to belong to only one logical rule and protect the panel port
- Preserve rules by default during upgrades and offer rule retention during uninstall

### Rule Fields

| Field | Description |
| --- | --- |
| Relay entry domain | Optional, for example `relay.example.com`; it must resolve to IPv4 |
| Listening port | Client-facing port in the range `1-65535` |
| Target IP / domain | Destination server |
| Target port | Destination service port |
| Traffic quota | Optional MB value; usage is upload + download |
| Expiration | Optional UTC+8 time |

Traffic path:

```text
Client → relay-domain:listening-port → kernel DNAT → target:target-port
```

The relay domain is metadata. Its DNS record must point to the relay server. All domains pointing to one relay server share the same listening-port pool, so changing the hostname does not allow port reuse. Use DNS-only records for ordinary TCP/UDP forwarding instead of a standard CDN proxy.

Select `TCP + UDP` in one operation when both protocols are required. Rules without an entry domain are displayed as `*:listening-port`.

### Upgrade and Switching

Rerun the quick-install command and select the current channel. The installer inherits the current runtime, backend, panel port, and admin account while preserving kernel rules by default.

- Switching Python / Rust within one experimental backend preserves usage and limits
- Switching stable / experimental preserves kernel rules, but limit metadata is not guaranteed to migrate
- Switching iptables / nftables may leave old rules active but hidden from the new panel; type `SWITCH` when prompted

### Maintenance

```bash
sudo systemctl status iptables-panel        # Status
sudo systemctl restart iptables-panel       # Restart
sudo journalctl -u iptables-panel -f        # Live logs
```

Main paths:

```text
/opt/iptables-panel                 Program and rule-limit metadata
/etc/iptables-panel/panel.env       Runtime configuration (mode 600)
/etc/systemd/system/iptables-panel.service
```

### Uninstall

Rerun the stable installer:

```bash
wget -O install.sh https://raw.githubusercontent.com/wcfbxw/iptables-web-panel/main/install.sh && sudo bash install.sh
```

- Choose `2`: remove the panel and service while keeping current kernel rules
- Choose `3`: remove the panel, service, and panel rules; type `DELETE` to confirm

Keeping rules only means the uninstaller does not actively delete them. Traffic quotas, expiration checks, and DNS refresh stop after uninstall, and the rules may disappear after a reboot or firewall reload.
