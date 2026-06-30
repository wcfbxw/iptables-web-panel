# Iptables / Nftables 流量中转面板

一个轻量级 Web 流量中转面板，用来通过网页管理 TCP / UDP 端口转发规则。默认稳定版基于 Python Flask + iptables，另提供实验版多组合安装器，支持 Python / Rust 与 iptables / nftables 组合。

## 核心功能

- Web UI 管理 TCP、UDP、TCP+UDP 端口转发
- 自动开启 IPv4 forwarding
- 自动注册 `systemd` 服务，支持开机自启
- 支持目标 IP 或域名解析
- 支持备注、规则列表、规则删除
- 支持查看每条新转发的已用流量
- 支持为每条新转发设置流量上限，到达上限后自动停用
- 支持为每条新转发设置到期时间，到期后自动停用
- 支持端口范围校验和重复规则保护
- 升级面板时默认保留已有转发规则
- 卸载时可选择保留规则或连同面板可见规则一起删除

## 核心安装脚本

稳定版安装脚本：`install.sh`

推荐大多数用户使用这个版本。它使用 `Python Flask + iptables`，兼容性最好。

```bash
wget -O install.sh https://raw.githubusercontent.com/wcfbxw/iptables-web-panel/main/install.sh && sudo bash install.sh
```

安装时会交互式设置：

- 面板运行端口，默认 `5000`
- 管理员用户名，默认 `admin`
- 管理员密码，默认 `123456`

安装完成后访问：

```text
http://你的服务器IP:面板端口
```

## 流量统计和配额限制

稳定版 `install.sh` 支持给每条新转发设置流量上限，单位为 MB。

添加规则时可以填写“流量上限”：

- 不填写：不限流量，只显示已用流量
- 填写数字：例如 `10240` 表示 10240 MB，也就是约 10 GB

面板显示的已用流量是上行和下行的总和：

```text
已用流量 = 上行流量 + 下行流量
```

当这条转发的累计流量达到上限后，后台检测线程会自动删除这条转发规则，使其停止转发。

## 到期时间限制

稳定版 `install.sh` 支持给每条新转发设置到期时间。时间按 UTC+8 解释。

添加规则时可以填写“到期时间”：

- 不填写：不过期
- 填写时间：到达该 UTC+8 时间后自动删除这条转发规则

例如选择 `2026-07-01 18:30`，表示 UTC+8 时间 2026 年 7 月 1 日 18:30 到期。

流量上限和到期时间可以同时设置，任一条件先达到都会停用这条转发。

实现方式：

- 面板为每条新转发额外添加两条带 `iptables-panel-track` comment 的 `FORWARD` 统计规则
- 去程和回程 bytes 会相加，作为该转发的已用流量
- 流量上限和到期时间保存在 `/opt/iptables-panel/quotas.json`

注意：

- 只有升级后新添加的规则会自动带流量统计规则
- 旧版本已经存在的规则可以继续使用，但没有历史流量统计
- 使用“卸载面板，并删除当前面板可见的转发规则”时，会同时尝试清理这些统计规则

## 多组合安装器

实验版安装脚本：`install-v2.sh`

这个版本支持安装时选择运行时和防火墙后端：

- `Python + iptables`
- `Python + nftables`
- `Rust + iptables`
- `Rust + nftables`

```bash
wget -O install-v2.sh https://raw.githubusercontent.com/wcfbxw/iptables-web-panel/main/install-v2.sh && sudo bash install-v2.sh
```

说明：

- `iptables` 后端使用 `PREROUTING DNAT + POSTROUTING MASQUERADE`
- `nftables` 后端会创建独立的 `ip iptables_panel` NAT table
- `Python` 版本使用 Flask
- `Rust` 版本使用 Rust 标准库实现轻量 HTTP 面板，不依赖 crates.io 三方包
- 新增规则会带 `iptables-panel` comment，便于后续识别和清理

## 升级已安装面板

如果之前已经通过一键脚本安装过面板，直接重新运行最新安装命令即可。

稳定版升级：

```bash
wget -O install.sh https://raw.githubusercontent.com/wcfbxw/iptables-web-panel/main/install.sh && sudo bash install.sh
```

脚本检测到已安装面板后会显示菜单：

```text
1) 升级/覆盖面板程序，保留现有转发规则（推荐）
2) 卸载面板，保留现有转发规则
3) 卸载面板，并删除当前面板可见的转发规则
```

选择默认的 `1` 即可升级。升级只会覆盖面板程序和 `systemd` 服务文件，不会主动清空已有 iptables 转发规则。

## 日常维护

面板安装后会注册为系统服务：`iptables-panel`

查看运行状态：

```bash
sudo systemctl status iptables-panel
```

重启面板：

```bash
sudo systemctl restart iptables-panel
```

停止面板：

```bash
sudo systemctl stop iptables-panel
```

启动面板：

```bash
sudo systemctl start iptables-panel
```

设置开机自启：

```bash
sudo systemctl enable iptables-panel
```

取消开机自启：

```bash
sudo systemctl disable iptables-panel
```

查看日志：

```bash
sudo journalctl -u iptables-panel -f
```

## 删除 / 卸载

推荐方式：重新运行稳定版安装脚本，然后选择卸载菜单。

```bash
wget -O install.sh https://raw.githubusercontent.com/wcfbxw/iptables-web-panel/main/install.sh && sudo bash install.sh
```

可选删除方式：

- 选择 `2`：只删除面板程序和服务，保留现有转发规则
- 选择 `3`：删除面板程序和服务，并删除当前面板可见的转发规则

选择 `3` 时，脚本会要求输入：

```text
DELETE
```

只有输入确认后才会删除规则，避免误删。

## 手动卸载面板但保留规则

如果只想删除面板，不删除内核里的转发规则，可以手动运行：

```bash
sudo systemctl stop iptables-panel
sudo systemctl disable iptables-panel
sudo rm -f /etc/systemd/system/iptables-panel.service
sudo systemctl daemon-reload
sudo rm -rf /opt/iptables-panel
```

这样不会删除已经写入内核的 iptables / nftables 规则。

## 规则是否会被删除

不会自动删除。

面板添加规则时，本质是在 Linux 内核防火墙里写入 NAT 规则。删除面板程序、删除 `/opt/iptables-panel`、停止服务，都不会自动删除已经生效的转发规则。

只有以下情况会删除规则：

- 在面板 UI 中点击删除规则
- 运行安装脚本并选择 `3) 卸载面板，并删除当前面板可见的转发规则`
- 手动执行 `iptables -D` / `nft delete rule`
- 手动清空 NAT 规则表

## 手动清空 NAT 规则

谨慎使用。下面命令会清空整个 iptables NAT 表，可能影响 Docker 或其他程序创建的 NAT 规则：

```bash
sudo iptables -t nat -F
```

nftables 后端如果使用 `install-v2.sh` 创建的独立表，可以删除该表：

```bash
sudo nft delete table ip iptables_panel
```

## 转发原理

iptables 后端核心逻辑：

```bash
iptables -t nat -A PREROUTING -p tcp/udp --dport 本地端口 -j DNAT --to-destination 目标IP:目标端口
iptables -t nat -A POSTROUTING -p tcp/udp -d 目标IP --dport 目标端口 -j MASQUERADE
```

nftables 后端核心逻辑：

```bash
nft add table ip iptables_panel
nft add chain ip iptables_panel prerouting '{ type nat hook prerouting priority dstnat; policy accept; }'
nft add chain ip iptables_panel postrouting '{ type nat hook postrouting priority srcnat; policy accept; }'
```
