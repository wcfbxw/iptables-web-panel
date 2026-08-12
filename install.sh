#!/bin/bash

# 确保脚本以 root 权限运行
if [ "$EUID" -ne 0 ]; then 
  echo "❌ 请使用 root 权限运行此脚本 (例如: sudo bash install.sh)"
  exit 1
fi

INSTALL_DIR="/opt/iptables-panel"
SERVICE_FILE="/etc/systemd/system/iptables-panel.service"

cleanup_visible_rules() {
  echo "⚠️ 即将删除当前面板可识别的 PREROUTING DNAT 和对应 MASQUERADE 规则。"
  echo "⚠️ 如果系统里存在非本面板创建、但格式相同的转发规则，也可能被删除。"
  read -p "请输入 DELETE 确认删除这些规则: " CONFIRM_DELETE
  if [ "$CONFIRM_DELETE" != "DELETE" ]; then
    echo "已取消规则删除。"
    return
  fi

  if ! command -v python3 > /dev/null 2>&1; then
    echo "❌ 未找到 python3，无法安全解析并删除规则。面板文件仍将继续卸载。"
    return
  fi

  python3 << 'PY'
import re
import subprocess

def run(cmd):
    print("+ " + " ".join(cmd))
    subprocess.run(cmd, check=False)

result = subprocess.run(["iptables-save", "-t", "nat"], capture_output=True, text=True)
for line in result.stdout.splitlines():
    if not line.startswith("-A PREROUTING") or "-j DNAT" not in line:
        continue

    proto_m = re.search(r"-p\s+(tcp|udp)", line)
    lport_m = re.search(r"--dport\s+(\d+)", line)
    target_m = re.search(r"--to-destination\s+([\d\.]+):(\d+)", line)
    remark_m = re.search(r'--comment\s+"([^"]+)"', line)
    if not proto_m or not lport_m or not target_m:
        continue

    proto = proto_m.group(1)
    local_port = lport_m.group(1)
    target_ip = target_m.group(1)
    target_port = target_m.group(2)
    remark = remark_m.group(1) if remark_m else ""

    pre_cmd = ["iptables", "-t", "nat", "-D", "PREROUTING", "-p", proto, "--dport", local_port]
    if remark:
        pre_cmd.extend(["-m", "comment", "--comment", remark])
    pre_cmd.extend(["-j", "DNAT", "--to-destination", f"{target_ip}:{target_port}"])
    run(pre_cmd)
    run(["iptables", "-t", "nat", "-D", "POSTROUTING", "-p", proto, "-d", target_ip, "--dport", target_port, "-j", "MASQUERADE"])

filter_result = subprocess.run(["iptables-save"], capture_output=True, text=True)
for line in filter_result.stdout.splitlines():
    if not line.startswith("-A FORWARD") or "iptables-panel-track:" not in line:
        continue

    proto_m = re.search(r"-p\s+(tcp|udp)", line)
    comment_m = re.search(r'--comment\s+"?([^"]*iptables-panel-track:[^"\s]+)"?', line)
    if not proto_m or not comment_m:
        continue

    proto = proto_m.group(1)
    comment = comment_m.group(1)
    dst_m = re.search(r"-d\s+([\d\.\/]+)", line)
    src_m = re.search(r"-s\s+([\d\.\/]+)", line)
    dport_m = re.search(r"--dport\s+(\d+)", line)
    sport_m = re.search(r"--sport\s+(\d+)", line)

    if dst_m and dport_m:
        run(["iptables", "-D", "FORWARD", "-p", proto, "-d", dst_m.group(1), "--dport", dport_m.group(1), "-m", "comment", "--comment", comment, "-j", "ACCEPT"])
    elif src_m and sport_m:
        run(["iptables", "-D", "FORWARD", "-p", proto, "-s", src_m.group(1), "--sport", sport_m.group(1), "-m", "comment", "--comment", comment, "-j", "ACCEPT"])
PY
}

uninstall_panel() {
  local remove_rules="$1"
  if [ "$remove_rules" = "yes" ]; then
    cleanup_visible_rules
  fi

  systemctl stop iptables-panel > /dev/null 2>&1 || true
  systemctl disable iptables-panel > /dev/null 2>&1 || true
  rm -f "$SERVICE_FILE"
  systemctl daemon-reload > /dev/null 2>&1 || true
  rm -rf "$INSTALL_DIR"

  if [ "$remove_rules" = "yes" ]; then
    echo "✅ 面板已卸载，并已尝试删除当前面板可见的转发规则。"
  else
    echo "✅ 面板已卸载。现有 iptables 转发规则已保留。"
  fi
}

confirm_stable_transition() {
  if [ ! -f "$SERVICE_FILE" ]; then
    return
  fi

  local current_exec current_backend
  current_exec=$(sed -n 's/^ExecStart=//p' "$SERVICE_FILE" | head -n 1)
  if ! printf '%s' "$current_exec" | grep -q -- '--backend'; then
    return
  fi

  if printf '%s' "$current_exec" | grep -q -- '--backend nftables'; then
    current_backend="nftables"
  else
    current_backend="iptables"
  fi

  if [ "$current_backend" = "nftables" ]; then
    echo "⚠️  稳定版固定使用 iptables，当前实验版使用 nftables。"
    echo "⚠️  nftables 规则会继续保留在内核中，但不会显示在稳定版面板里。"
    echo "⚠️  本安装器不会自动迁移或删除这些规则。"
    read -r -p "确认切换到 iptables 请输入 SWITCH: " BACKEND_SWITCH_CONFIRM
    if [ "$BACKEND_SWITCH_CONFIRM" != "SWITCH" ]; then
      echo "已取消安装。"
      exit 0
    fi
  elif [ "${PANEL_CHANNEL_SWITCH_CONFIRMED:-0}" != "1" ]; then
    echo "⚠️  即将从实验版切换到稳定版。转发规则会保留，但配额和到期时间元数据不会自动迁移。"
    read -r -p "确认切换版本请输入 SWITCH: " CHANNEL_SWITCH_CONFIRM
    if [ "$CHANNEL_SWITCH_CONFIRM" != "SWITCH" ]; then
      echo "已取消安装。"
      exit 0
    fi
  fi
}

if [ -d "$INSTALL_DIR" ] || [ -f "$SERVICE_FILE" ]; then
  echo "====================================================="
  echo "   检测到已安装的 Iptables 流量中转面板"
  echo "====================================================="
  echo "1) 升级/覆盖面板程序，保留现有转发规则（推荐）"
  echo "2) 卸载面板，保留现有转发规则"
  echo "3) 卸载面板，并删除当前面板可见的转发规则"
  read -p "请选择操作 [默认: 1]: " EXISTING_ACTION
  EXISTING_ACTION=${EXISTING_ACTION:-1}

  case "$EXISTING_ACTION" in
    2)
      uninstall_panel "no"
      exit 0
      ;;
    3)
      uninstall_panel "yes"
      exit 0
      ;;
    *)
      confirm_stable_transition
      echo "将继续升级面板程序。现有 iptables 转发规则不会被清空。"
      ;;
  esac
fi

echo "====================================================="
echo "   🚀 欢迎安装 Iptables 流量中转面板 (支持域名解析版)   "
echo "====================================================="

