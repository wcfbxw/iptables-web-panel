# 🚀 Iptables 极简流量中转面板 (Bilingual Web UI)

[中文] | [English]

一个基于 Python Flask + Iptables 打造的轻量级流量中转面板。无需繁琐的命令行操作，通过美观的网页即可一键配置 TCP / UDP 端口转发。自带中英双语无缝切换，适配全球主机玩家！

A lightweight traffic forwarding web panel based on Python Flask + Iptables. Easily configure TCP/UDP port forwarding with a beautiful web UI without complex command-line operations. Built-in seamless bilingual (Chinese/English) switching!

## ✨ 特色功能 (Features)

- 🌐 **中英双语 (Bilingual)**：面板右上角一键切换中文/English。
- 🎛️ **现代化面板 (Modern UI)**：更清晰的登录页、运行概览、规则表格和移动端适配。
- ⚡ **极简部署 (Easy Install)**：一键脚本安装，交互式设置端口和密码。
- 🎮 **双栈支持 (TCP/UDP Support)**：支持纯 TCP、纯 UDP (完美支持 Hysteria 2 / 游戏联机) 或 TCP+UDP 双栈。
- 🛡️ **持久运行 (Daemonized)**：自动注册 Systemd 服务，支持开机自启和崩溃重启。
- 🗑️ **精准管理 (Precise Control)**：UI 精准识别并删除指定规则，绝不影响系统内其他的防火墙配置。
- ✅ **安全校验 (Safer Validation)**：自动校验端口范围，阻止重复添加相同的转发规则。

## 🛠️ 日常维护命令 (Maintenance Commands)

面板安装为系统服务，您可以使用标准 `systemctl` 命令进行日常管理：

- **查看运行状态** (Status)：`systemctl status iptables-panel`
- **重启面板服务** (Restart)：`systemctl restart iptables-panel`
- **停止面板服务** (Stop)：`systemctl stop iptables-panel`

## ⬆️ 升级已安装面板 (Upgrade)

如果之前已经通过一键脚本安装过面板，直接重新运行最新安装命令即可：

```bash
wget -O install.sh https://raw.githubusercontent.com/wcfbxw/iptables-web-panel/main/install.sh && sudo bash install.sh
```

脚本检测到旧版本后会出现菜单。选择默认的 `1) 升级/覆盖面板程序，保留现有转发规则` 即可更新到最新面板 UI 和功能。

升级只会覆盖面板程序和 systemd 服务文件，不会主动清空已有的 iptables 转发规则。

## 🗑️ 卸载面板 (Uninstall)

重新运行安装脚本后，检测到已安装面板时可以选择：

- `2) 卸载面板，保留现有转发规则`
- `3) 卸载面板，并删除当前面板可见的转发规则`

选择删除规则时，脚本会要求输入 `DELETE` 二次确认，避免误删。

## ⚠️ 规则清理提示 (Rules Cleanup)
默认卸载面板程序不会中断您已经配置好的流量转发（因为它们已写入内核）。

如果选择“卸载面板，并删除当前面板可见的转发规则”，脚本会尝试删除面板列表中能识别到的 DNAT/MASQUERADE 规则。注意：如果系统里存在非本面板创建、但格式相同的转发规则，也可能被删除。

如果您想彻底清空所有的 NAT 转发规则（注意：这也会一并清空 Docker 等其他程序的 NAT 规则），请手动运行：

Uninstalling the panel WILL NOT interrupt your existing forwarding rules. If you want to flush ALL NAT rules (Warning: this will also clear rules for Docker, etc.), run:
`sudo iptables -t nat -F`


## 📦 一键安装脚本 (One-Click Installation)

请在具有 `root` 权限的 Linux 终端中运行以下命令 / Run the following command as `root`:

```bash
wget -O install.sh https://raw.githubusercontent.com/wcfbxw/iptables-web-panel/main/install.sh && sudo bash install.sh
```

## 🧪 多组合安装器 (Python/Rust + iptables/nftables)

新版实验安装器支持在安装时选择运行时和防火墙后端：

- `Python + iptables`
- `Python + nftables`
- `Rust + iptables`
- `Rust + nftables`

运行：

```bash
wget -O install-v2.sh https://raw.githubusercontent.com/wcfbxw/iptables-web-panel/main/install-v2.sh && sudo bash install-v2.sh
```

说明：

- `iptables` 后端使用 `PREROUTING DNAT + POSTROUTING MASQUERADE`。
- `nftables` 后端会创建独立的 `ip iptables_panel` NAT table，并在里面维护 `prerouting` / `postrouting` chain。
- `Python` 版本使用 Flask。
- `Rust` 版本使用 Rust 标准库实现轻量 HTTP 面板，不依赖 crates.io 三方包，只需要系统包里的 `rustc`。
- 四种组合都会把新规则加上 `iptables-panel` comment，方便后续识别和清理。
