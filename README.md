# Traffic Forwarding Web Panel Lite

[中文](#中文) | [English](#english)

Permanent low-memory branch of `wcfbxw/iptables-web-panel`. It uses a precompiled Rust service with either iptables or nftables and is designed for small NAT servers where Python installation or local Rust compilation is impractical.

![Liquid Glass panel](docs/ui-glass.svg)

## 中文

### Lite 版特点

- 只运行预编译 Rust 程序，不安装 Python、pip、Flask、Gunicorn 或 rustc
- 安装过程不执行 `apt update`，避免低内存机器的软件包管理峰值
- 自动识别 amd64、arm64、armv7，并校验下载文件的 SHA-256
- 可选择已经安装的 iptables 或 nftables
- 串行处理管理请求，仅保留一个 512 KB 栈的后台巡检线程
- 支持 TCP、UDP、TCP + UDP 端口转发
- 支持目标域名解析、中转入口域名、流量配额和 UTC+8 到期时间
- 升级失败自动恢复原程序、配置和 systemd 服务

### 适用范围

建议用于 Debian/Ubuntu、systemd、IPv4 和 root 环境。系统必须已经具备：

- `iptables` + `iptables-save`，或者 `nft`
- `curl` 或 `wget`
- `sha256sum`
- 操作防火墙和开启 `net.ipv4.ip_forward` 的容器权限

安装器不会为了补齐依赖而运行 apt。共享 NAT/OpenVZ 容器如果禁止 `NET_ADMIN` 或内核转发，增加 swap 也无法解决。

内存建议：

- 约 96 MB：Lite 版的主要目标环境
- 64-96 MB：通常可以安装，稳定性取决于系统剩余内存和后台服务
- 低于 64 MB：不承诺稳定运行

这些范围不是固定 RSS 保证，实际占用应在目标服务器上通过 systemd 统计确认。

### 一键安装

```bash
wget -O install-lite.sh https://raw.githubusercontent.com/wcfbxw/iptables-web-panel/lite/install.sh && sudo bash install-lite.sh
```

也可以使用 curl：

```bash
curl -fLo install-lite.sh https://raw.githubusercontent.com/wcfbxw/iptables-web-panel/lite/install.sh && sudo bash install-lite.sh
```

安装器会让你选择已有的防火墙后端，并设置面板端口、管理员账号和密码。默认面板端口为 `5000`。

### 从 main 版本切换

直接运行 Lite 安装命令并选择升级。安装器会继承现有端口和账号，保留内核转发规则与 `/opt/iptables-panel/limits.tsv`。

切换 iptables/nftables 后端时，旧后端规则仍留在内核中，但不会出现在新后端面板中，也不会自动迁移。

### 日常维护

```bash
systemctl status iptables-panel
systemctl restart iptables-panel
journalctl -u iptables-panel -n 50 --no-pager
systemctl show iptables-panel -p MemoryCurrent
/opt/iptables-panel/panel --version
```

配置和数据位置：

```text
/opt/iptables-panel/panel
/opt/iptables-panel/limits.tsv
/etc/iptables-panel/panel.env
/etc/systemd/system/iptables-panel.service
```

### 升级与卸载

重新运行一键安装命令即可升级。菜单提供：

1. 升级或切换到 Lite，保留转发规则
2. 卸载面板，保留转发规则
3. 卸载面板，并删除当前后端中可识别的转发规则

保留规则只代表卸载器不主动删除内核规则。卸载后流量配额、到期停用和域名刷新都会停止，规则也可能在服务器重启或防火墙重载后消失。

### 发布机制

`.github/workflows/lite-release.yml` 在 `lite-v*` 标签上构建以下静态程序：

- `iptables-panel-linux-amd64`
- `iptables-panel-linux-arm64`
- `iptables-panel-linux-armv7`

每个文件都有独立 `.sha256` 校验文件。安装脚本中的 `LITE_VERSION` 必须和 `Cargo.toml` 版本以及标签一致。
amd64 构建还会启动真实 HTTP 服务做冒烟测试，并要求 CI 空闲 RSS 低于 32 MB；该结果用于防止明显回退，不代表所有系统上的固定占用。

## English

### Lite characteristics

- Runs a prebuilt Rust binary; no Python, pip, Flask, Gunicorn, or rustc installation
- Does not run `apt update`, avoiding package-manager memory spikes
- Detects amd64, arm64, and armv7 and verifies SHA-256 checksums
- Uses an already installed iptables or nftables backend
- Handles admin requests serially and keeps one 512 KB watcher thread
- Supports TCP, UDP, dual-protocol forwarding, destination DNS, relay entry domains, traffic quotas, and UTC+8 expiry
- Restores the previous binary, configuration, and systemd unit when an upgrade fails

### Requirements

Use Debian/Ubuntu with systemd, IPv4, and root access. The image must already provide:

- `iptables` plus `iptables-save`, or `nft`
- `curl` or `wget`
- `sha256sum`
- Permission to manage the firewall and enable `net.ipv4.ip_forward`

The installer deliberately does not use apt to add missing dependencies. Shared NAT/OpenVZ containers without `NET_ADMIN` or kernel-forwarding permission cannot be fixed with swap.

The primary target is around 96 MB RAM. Systems with 64-96 MB may work when enough memory remains available; operation below 64 MB is not guaranteed. Measure the actual service RSS on the target host.

### Install

```bash
wget -O install-lite.sh https://raw.githubusercontent.com/wcfbxw/iptables-web-panel/lite/install.sh && sudo bash install-lite.sh
```

Or:

```bash
curl -fLo install-lite.sh https://raw.githubusercontent.com/wcfbxw/iptables-web-panel/lite/install.sh && sudo bash install-lite.sh
```

The installer selects an available firewall backend and asks for the panel port and administrator credentials. The default port is `5000`.

### Upgrade from main

Run the Lite installer and select upgrade. Existing kernel forwarding rules and `/opt/iptables-panel/limits.tsv` are preserved. Rules are not migrated when changing between iptables and nftables; old-backend rules remain in the kernel and are hidden from the selected backend.

### Maintenance

```bash
systemctl status iptables-panel
systemctl restart iptables-panel
journalctl -u iptables-panel -n 50 --no-pager
systemctl show iptables-panel -p MemoryCurrent
/opt/iptables-panel/panel --version
```

### Upgrade and uninstall

Rerun the installation command. The menu can upgrade while preserving rules, uninstall while preserving rules, or uninstall and remove recognizable rules from the active backend.

When rules are preserved, quota enforcement, expiry handling, and DNS refresh stop with the panel. Kernel rules may also disappear after a reboot or firewall reload.

### Releases

The `lite-v*` workflow builds statically linked amd64, arm64, and armv7 assets with separate SHA-256 files. `LITE_VERSION`, the Cargo package version, and the release tag must match.
The amd64 job also starts the HTTP service and rejects an idle CI RSS of 32 MB or more. This is a regression guard, not a fixed memory guarantee for every host.