read -p "👉 请设置面板运行端口 [默认: 5000]: " PANEL_PORT
PANEL_PORT=${PANEL_PORT:-5000}

read -p "👉 请设置管理员用户名 [默认: admin]: " PANEL_USER
PANEL_USER=${PANEL_USER:-admin}

read -p "👉 请设置管理员密码 [默认: 123456]: " PANEL_PASS
PANEL_PASS=${PANEL_PASS:-123456}

PANEL_THEME="glass"

echo ""
echo "⏳ 正在安装依赖环境 (Python3 & Flask)..."
apt-get update -y > /dev/null 2>&1
apt-get install -y python3 python3-pip iptables > /dev/null 2>&1
pip3 install flask --break-system-packages > /dev/null 2>&1 || pip3 install flask > /dev/null 2>&1

echo "📁 正在配置程序文件..."
mkdir -p $INSTALL_DIR

# 写入支持双语、备注和域名的 panel.py
cat << 'EOF' > $INSTALL_DIR/panel.py
import subprocess, ipaddress, os, argparse, re, socket, json, hashlib, threading, time, datetime
from flask import Flask, request, render_template_string, session, redirect, url_for

parser = argparse.ArgumentParser()
parser.add_argument('--port', type=int, default=5000)
parser.add_argument('--user', type=str, default='admin')
parser.add_argument('--password', type=str, default='123456')
parser.add_argument('--theme', type=str, default='map')
args = parser.parse_args()

ADMIN_USER, ADMIN_PASS, PANEL_PORT = args.user, args.password, args.port
PANEL_THEME = "glass"
app = Flask(__name__)
app.secret_key = os.urandom(24)
QUOTA_FILE = "/opt/iptables-panel/quotas.json"
TRACK_PREFIX = "iptables-panel-track:"

# --- 双语字典 (加入备注字段和域名提示) ---
T = {
    'zh': {
        'login_title': '流量中转面板登录', 'username': '用户名', 'password': '密码', 'login_btn': '登录面板',
        'panel_title': '流量中转管理面板', 'logout': '退出', 'add_rule': '新建转发规则',
        'protocol': '转发协议', 'local_port': '监听端口', 'target_ip': '目标 IP 或 域名', 'target_port': '目标端口',
        'remark': '备注信息', 'remark_ph': '选填 (如: Web/游戏服)', 'add_btn': '立即添加转发规则', 
        'cur_rules': '当前生效规则', 'proto': '协议', 'forward_to': '转发至',
        'action': '操作', 'delete': '删除', 'no_rules': '当前没有配置任何转发规则。',
        'confirm_del': '确定要删除这条规则吗？', 'tcp_only': '纯 TCP (网页/SSH)',
        'udp_only': '纯 UDP (Hysteria2)', 'dual_stack': 'TCP + UDP 双栈',
        'lang_btn': 'English', 'switch_to': 'en', 'status_online': '服务在线', 'err_port': '端口必须是 1-65535 之间的数字！',
        'err_ip': '无效的 IP 地址或域名解析失败！', 'err_duplicate': '规则已存在，无需重复添加。',
        'add_success': '添加成功！', 'del_success': '删除成功',
        'login_error': '用户名或密码错误', 'overview': '运行概览', 'total_rules': '总规则', 'total_traffic': '总流量',
        'tcp_rules': 'TCP 规则', 'udp_rules': 'UDP 规则', 'traffic': '流量',
        'quota': '流量上限', 'quota_ph': '选填，单位 MB', 'quota_reached': '流量已达上限，规则已自动停用。',
        'err_quota': '流量上限必须是数字，单位 MB。', 'unlimited': '不限',
        'traffic_note': '流量为上行 + 下行总和', 'expires_at': '到期时间', 'expires_ph': 'UTC+8',
        'err_expires': '到期时间格式无效，请使用 UTC+8 时间。'
    },
    'en': {
        'login_title': 'Traffic Forwarding Login', 'username': 'Username', 'password': 'Password', 'login_btn': 'Sign in',
        'panel_title': 'Traffic Forwarding Panel', 'logout': 'Logout', 'add_rule': 'Create Forwarding Rule',
        'protocol': 'Protocol', 'local_port': 'Local Port', 'target_ip': 'Target IP / Domain', 'target_port': 'Target Port',
        'remark': 'Remark / Note', 'remark_ph': 'Optional', 'add_btn': 'Add Forwarding Rule', 
        'cur_rules': 'Active Rules', 'proto': 'Protocol', 'forward_to': 'Forward to',
        'action': 'Action', 'delete': 'Delete', 'no_rules': 'No rules configured currently.',
        'confirm_del': 'Are you sure you want to delete this rule?', 'tcp_only': 'TCP Only (Web)',
        'udp_only': 'UDP Only (Hysteria2)', 'dual_stack': 'TCP + UDP Dual',
        'lang_btn': '中文', 'switch_to': 'zh', 'status_online': 'Service online', 'err_port': 'Ports must be numbers between 1 and 65535!',
        'err_ip': 'Invalid IP or Domain resolution failed!', 'err_duplicate': 'Rule already exists. No duplicate was added.',
        'add_success': 'Added successfully!', 'del_success': 'Deleted',
        'login_error': 'Invalid username or password', 'overview': 'Overview', 'total_rules': 'Total Rules', 'total_traffic': 'Total Traffic',
        'tcp_rules': 'TCP Rules', 'udp_rules': 'UDP Rules', 'traffic': 'Traffic',
        'quota': 'Traffic Limit', 'quota_ph': 'Optional, MB', 'quota_reached': 'Traffic limit reached. Rule was disabled.',
        'err_quota': 'Traffic limit must be a number in MB.', 'unlimited': 'Unlimited',
        'traffic_note': 'Traffic is upload + download total', 'expires_at': 'Expires At', 'expires_ph': 'UTC+8',
        'err_expires': 'Invalid expiration time. Use UTC+8 time.'
    }
}

