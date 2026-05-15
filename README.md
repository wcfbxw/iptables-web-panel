# 🚀 Iptables 极简流量中转面板 (Bilingual Web UI)

[中文] | [English]

一个基于 Python Flask + Iptables 打造的轻量级流量中转面板。无需繁琐的命令行操作，通过美观的网页即可一键配置 TCP / UDP 端口转发。自带中英双语无缝切换，适配全球主机玩家！

A lightweight traffic forwarding web panel based on Python Flask + Iptables. Easily configure TCP/UDP port forwarding with a beautiful web UI without complex command-line operations. Built-in seamless bilingual (Chinese/English) switching!

## ✨ 特色功能 (Features)

- 🌐 **中英双语 (Bilingual)**：面板右上角一键切换中文/English。
- ⚡ **极简部署 (Easy Install)**：一键脚本安装，交互式设置端口和密码。
- 🎮 **双栈支持 (TCP/UDP Support)**：支持纯 TCP、纯 UDP (完美支持 Hysteria 2 / 游戏联机) 或 TCP+UDP 双栈。
- 🛡️ **持久运行 (Daemonized)**：自动注册 Systemd 服务，支持开机自启和崩溃重启。
- 🗑️ **精准管理 (Precise Control)**：UI 精准识别并删除指定规则，绝不影响系统内其他的防火墙配置。

## 📦 一键安装脚本 (One-Click Installation)

请在具有 `root` 权限的 Linux 终端中运行以下命令 / Run the following command as `root`:

```bash
wget -O install.sh https://raw.githubusercontent.com/wcfbxw/iptables-web-panel/main/install.sh && sudo bash install.sh