HEADER_HTML = """
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>{{ t.panel_title }}</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
    <style>
        :root {
            --panel-bg: #f4f6f8;
            --panel-surface: #ffffff;
            --panel-border: #d9e0e8;
            --panel-text: #172033;
            --panel-muted: #6b7685;
            --panel-primary: #2563eb;
            --panel-primary-dark: #1d4ed8;
            --panel-danger: #dc2626;
            --panel-success: #15803d;
            --panel-warning: #b45309;
        }
        * { box-sizing: border-box; }
        body {
            min-height: 100vh;
            margin: 0;
            background: var(--panel-bg);
            color: var(--panel-text);
            font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
            letter-spacing: 0;
        }
        .topbar {
            border-bottom: 1px solid var(--panel-border);
            background: rgba(255,255,255,0.94);
            backdrop-filter: blur(10px);
        }
        .topbar-inner {
            max-width: 1180px;
            min-height: 64px;
            margin: 0 auto;
            padding: 0 18px;
            display: flex;
            align-items: center;
            justify-content: space-between;
            gap: 14px;
        }
        .brand {
            display: flex;
            align-items: center;
            gap: 10px;
            min-width: 0;
            font-weight: 700;
            font-size: 1.02rem;
        }
        .brand-mark {
            width: 34px;
            height: 34px;
            border-radius: 8px;
            display: inline-flex;
            align-items: center;
            justify-content: center;
            color: #fff;
            background: var(--panel-primary);
            font-weight: 800;
            flex: 0 0 auto;
        }
        .brand-title {
            overflow: hidden;
            text-overflow: ellipsis;
            white-space: nowrap;
        }
        .page-shell {
            max-width: 1180px;
            margin: 0 auto;
            padding: 26px 18px 44px;
        }
        .login-shell {
            min-height: calc(100vh - 65px);
            display: grid;
            place-items: center;
            padding: 28px 18px;
        }
        .login-card, .panel-card, .metric {
            background: var(--panel-surface);
            border: 1px solid var(--panel-border);
            border-radius: 8px;
            box-shadow: 0 10px 26px rgba(23,32,51,0.06);
        }
        .login-card {
            width: min(100%, 420px);
            padding: 28px;
        }
        .login-title, .page-title {
            margin: 0;
            font-weight: 750;
            letter-spacing: 0;
        }
        .login-title { font-size: 1.35rem; text-align: center; }
        .page-title { font-size: clamp(1.35rem, 2vw, 1.85rem); }
        .page-actions {
            display: flex;
            align-items: center;
            gap: 10px;
            flex-wrap: wrap;
            justify-content: flex-end;
        }
        .page-header {
            margin-bottom: 18px;
        }
        .btn {
            border-radius: 8px;
            font-weight: 650;
        }
        .btn-primary {
            background: var(--panel-primary);
            border-color: var(--panel-primary);
        }
        .btn-primary:hover {
            background: var(--panel-primary-dark);
            border-color: var(--panel-primary-dark);
        }
        .btn-outline-secondary {
            color: var(--panel-text);
            border-color: var(--panel-border);
            background: #fff;
        }
        .btn-outline-danger {
            color: var(--panel-danger);
            border-color: #f1b9b9;
            background: #fff;
        }
        .form-label {
            color: var(--panel-muted);
            font-weight: 650;
            font-size: .86rem;
            margin-bottom: 6px;
        }
        .form-control, .form-select {
            min-height: 42px;
            border-radius: 8px;
            border-color: var(--panel-border);
            color: var(--panel-text);
        }
        .form-control:focus, .form-select:focus {
            border-color: var(--panel-primary);
            box-shadow: 0 0 0 .2rem rgba(37,99,235,.12);
        }
        .metric-grid {
            display: grid;
            grid-template-columns: repeat(4, minmax(0, 1fr));
            gap: 14px;
            margin: 20px 0;
        }
        .metric {
            padding: 16px 18px;
        }
        .metric-label {
            color: var(--panel-muted);
            font-size: .82rem;
            font-weight: 700;
            text-transform: uppercase;
        }
        .metric-value {
            margin-top: 6px;
            font-size: 1.85rem;
            line-height: 1;
            font-weight: 800;
        }
        .panel-card {
            margin-top: 18px;
            overflow: hidden;
        }
        .panel-header {
            padding: 16px 18px;
            border-bottom: 1px solid var(--panel-border);
            background: #fbfcfe;
            font-weight: 750;
        }
        .panel-body {
            padding: 18px;
        }
        .table {
            margin: 0;
            vertical-align: middle;
        }
        .table thead th {
            color: var(--panel-muted);
            background: #f7f9fb;
            border-bottom: 1px solid var(--panel-border);
            font-size: .82rem;
            font-weight: 750;
            text-transform: uppercase;
            white-space: nowrap;
        }
        .table tbody td {
            padding-top: 14px;
            padding-bottom: 14px;
            border-color: #edf1f5;
        }
        .badge {
            border-radius: 6px;
            padding: .42rem .58rem;
            font-weight: 750;
        }
        .badge-tcp { background-color: #2563eb; }
        .badge-udp { background-color: #7c3aed; }
        .target-pill {
            display: inline-flex;
            max-width: 100%;
            padding: .42rem .58rem;
            border-radius: 6px;
            background: #111827;
            color: #fff;
            font-weight: 700;
            white-space: nowrap;
        }
        .remark-cell {
            max-width: 240px;
            color: var(--panel-muted);
            overflow: hidden;
            text-overflow: ellipsis;
            white-space: nowrap;
        }
        .alert {
            border-radius: 8px;
            border: 1px solid transparent;
            font-weight: 650;
            margin-bottom: 18px;
        }
        .empty-row {
            padding: 36px 18px !important;
            color: var(--panel-muted);
        }
        @media (max-width: 768px) {
            .topbar-inner { padding: 0 14px; }
            .brand-title { max-width: 58vw; }
            .page-shell { padding: 20px 14px 34px; }
            .page-header {
                align-items: flex-start !important;
                gap: 14px;
                flex-direction: column;
            }
            .page-actions {
                width: 100%;
                justify-content: stretch;
            }
            .page-actions .btn {
                flex: 1 1 auto;
            }
            .metric-grid {
                grid-template-columns: 1fr;
            }
            .login-card { padding: 22px; }
            .panel-body { padding: 16px; }
        }
        .theme-glass {
            --panel-bg: #edf8fb;
            --panel-surface: rgba(255,255,255,.62);
            --panel-border: rgba(255,255,255,.58);
            --panel-text: #0b1b35;
            --panel-muted: #526173;
            --panel-primary: #3157d5;
            --panel-primary-dark: #2442a8;
            background:
                linear-gradient(120deg, rgba(255,255,255,.2) 0 8%, transparent 8% 26%, rgba(125,211,252,.18) 26% 34%, transparent 34% 62%, rgba(216,180,254,.16) 62% 70%, transparent 70%),
                linear-gradient(150deg, #dff7ff 0%, #f7fbff 34%, #d8f3ee 67%, #f4e9ff 100%);
            position: relative;
            overflow-x: hidden;
        }
        .theme-glass::before {
            content: "";
            position: fixed;
            inset: -18%;
            pointer-events: none;
            background:
                linear-gradient(105deg, transparent 0 18%, rgba(255,255,255,.62) 19%, transparent 25% 48%, rgba(103,232,249,.22) 52%, transparent 59% 100%),
                linear-gradient(62deg, transparent 0 24%, rgba(196,181,253,.24) 28%, transparent 36% 70%, rgba(255,255,255,.42) 74%, transparent 82%);
            filter: blur(22px) saturate(1.25);
            transform: rotate(-6deg);
            opacity: .88;
            z-index: 0;
        }
        .theme-glass::after {
            content: "";
            position: fixed;
            inset: 0;
            pointer-events: none;
            background-image:
                linear-gradient(rgba(255,255,255,.22) 1px, transparent 1px),
                linear-gradient(90deg, rgba(255,255,255,.16) 1px, transparent 1px);
            background-size: 78px 78px;
            mask-image: linear-gradient(to bottom, rgba(0,0,0,.42), transparent 72%);
            opacity: .34;
            z-index: 0;
        }
        .theme-glass .topbar,
        .theme-glass .page-shell,
        .theme-glass .login-shell {
            position: relative;
            z-index: 1;
        }
        .theme-glass .topbar,
        .theme-glass .metric,
        .theme-glass .panel-card,
        .theme-glass .login-card {
            position: relative;
            background:
                linear-gradient(135deg, rgba(255,255,255,.72), rgba(255,255,255,.3) 42%, rgba(255,255,255,.55)),
                linear-gradient(120deg, rgba(125,211,252,.16), rgba(216,180,254,.14));
            border-color: rgba(255,255,255,.62);
            box-shadow:
                inset 0 1px 0 rgba(255,255,255,.92),
                inset 0 -20px 44px rgba(255,255,255,.24),
                0 24px 64px rgba(54, 78, 112, .18);
            backdrop-filter: blur(28px) saturate(1.65);
        }
        .theme-glass .topbar::before,
        .theme-glass .metric::before,
        .theme-glass .panel-card::before,
        .theme-glass .login-card::before {
            content: "";
            position: absolute;
            inset: 1px;
            pointer-events: none;
            border-radius: inherit;
            background:
                linear-gradient(120deg, rgba(255,255,255,.82), transparent 24% 64%, rgba(255,255,255,.42)),
                linear-gradient(180deg, rgba(255,255,255,.22), transparent 46%);
            opacity: .7;
            mix-blend-mode: screen;
        }
        .theme-glass .topbar::after,
        .theme-glass .metric::after,
        .theme-glass .panel-card::after,
        .theme-glass .login-card::after {
            content: "";
            position: absolute;
            left: 16px;
            right: 16px;
            top: 10px;
            height: 1px;
            pointer-events: none;
            border-radius: 999px;
            background: rgba(255,255,255,.9);
            box-shadow: 0 12px 28px rgba(255,255,255,.42);
        }
        .theme-glass .topbar > *,
        .theme-glass .metric > *,
        .theme-glass .panel-card > *,
        .theme-glass .login-card > * {
            position: relative;
            z-index: 1;
        }
        .theme-glass .panel-header,
        .theme-glass .table thead th {
            background: rgba(255,255,255,.34);
            border-color: rgba(255,255,255,.46);
        }
        .theme-glass .table td,
        .theme-glass .table th {
            border-color: rgba(255,255,255,.42);
        }
        .theme-glass .form-control,
        .theme-glass .form-select {
            background:
                linear-gradient(180deg, rgba(255,255,255,.74), rgba(255,255,255,.38));
            border-color: rgba(255,255,255,.68);
            box-shadow:
                inset 0 1px 0 rgba(255,255,255,.88),
                inset 0 0 18px rgba(255,255,255,.32),
                0 10px 24px rgba(54,78,112,.12);
            backdrop-filter: blur(18px) saturate(1.45);
        }
        .theme-glass .btn-primary {
            background:
                linear-gradient(135deg, rgba(49,87,213,.92), rgba(103,232,249,.72)),
                linear-gradient(120deg, rgba(255,255,255,.32), transparent);
            border-color: rgba(255,255,255,.58);
            box-shadow:
                inset 0 1px 0 rgba(255,255,255,.62),
                inset 0 -14px 26px rgba(11,27,53,.12),
                0 16px 34px rgba(49,87,213,.24);
        }
        .theme-glass .page-title::after {
            content: "C";
            display: inline-flex;
            align-items: center;
            justify-content: center;
            width: 28px;
            height: 28px;
            margin-left: 10px;
            border-radius: 8px;
            background: rgba(49,87,213,.12);
            color: #3157d5;
            font-size: .88rem;
            vertical-align: middle;
        }

        /* Network console redesign */
        body {
            background:
                linear-gradient(118deg, transparent 0 14%, rgba(98,185,194,.10) 14% 23%, transparent 23% 62%, rgba(123,104,238,.08) 62% 72%, transparent 72%),
                #eaf0f4;
        }
        .topbar {
            position: sticky;
            top: 0;
            z-index: 20;
            border-bottom-color: rgba(115,132,151,.22);
            background: rgba(242,247,250,.78);
            box-shadow: 0 8px 28px rgba(28,45,66,.06);
            backdrop-filter: blur(22px) saturate(1.35);
        }
        .topbar-inner {
            max-width: 1400px;
            min-height: 70px;
            padding: 0 24px;
        }
        .brand { gap: 12px; color: #10233e; }
        .brand-mark {
            width: 40px;
            height: 40px;
            border: 1px solid rgba(255,255,255,.72);
            background: linear-gradient(145deg, #10233e, #285c68);
            box-shadow: inset 0 1px 0 rgba(255,255,255,.24), 0 8px 20px rgba(16,35,62,.16);
        }
        .brand-title { font-size: .98rem; }
        .page-shell {
            max-width: 1400px;
            padding: 28px 24px 48px;
        }
        .page-header {
            min-height: 54px;
            margin-bottom: 22px;
        }
        .page-heading { min-width: 0; }
        .page-title {
            color: #10233e;
            font-size: 1.7rem;
            line-height: 1.2;
        }
        .page-title::after, .theme-glass .page-title::after { display: none; }
        .service-state {
            display: inline-flex;
            align-items: center;
            gap: 7px;
            margin-bottom: 6px;
            color: #477177;
            font-size: .78rem;
            font-weight: 750;
            text-transform: uppercase;
        }
        .service-dot {
            width: 8px;
            height: 8px;
            border-radius: 50%;
            background: #18a46c;
            box-shadow: 0 0 0 4px rgba(24,164,108,.12);
        }
        .page-actions .btn, .topbar .btn {
            min-height: 38px;
            display: inline-flex;
            align-items: center;
            justify-content: center;
            padding: 7px 13px;
            background: rgba(255,255,255,.48);
            border-color: rgba(115,132,151,.26);
            box-shadow: inset 0 1px 0 rgba(255,255,255,.7);
        }
        .console-layout {
            display: grid;
            grid-template-columns: minmax(300px, 360px) minmax(0, 1fr);
            align-items: start;
            gap: 20px;
        }
        .control-column {
            min-width: 0;
            display: grid;
            gap: 20px;
        }
        .compose-panel {
            position: sticky;
            top: 92px;
            margin: 0;
        }
        .panel-card, .metric-strip, .login-card {
            border: 1px solid rgba(255,255,255,.72);
            background: rgba(250,252,253,.66);
            box-shadow: inset 0 1px 0 rgba(255,255,255,.9), 0 18px 44px rgba(34,55,78,.10);
            backdrop-filter: blur(24px) saturate(1.3);
        }
        .panel-card { margin: 0; }
        .panel-header {
            min-height: 56px;
            padding: 17px 20px;
            display: flex;
            align-items: center;
            justify-content: space-between;
            gap: 12px;
            color: #10233e;
            background: rgba(255,255,255,.28);
            border-bottom-color: rgba(115,132,151,.16);
            font-size: .98rem;
        }
        .panel-caption {
            color: #748293;
            font-size: .75rem;
            font-weight: 700;
        }
        .panel-body { padding: 20px; }
        .compose-form {
            display: grid;
            grid-template-columns: repeat(2, minmax(0, 1fr));
            gap: 15px 12px;
        }
        .form-field { min-width: 0; }
        .form-field-wide { grid-column: 1 / -1; }
        .form-label {
            color: #586a7d;
            font-size: .79rem;
            font-weight: 750;
        }
        .form-control, .form-select {
            min-height: 44px;
            border-color: rgba(115,132,151,.26);
            background: rgba(255,255,255,.58);
            box-shadow: inset 0 1px 0 rgba(255,255,255,.76);
        }
        .form-control:focus, .form-select:focus {
            border-color: #168798;
            box-shadow: 0 0 0 .2rem rgba(22,135,152,.12);
        }
        .submit-rule {
            min-height: 46px;
            margin-top: 3px;
            border-color: #176f7c;
            background: linear-gradient(135deg, #176f7c, #188b88);
            box-shadow: inset 0 1px 0 rgba(255,255,255,.24), 0 12px 24px rgba(23,111,124,.18);
        }
        .submit-rule:hover { border-color: #135f69; background: linear-gradient(135deg, #135f69, #147875); }
        .metric-strip {
            display: grid;
            grid-template-columns: 1.1fr 1.4fr 1fr 1fr;
            overflow: hidden;
            border-radius: 8px;
        }
        .metric-item {
            min-width: 0;
            padding: 18px 20px;
            border-left: 1px solid rgba(115,132,151,.14);
        }
        .metric-item:first-child { border-left: 0; }
        .metric-label {
            color: #6a798a;
            font-size: .75rem;
            text-transform: uppercase;
        }
        .metric-value {
            margin-top: 8px;
            color: #10233e;
            font-size: 1.55rem;
            line-height: 1.1;
        }
        .metric-protocol {
            display: inline-flex;
            align-items: baseline;
            gap: 8px;
        }
        .protocol-key { color: #168798; font-size: .72rem; font-weight: 800; }
        .protocol-key.udp-key { color: #7654b8; }
        .rule-count {
            display: inline-flex;
            align-items: center;
            justify-content: center;
            min-width: 28px;
            height: 26px;
            padding: 0 8px;
            border-radius: 6px;
            color: #176f7c;
            background: rgba(23,111,124,.09);
            font-size: .78rem;
        }
        .rules-table { table-layout: auto; }
        .rules-table thead th {
            padding: 12px 14px;
            color: #6a798a;
            background: rgba(234,240,244,.42);
            border-color: rgba(115,132,151,.14);
            font-size: .72rem;
        }
        .rules-table tbody td {
            padding: 15px 14px;
            border-color: rgba(115,132,151,.12);
        }
        .rules-table tbody tr:last-child td { border-bottom: 0; }
        .rules-table .badge {
            min-width: 44px;
            border: 1px solid rgba(255,255,255,.48);
            box-shadow: inset 0 1px 0 rgba(255,255,255,.22);
        }
        .badge-tcp { background: #2262b7; }
        .badge-udp { background: #7654b8; }
        .port-value { color: #10233e; font-size: 1rem; font-weight: 800; }
        .target-pill {
            border: 1px solid rgba(16,35,62,.08);
            background: #10233e;
            box-shadow: inset 0 1px 0 rgba(255,255,255,.13);
            font-size: .84rem;
        }
        .traffic-value { color: #2f5660; font-weight: 700; white-space: nowrap; }
        .expiry-value { color: #657386; font-size: .83rem; white-space: nowrap; }
        .delete-button {
            min-width: 52px;
            border-color: rgba(201,74,88,.34);
            color: #b53746;
            background: rgba(255,255,255,.42);
        }
        .delete-button:hover { color: #fff; background: #b53746; border-color: #b53746; }
        .alert { box-shadow: inset 0 1px 0 rgba(255,255,255,.66); }
        .login-card { padding: 30px; }
        .login-brand {
            width: 48px;
            height: 48px;
            margin: 0 auto 16px;
            display: grid;
            place-items: center;
            border-radius: 8px;
            color: #fff;
            background: linear-gradient(145deg, #10233e, #285c68);
            font-weight: 850;
            box-shadow: inset 0 1px 0 rgba(255,255,255,.22), 0 12px 24px rgba(16,35,62,.18);
        }
        .login-caption {
            margin: 7px 0 22px;
            color: #6a798a;
            text-align: center;
            font-size: .86rem;
        }
        .theme-glass {
            background:
                linear-gradient(118deg, transparent 0 12%, rgba(92,184,190,.18) 12% 21%, transparent 21% 58%, rgba(139,114,210,.12) 58% 69%, transparent 69%),
                linear-gradient(150deg, #dbeef1, #f4f7f8 46%, #e3eef0 74%, #eef0f7);
        }
        .theme-glass::before {
            inset: 0;
            transform: none;
            filter: none;
            opacity: .82;
            background:
                linear-gradient(105deg, transparent 0 28%, rgba(255,255,255,.54) 28% 36%, transparent 36% 72%, rgba(114,202,198,.12) 72% 80%, transparent 80%);
        }
        .theme-glass::after { opacity: .18; background-size: 92px 92px; }
        .theme-glass .topbar,
        .theme-glass .panel-card,
        .theme-glass .metric-strip,
        .theme-glass .login-card {
            background: linear-gradient(135deg, rgba(255,255,255,.70), rgba(255,255,255,.38));
            border-color: rgba(255,255,255,.74);
            box-shadow: inset 0 1px 0 rgba(255,255,255,.94), 0 18px 44px rgba(34,55,78,.11);
            backdrop-filter: blur(26px) saturate(1.4);
        }
        .theme-glass .metric-strip::before { display: none; }

        @media (max-width: 1040px) {
            .console-layout { grid-template-columns: 310px minmax(0, 1fr); }
            .metric-strip { grid-template-columns: repeat(2, minmax(0, 1fr)); }
            .metric-item:nth-child(3) { border-left: 0; }
            .metric-item:nth-child(n+3) { border-top: 1px solid rgba(115,132,151,.14); }
        }
        @media (max-width: 820px) {
            .topbar-inner { min-height: 62px; padding: 0 14px; }
            .brand-mark { width: 36px; height: 36px; }
            .brand-title { max-width: 52vw; }
            .page-shell { padding: 20px 14px 34px; }
            .page-header { align-items: center !important; flex-direction: row; }
            .page-actions { width: auto; }
            .page-actions .btn { flex: 0 0 auto; }
            .console-layout { grid-template-columns: 1fr; }
            .compose-panel { position: static; }
            .control-column { display: contents; }
            .metric-strip { grid-row: 1; }
            .compose-panel { grid-row: 2; }
            .rules-panel { grid-row: 3; }
            .rules-table thead { display: none; }
            .rules-table, .rules-table tbody, .rules-table tr, .rules-table td { display: block; width: 100%; }
            .rules-table tbody { padding: 10px; }
            .rules-table tbody tr {
                display: grid;
                grid-template-columns: repeat(2, minmax(0, 1fr));
                gap: 0;
                margin-bottom: 10px;
                overflow: hidden;
                border: 1px solid rgba(115,132,151,.16);
                border-radius: 8px;
                background: rgba(255,255,255,.28);
            }
            .rules-table tbody tr:last-child { margin-bottom: 0; }
            .rules-table tbody td {
                min-width: 0;
                padding: 11px 12px;
                border: 0;
                border-bottom: 1px solid rgba(115,132,151,.10);
            }
            .rules-table tbody td::before {
                content: attr(data-label);
                display: block;
                margin-bottom: 5px;
                color: #738193;
                font-size: .68rem;
                font-weight: 750;
                text-transform: uppercase;
            }
            .rules-table .target-cell, .rules-table .remark-cell-mobile, .rules-table .action-cell { grid-column: 1 / -1; }
            .rules-table .action-cell { text-align: left !important; }
            .rules-table .action-cell form, .rules-table .delete-button { width: 100%; }
            .empty-row { grid-column: 1 / -1 !important; }
            .empty-row::before { display: none !important; }
        }
        @media (max-width: 460px) {
            .page-title { font-size: 1.4rem; }
            .service-state { margin-bottom: 4px; }
            .page-header { align-items: flex-start !important; flex-direction: column; }
            .page-actions { width: 100%; }
            .page-actions .btn { width: 100%; min-width: 58px; padding-inline: 10px; }
            .metric-item { padding: 15px 14px; }
            .metric-value { font-size: 1.3rem; }
            .compose-form { grid-template-columns: 1fr; }
            .form-field-wide { grid-column: auto; }
        }
    </style>
</head>
<body class="theme-{{ theme }}">
    <div class="topbar">
        <div class="topbar-inner">
            <div class="brand">
                <span class="brand-mark">IP</span>
                <span class="brand-title">{{ t.panel_title }}</span>
            </div>
            <a href="/lang/{{ t.switch_to }}" class="btn btn-sm btn-outline-secondary">{{ t.lang_btn }}</a>
        </div>
    </div>
"""

LOGIN_HTML = HEADER_HTML + """
<main class="login-shell">
    <div class="login-card">
        <div class="login-brand">IP</div>
        <h1 class="login-title">{{ t.login_title }}</h1>
        <p class="login-caption">{{ t.panel_title }}</p>
        {% if error %}<div class="alert alert-danger py-2 text-center">{{ error }}</div>{% endif %}
        <form method="POST" action="/login">
            <div class="mb-3"><label class="form-label">{{ t.username }}</label><input type="text" class="form-control" name="username" autocomplete="username" required></div>
            <div class="mb-4"><label class="form-label">{{ t.password }}</label><input type="password" class="form-control" name="password" autocomplete="current-password" required></div>
            <button type="submit" class="btn btn-primary w-100">{{ t.login_btn }}</button>
        </form>
    </div>
</main></body></html>
"""

DASHBOARD_HTML = HEADER_HTML + """
<main class="page-shell">
    <div class="page-header d-flex align-items-center justify-content-between">
        <div class="page-heading">
            <div class="service-state"><span class="service-dot"></span>{{ t.status_online }}</div>
            <h1 class="page-title">{{ t.panel_title }}</h1>
        </div>
        <div class="page-actions">
            <a href="/logout" class="btn btn-outline-danger">{{ t.logout }}</a>
        </div>
    </div>
    {% if message %}<div class="alert alert-{{ status }}">{{ message }}</div>{% endif %}

    <div class="console-layout">
        <aside class="panel-card compose-panel">
            <div class="panel-header">
                <span>{{ t.add_rule }}</span>
                <span class="panel-caption">DNAT</span>
            </div>
            <div class="panel-body">
                <form method="POST" action="/add" class="compose-form">
                    <div class="form-field form-field-wide"><label class="form-label">{{ t.protocol }}</label>
                    <select class="form-select" name="protocol">
                        <option value="tcp">{{ t.tcp_only }}</option>
                        <option value="udp" selected>{{ t.udp_only }}</option>
                        <option value="all">{{ t.dual_stack }}</option>
                    </select>
                    </div>
                    <div class="form-field"><label class="form-label">{{ t.local_port }}</label><input type="number" min="1" max="65535" class="form-control" name="local_port" required></div>
                    <div class="form-field"><label class="form-label">{{ t.target_port }}</label><input type="number" min="1" max="65535" class="form-control" name="target_port" required></div>
                    <div class="form-field form-field-wide"><label class="form-label">{{ t.target_ip }}</label><input type="text" class="form-control" name="target_ip" required></div>
                    <div class="form-field form-field-wide"><label class="form-label">{{ t.remark }}</label><input type="text" class="form-control" name="remark" placeholder="{{ t.remark_ph }}"></div>
                    <div class="form-field"><label class="form-label">{{ t.quota }}</label><input type="number" min="1" step="1" class="form-control" name="quota_mb" placeholder="MB"></div>
                    <div class="form-field"><label class="form-label">{{ t.expires_at }}</label><input type="datetime-local" class="form-control" name="expires_at" title="{{ t.expires_ph }}"></div>
                    <div class="form-field form-field-wide"><button type="submit" class="btn btn-primary submit-rule w-100">{{ t.add_btn }}</button></div>
                </form>
            </div>
        </aside>

        <div class="control-column">
            <section class="metric-strip" aria-label="{{ t.overview }}">
                <div class="metric-item"><div class="metric-label">{{ t.total_rules }}</div><div class="metric-value">{{ rules|length }}</div></div>
                <div class="metric-item"><div class="metric-label">{{ t.total_traffic }}</div><div class="metric-value">{{ total_traffic_text }}</div></div>
                <div class="metric-item"><div class="metric-label">{{ t.tcp_rules }}</div><div class="metric-value metric-protocol"><span class="protocol-key">TCP</span>{{ rules|selectattr('protocol', 'equalto', 'TCP')|list|length }}</div></div>
                <div class="metric-item"><div class="metric-label">{{ t.udp_rules }}</div><div class="metric-value metric-protocol"><span class="protocol-key udp-key">UDP</span>{{ rules|selectattr('protocol', 'equalto', 'UDP')|list|length }}</div></div>
            </section>

            <section class="panel-card rules-panel">
                <div class="panel-header"><span>{{ t.cur_rules }}</span><span class="rule-count">{{ rules|length }}</span></div>
                <div class="table-responsive p-0">
                    <table class="table rules-table">
                        <thead><tr><th>{{ t.proto }}</th><th>{{ t.local_port }}</th><th>{{ t.target_ip }} : {{ t.target_port }}</th><th>{{ t.remark }}</th><th>{{ t.traffic }}<br><small class="text-muted">{{ t.traffic_note }}</small></th><th>{{ t.expires_at }}</th><th class="text-end">{{ t.action }}</th></tr></thead>
                        <tbody>
                            {% for rule in rules %}
                            <tr>
                                <td data-label="{{ t.proto }}"><span class="badge {% if rule.protocol == 'TCP' %}badge-tcp{% else %}badge-udp{% endif %}">{{ rule.protocol }}</span></td>
                                <td data-label="{{ t.local_port }}"><span class="port-value">{{ rule.local_port }}</span></td>
                                <td class="target-cell" data-label="{{ t.target_ip }} : {{ t.target_port }}"><span class="target-pill">{{ rule.target_ip }} : {{ rule.target_port }}</span></td>
                                <td class="remark-cell-mobile" data-label="{{ t.remark }}"><div class="remark-cell" title="{{ rule.remark }}">{% if rule.remark %}{{ rule.remark }}{% else %}-{% endif %}</div></td>
                                <td data-label="{{ t.traffic }}"><span class="traffic-value">{{ rule.traffic_text }}</span></td>
                                <td data-label="{{ t.expires_at }}"><span class="expiry-value">{{ rule.expires_text }}</span></td>
                                <td class="text-end action-cell" data-label="{{ t.action }}">
                                    <form method="POST" action="/delete" style="display:inline;">
                                        <input type="hidden" name="protocol" value="{{ rule.protocol | lower }}">
                                        <input type="hidden" name="local_port" value="{{ rule.local_port }}">
                                        <input type="hidden" name="target_ip" value="{{ rule.target_ip }}">
                                        <input type="hidden" name="target_port" value="{{ rule.target_port }}">
                                        <input type="hidden" name="remark" value="{{ rule.remark }}">
                                        <button type="submit" class="btn btn-sm delete-button" onclick="return confirm('{{ t.confirm_del }}');">{{ t.delete }}</button>
                                    </form>
                                </td>
                            </tr>
                            {% else %}<tr><td colspan="7" class="text-center empty-row">{{ t.no_rules }}</td></tr>{% endfor %}
                        </tbody>
                    </table>
                </div>
            </section>
        </div>
    </div>
</main></body></html>
"""

def get_t(): return T[session.get('lang', 'zh')]

def load_quotas():
    try:
        with open(QUOTA_FILE, "r", encoding="utf-8") as quota_file:
            data = json.load(quota_file)
            return data if isinstance(data, dict) else {}
    except Exception:
        return {}

def save_quotas(quotas):
    tmp_path = QUOTA_FILE + ".tmp"
    with open(tmp_path, "w", encoding="utf-8") as quota_file:
        json.dump(quotas, quota_file, ensure_ascii=False, indent=2)
    os.replace(tmp_path, QUOTA_FILE)

def parse_quota_mb(value):
    value = (value or "").strip()
    if not value:
        return 0
    if not value.isdigit() or int(value) <= 0:
        return None
    return int(value) * 1024 * 1024

def parse_expires_at(value):
    value = (value or "").strip()
    if not value:
        return ""
    try:
        parsed = datetime.datetime.strptime(value, "%Y-%m-%dT%H:%M")
        return parsed.strftime("%Y-%m-%dT%H:%M")
    except ValueError:
        return None

def utc8_now():
    return datetime.datetime.utcnow() + datetime.timedelta(hours=8)

def limit_quota_bytes(limit):
    if isinstance(limit, dict):
        return int(limit.get("quota_bytes", 0) or 0)
    return int(limit or 0)

def limit_expires_at(limit):
    if isinstance(limit, dict):
        return str(limit.get("expires_at", "") or "")
    return ""

def format_expires(value):
    return value.replace("T", " ") + " UTC+8" if value else "不限"

def is_expired(value):
    if not value:
        return False
    try:
        return utc8_now() >= datetime.datetime.strptime(value, "%Y-%m-%dT%H:%M")
    except ValueError:
        return False

def format_bytes(value):
    value = int(value or 0)
    units = ("B", "KB", "MB", "GB", "TB")
    size = float(value)
    for unit in units:
        if size < 1024 or unit == units[-1]:
            return f"{size:.1f} {unit}" if unit != "B" else f"{int(size)} B"
        size /= 1024

def rule_track_id(protocol, local_port, target_ip, target_port, remark):
    raw = f"{protocol.lower()}|{local_port}|{target_ip}|{target_port}|{remark or ''}"
    return hashlib.sha1(raw.encode("utf-8")).hexdigest()[:16]

def tracking_comment(track_id):
    return TRACK_PREFIX + track_id

def get_tracking_bytes():
    usage = {}
    try:
        res = subprocess.run(['sudo', 'iptables-save', '-c'], capture_output=True, text=True)
        for line in res.stdout.splitlines():
            if '-A FORWARD' not in line or TRACK_PREFIX not in line:
                continue
            counter_m = re.match(r'\[(\d+):(\d+)\]\s+', line)
            comment_m = re.search(r'--comment\s+"?(' + re.escape(TRACK_PREFIX) + r'[a-f0-9]+)"?', line)
            if counter_m and comment_m:
                track_id = comment_m.group(1).replace(TRACK_PREFIX, "")
                usage[track_id] = usage.get(track_id, 0) + int(counter_m.group(2))
    except Exception as e:
        print(e)
    return usage

def add_tracking_rules(protocol, target_ip, target_port, track_id):
    comment = tracking_comment(track_id)
    subprocess.run(['sudo', 'iptables', '-A', 'FORWARD', '-p', protocol, '-d', target_ip, '--dport', target_port, '-m', 'comment', '--comment', comment, '-j', 'ACCEPT'], check=True)
    subprocess.run(['sudo', 'iptables', '-A', 'FORWARD', '-p', protocol, '-s', target_ip, '--sport', target_port, '-m', 'comment', '--comment', comment, '-j', 'ACCEPT'], check=True)

def delete_tracking_rules(protocol, target_ip, target_port, track_id):
    comment = tracking_comment(track_id)
    subprocess.run(['sudo', 'iptables', '-D', 'FORWARD', '-p', protocol, '-d', target_ip, '--dport', target_port, '-m', 'comment', '--comment', comment, '-j', 'ACCEPT'], check=False)
    subprocess.run(['sudo', 'iptables', '-D', 'FORWARD', '-p', protocol, '-s', target_ip, '--sport', target_port, '-m', 'comment', '--comment', comment, '-j', 'ACCEPT'], check=False)

def delete_forwarding_rule(protocol, local_port, target_ip, target_port, remark):
    cmd_pre = ['sudo', 'iptables', '-t', 'nat', '-D', 'PREROUTING', '-p', protocol, '--dport', local_port]
    if remark:
        cmd_pre.extend(['-m', 'comment', '--comment', remark])
    cmd_pre.extend(['-j', 'DNAT', '--to-destination', f'{target_ip}:{target_port}'])
    subprocess.run(cmd_pre, check=False)
    subprocess.run(['sudo', 'iptables', '-t', 'nat', '-D', 'POSTROUTING', '-p', protocol, '-d', target_ip, '--dport', target_port, '-j', 'MASQUERADE'], check=False)
    delete_tracking_rules(protocol, target_ip, target_port, rule_track_id(protocol, local_port, target_ip, target_port, remark))

def remove_quota(track_id):
    quotas = load_quotas()
    if track_id in quotas:
        quotas.pop(track_id, None)
        save_quotas(quotas)

def enforce_quotas_once():
    quotas = load_quotas()
    if not quotas:
        return
    changed = False
    for rule in get_parsed_rules():
        limit = quotas.get(rule['track_id'], 0)
        quota = limit_quota_bytes(limit)
        expires_at = limit_expires_at(limit)
        if (quota and rule['traffic_bytes'] >= quota) or is_expired(expires_at):
            delete_forwarding_rule(rule['protocol'].lower(), rule['local_port'], rule['target_ip'], rule['target_port'], rule['remark'])
            quotas.pop(rule['track_id'], None)
            changed = True
    if changed:
        save_quotas(quotas)

def quota_watcher():
    while True:
        try:
            enforce_quotas_once()
        except Exception as e:
            print(e)
        time.sleep(30)

def get_parsed_rules():
    rules_list = []
    traffic_bytes = get_tracking_bytes()
    quotas = load_quotas()
    try:
        res = subprocess.run(['sudo', 'iptables-save', '-t', 'nat'], capture_output=True, text=True)
        for line in res.stdout.split('\n'):
            if line.startswith('-A PREROUTING') and '-j DNAT' in line:
                proto_m = re.search(r'-p\s+(tcp|udp)', line)
                lport_m = re.search(r'--dport\s+(\d+)', line)
                target_m = re.search(r'--to-destination\s+([\d\.]+):(\d+)', line)
                remark_m = re.search(r'--comment\s+"([^"]+)"', line)
                
                if proto_m and lport_m and target_m:
                    protocol = proto_m.group(1)
                    local_port = lport_m.group(1)
                    target_ip = target_m.group(1)
                    target_port = target_m.group(2)
                    remark = remark_m.group(1) if remark_m else ''
                    track_id = rule_track_id(protocol, local_port, target_ip, target_port, remark)
                    used_bytes = traffic_bytes.get(track_id, 0)
                    limit = quotas.get(track_id, 0)
                    quota_bytes = limit_quota_bytes(limit)
                    expires_at = limit_expires_at(limit)
                    rules_list.append({
                        'protocol': protocol.upper(),
                        'local_port': local_port,
                        'target_ip': target_ip,
                        'target_port': target_port,
                        'remark': remark,
                        'track_id': track_id,
                        'traffic_bytes': used_bytes,
                        'quota_bytes': quota_bytes,
                        'expires_at': expires_at,
                        'traffic_text': f"{format_bytes(used_bytes)} / {format_bytes(quota_bytes) if quota_bytes else '不限'}",
                        'expires_text': format_expires(expires_at)
                    })
    except Exception as e: print(e)
    return rules_list

def valid_port(value):
    return value and value.isdigit() and 1 <= int(value) <= 65535

def rule_exists(protocol, local_port, target_ip, target_port):
    return any(
        rule['protocol'].lower() == protocol
        and rule['local_port'] == local_port
        and rule['target_ip'] == target_ip
        and rule['target_port'] == target_port
        for rule in get_parsed_rules()
    )

@app.route('/lang/<lang>')
def switch_lang(lang):
    if lang in ['zh', 'en']: session['lang'] = lang
    return redirect(request.referrer or url_for('login'))

@app.route('/login', methods=['GET', 'POST'])
def login():
    t = get_t()
    if request.method == 'POST':
        if request.form.get('username') == ADMIN_USER and request.form.get('password') == ADMIN_PASS:
            session['logged_in'] = True; return redirect(url_for('index'))
        return render_template_string(LOGIN_HTML, t=t, theme=PANEL_THEME, error=t['login_error'])
    return render_template_string(LOGIN_HTML, t=t, theme=PANEL_THEME)

@app.route('/logout')
def logout(): session.pop('logged_in', None); return redirect(url_for('login'))

@app.route('/', methods=['GET'])
def index():
    if not session.get('logged_in'): return redirect(url_for('login'))
    rules = get_parsed_rules()
    total_traffic_text = format_bytes(sum(rule.get('traffic_bytes', 0) for rule in rules))
    return render_template_string(DASHBOARD_HTML, t=get_t(), theme=PANEL_THEME, rules=rules, total_traffic_text=total_traffic_text, message=request.args.get('msg'), status=request.args.get('status', 'success'))

@app.route('/add', methods=['POST'])
def add_rule():
    if not session.get('logged_in'): return redirect(url_for('login'))
    t = get_t()
    p, l_port, t_input, t_port = request.form.get('protocol'), request.form.get('local_port'), request.form.get('target_ip', '').strip(), request.form.get('target_port')
    
    remark = request.form.get('remark', '').replace('"', '').replace("'", "").strip()
    quota_bytes = parse_quota_mb(request.form.get('quota_mb'))
    expires_at = parse_expires_at(request.form.get('expires_at'))

    if not valid_port(l_port) or not valid_port(t_port): return redirect(url_for('index', msg=t['err_port'], status="danger"))
    if quota_bytes is None: return redirect(url_for('index', msg=t['err_quota'], status="danger"))
    if expires_at is None: return redirect(url_for('index', msg=t['err_expires'], status="danger"))
    
    # --- 增加域名解析逻辑 ---
    try:
        t_ip = socket.gethostbyname(t_input)
    except Exception:
        return redirect(url_for('index', msg=t['err_ip'], status="danger"))
        
    # 如果用户输入的是域名，则在备注里附加上域名，以便记忆
    if t_ip != t_input:
        remark = f"{remark} [{t_input}]".strip()
    
    protos = ['tcp', 'udp'] if p == 'all' else [p]
    if any(rule_exists(proto, l_port, t_ip, t_port) for proto in protos):
        return redirect(url_for('index', msg=t['err_duplicate'], status="warning"))

    try:
        quotas = load_quotas()
        for proto in protos:
            cmd_pre = ['sudo', 'iptables', '-t', 'nat', '-A', 'PREROUTING', '-p', proto, '--dport', l_port]
            if remark: cmd_pre.extend(['-m', 'comment', '--comment', remark])
            cmd_pre.extend(['-j', 'DNAT', '--to-destination', f'{t_ip}:{t_port}'])
            subprocess.run(cmd_pre, check=True)
            
            subprocess.run(['sudo', 'iptables', '-t', 'nat', '-A', 'POSTROUTING', '-p', proto, '-d', t_ip, '--dport', t_port, '-j', 'MASQUERADE'], check=True)
            track_id = rule_track_id(proto, l_port, t_ip, t_port, remark)
            add_tracking_rules(proto, t_ip, t_port, track_id)
            if quota_bytes or expires_at:
                quotas[track_id] = {
                    "quota_bytes": quota_bytes,
                    "expires_at": expires_at,
                }
        save_quotas(quotas)
        return redirect(url_for('index', msg=t['add_success'], status="success"))
    except Exception as e: return redirect(url_for('index', msg=f"Failed: {e}", status="danger"))

@app.route('/delete', methods=['POST'])
def delete_rule():
    if not session.get('logged_in'): return redirect(url_for('login'))
    t = get_t()
    p, l_port, t_ip, t_port, remark = request.form.get('protocol'), request.form.get('local_port'), request.form.get('target_ip'), request.form.get('target_port'), request.form.get('remark', '')
    try:
        track_id = rule_track_id(p, l_port, t_ip, t_port, remark)
        delete_forwarding_rule(p, l_port, t_ip, t_port, remark)
        remove_quota(track_id)
        return redirect(url_for('index', msg=t['del_success'], status="warning"))
    except Exception as e: return redirect(url_for('index', msg=f"Failed: {e}", status="danger"))

if __name__ == '__main__':
    subprocess.run(['sudo', 'sysctl', '-w', 'net.ipv4.ip_forward=1'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    threading.Thread(target=quota_watcher, daemon=True).start()
    app.run(host='0.0.0.0', port=PANEL_PORT)
EOF

echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p > /dev/null 2>&1

echo "⚙️ 正在配置系统服务..."
cat << EOF > /etc/systemd/system/iptables-panel.service
[Unit]
Description=Iptables Forwarding Web Panel
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=/usr/bin/python3 $INSTALL_DIR/panel.py --port $PANEL_PORT --user $PANEL_USER --password $PANEL_PASS --theme $PANEL_THEME
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable iptables-panel > /dev/null 2>&1
systemctl restart iptables-panel

echo "UI theme: $PANEL_THEME"
echo "====================================================="
echo "✅ 安装/更新成功！面板已在后台运行并设置开机自启。"
echo "🌐 访问地址: http://你的服务器IP:$PANEL_PORT"
echo "👤 登录账号: $PANEL_USER"
echo "🔑 登录密码: $PANEL_PASS"
echo "====================================================="
