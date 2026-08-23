#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
  echo "❌ 请使用 root 权限运行此脚本 (例如: sudo bash install-v2.sh)"
  exit 1
fi

INSTALL_DIR="/opt/iptables-panel"
SERVICE_FILE="/etc/systemd/system/iptables-panel.service"
PANEL_BINARY="$INSTALL_DIR/panel"
CONFIG_DIR="/etc/iptables-panel"
CONFIG_FILE="$CONFIG_DIR/panel.env"
TEMP_SWAP_FILE=""

cleanup_temp_swap() {
  if [ -n "$TEMP_SWAP_FILE" ]; then
    swapoff "$TEMP_SWAP_FILE" > /dev/null 2>&1 || true
    rm -f "$TEMP_SWAP_FILE"
    TEMP_SWAP_FILE=""
  fi
}
trap cleanup_temp_swap EXIT

prepare_rust_build_memory() {
  [ "$PANEL_RUNTIME" = "rust" ] || return 0
  local available_kb swap_kb candidate
  available_kb=$(awk '/MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
  swap_kb=$(awk '/SwapTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
  if [ "${available_kb:-0}" -ge 393216 ] || [ "${swap_kb:-0}" -gt 0 ]; then
    return 0
  fi

  candidate=$(mktemp /var/tmp/iptables-panel-build.XXXXXX.swap 2>/dev/null || true)
  if [ -z "$candidate" ]; then
    echo "⚠️  可用内存较低，且无法创建临时交换文件；Rust 编译可能失败。"
    return 0
  fi
  chmod 600 "$candidate"
  if dd if=/dev/zero of="$candidate" bs=1M count=512 status=none 2>/dev/null \
    && mkswap "$candidate" > /dev/null 2>&1 \
    && swapon "$candidate" > /dev/null 2>&1; then
    TEMP_SWAP_FILE="$candidate"
    echo "已启用 512 MB 临时编译交换空间，安装结束后会自动删除。"
  else
    rm -f "$candidate"
    echo "⚠️  系统不允许启用临时交换空间；Rust 编译将在现有内存下继续。"
  fi
}

hex_encode() {
  printf '%s' "$1" | od -An -tx1 | tr -d ' \n'
}

hex_decode() {
  local escaped
  escaped=$(printf '%s' "$1" | sed 's/../\\x&/g')
  printf '%b' "$escaped"
}

config_value() {
  [ -f "$CONFIG_FILE" ] || return 0
  sed -n "s/^$1=//p" "$CONFIG_FILE" | tail -n 1
}

load_existing_settings() {
  EXISTING_CHANNEL=""
  EXISTING_RUNTIME=""
  EXISTING_BACKEND=""
  EXISTING_PORT="5000"
  EXISTING_USER="admin"
  EXISTING_PASSWORD=""

  if [ -f "$CONFIG_FILE" ]; then
    EXISTING_CHANNEL=$(config_value PANEL_CHANNEL)
    EXISTING_RUNTIME=$(config_value PANEL_RUNTIME)
    EXISTING_BACKEND=$(config_value PANEL_BACKEND)
    EXISTING_PORT=$(config_value PANEL_PORT)
    local user_hex password_hex
    user_hex=$(config_value PANEL_USER_HEX)
    password_hex=$(config_value PANEL_PASSWORD_HEX)
    [ -n "$user_hex" ] && EXISTING_USER=$(hex_decode "$user_hex")
    [ -n "$password_hex" ] && EXISTING_PASSWORD=$(hex_decode "$password_hex")
    [ -n "$EXISTING_PORT" ] || EXISTING_PORT="5000"
    return
  fi

  if [ -f "$SERVICE_FILE" ]; then
    local current_exec
    current_exec=$(sed -n 's/^ExecStart=//p' "$SERVICE_FILE" | head -n 1)
    if printf '%s' "$current_exec" | grep -q -- '--backend'; then EXISTING_CHANNEL="experimental"; else EXISTING_CHANNEL="stable"; fi
    if printf '%s' "$current_exec" | grep -q '/panel.py'; then EXISTING_RUNTIME="python"; else EXISTING_RUNTIME="rust"; fi
    if printf '%s' "$current_exec" | grep -q -- '--backend nftables'; then EXISTING_BACKEND="nftables"; else EXISTING_BACKEND="iptables"; fi
    EXISTING_PORT=$(printf '%s\n' "$current_exec" | sed -n 's/.*--port \([^ ]*\).*/\1/p')
    EXISTING_USER=$(printf '%s\n' "$current_exec" | sed -n 's/.*--user \([^ ]*\).*/\1/p')
    EXISTING_PASSWORD=$(printf '%s\n' "$current_exec" | sed -n 's/.*--password \([^ ]*\).*/\1/p')
    [ -n "$EXISTING_PORT" ] || EXISTING_PORT="5000"
    [ -n "$EXISTING_USER" ] || EXISTING_USER="admin"
  fi
}

load_existing_settings
DEFAULT_INSTALL_MODE="1"
case "$EXISTING_RUNTIME/$EXISTING_BACKEND" in
  python/nftables) DEFAULT_INSTALL_MODE="2" ;;
  rust/iptables) DEFAULT_INSTALL_MODE="3" ;;
  rust/nftables) DEFAULT_INSTALL_MODE="4" ;;
esac

echo "====================================================="
echo "   🚀 Iptables/Nftables 多后端流量中转面板安装器"
echo "====================================================="
echo "可选组合:"
echo "1) Python + iptables"
echo "2) Python + nftables"
echo "3) Rust + iptables"
echo "4) Rust + nftables"
echo ""
read -p "请选择安装组合 [默认: $DEFAULT_INSTALL_MODE]: " INSTALL_MODE
INSTALL_MODE=${INSTALL_MODE:-$DEFAULT_INSTALL_MODE}

case "$INSTALL_MODE" in
  2) PANEL_RUNTIME="python"; FIREWALL_BACKEND="nftables" ;;
  3) PANEL_RUNTIME="rust"; FIREWALL_BACKEND="iptables" ;;
  4) PANEL_RUNTIME="rust"; FIREWALL_BACKEND="nftables" ;;
  *) PANEL_RUNTIME="python"; FIREWALL_BACKEND="iptables" ;;
esac

confirm_install_transition() {
  if [ ! -f "$SERVICE_FILE" ]; then
    return
  fi

  local current_exec current_channel current_runtime current_backend
  current_exec=$(sed -n 's/^ExecStart=//p' "$SERVICE_FILE" | head -n 1)
  [ -z "$current_exec" ] && [ ! -f "$CONFIG_FILE" ] && return

  if [ -n "$EXISTING_CHANNEL" ]; then
    current_channel="$EXISTING_CHANNEL"
  elif printf '%s' "$current_exec" | grep -q -- '--backend'; then
    current_channel="experimental"
  else
    current_channel="stable"
  fi

  if [ -n "$EXISTING_RUNTIME" ]; then
    current_runtime="$EXISTING_RUNTIME"
  elif printf '%s' "$current_exec" | grep -q '/panel.py'; then
    current_runtime="python"
  else
    current_runtime="rust"
  fi

  if [ -n "$EXISTING_BACKEND" ]; then
    current_backend="$EXISTING_BACKEND"
  elif printf '%s' "$current_exec" | grep -q -- '--backend nftables'; then
    current_backend="nftables"
  else
    current_backend="iptables"
  fi

  echo ""
  echo "检测到当前面板: $current_channel / $current_runtime + $current_backend"

  if [ "$current_backend" != "$FIREWALL_BACKEND" ]; then
    echo "⚠️  即将把防火墙后端从 $current_backend 切换为 $FIREWALL_BACKEND。"
    echo "⚠️  旧后端的规则会继续保留在内核中，但不会显示在新后端面板里。"
    echo "⚠️  本安装器不会自动迁移或删除这些规则。"
    read -r -p "确认切换后端请输入 SWITCH: " BACKEND_SWITCH_CONFIRM
    if [ "$BACKEND_SWITCH_CONFIRM" != "SWITCH" ]; then
      echo "已取消安装。"
      exit 0
    fi
  elif [ "$current_channel" = "stable" ] && [ "${PANEL_CHANNEL_SWITCH_CONFIRMED:-0}" != "1" ]; then
    echo "⚠️  即将从稳定版切换到实验版。转发规则会保留，但配额和到期时间元数据不会自动迁移。"
    read -r -p "确认切换版本请输入 SWITCH: " CHANNEL_SWITCH_CONFIRM
    if [ "$CHANNEL_SWITCH_CONFIRM" != "SWITCH" ]; then
      echo "已取消安装。"
      exit 0
    fi
  elif [ "$current_runtime" != "$PANEL_RUNTIME" ]; then
    echo "运行时将从 $current_runtime 切换为 $PANEL_RUNTIME；防火墙规则保持不变。"
  else
    echo "将升级当前实验版组合，现有转发规则保持不变。"
  fi
}

confirm_install_transition

read -p "👉 请设置面板运行端口 [默认: $EXISTING_PORT]: " PANEL_PORT
PANEL_PORT=${PANEL_PORT:-$EXISTING_PORT}

read -p "👉 请设置管理员用户名 [默认: $EXISTING_USER]: " PANEL_USER
PANEL_USER=${PANEL_USER:-$EXISTING_USER}

if [ -n "$EXISTING_PASSWORD" ]; then
  read -r -s -p "👉 请设置管理员密码 [回车保留原密码]: " PANEL_PASS
  echo ""
  PANEL_PASS=${PANEL_PASS:-$EXISTING_PASSWORD}
else
  GENERATED_PASSWORD=$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')
  read -r -s -p "👉 请设置管理员密码 [回车使用随机密码]: " PANEL_PASS
  echo ""
  PANEL_PASS=${PANEL_PASS:-$GENERATED_PASSWORD}
fi

PANEL_THEME="glass"

echo ""
echo "将安装: $PANEL_RUNTIME + $FIREWALL_BACKEND"
echo "升级说明: 重新运行本脚本会覆盖面板程序和 systemd 服务，不会主动清空已有转发规则。"
echo ""

install_common_deps() {
  apt-get update -y > /dev/null 2>&1
  apt-get install -y curl ca-certificates > /dev/null 2>&1

  if [ "$FIREWALL_BACKEND" = "nftables" ]; then
    apt-get install -y nftables > /dev/null 2>&1
  else
    apt-get install -y iptables > /dev/null 2>&1
  fi

  if [ "$PANEL_RUNTIME" = "python" ]; then
    apt-get install -y python3 python3-pip > /dev/null 2>&1
    pip3 install flask gunicorn --break-system-packages > /dev/null 2>&1 || pip3 install flask gunicorn > /dev/null 2>&1
  else
    apt-get install -y rustc > /dev/null 2>&1
  fi
}

write_python_panel() {
  cat << 'PYEOF' > "$INSTALL_DIR/panel.py.new"
import argparse
import datetime
import functools
import hashlib
import html
import ipaddress
import os
import re
import socket
import subprocess
import threading
import time
from flask import Flask, redirect, render_template_string, request, session, url_for

def decode_env_hex(name, fallback):
    value = os.environ.get(name, "")
    if not value:
        return fallback
    try:
        return bytes.fromhex(value).decode("utf-8")
    except (ValueError, UnicodeDecodeError):
        return fallback

parser = argparse.ArgumentParser()
parser.add_argument("--port", type=int, default=int(os.environ.get("PANEL_PORT", "5000")))
parser.add_argument("--user", default=decode_env_hex("PANEL_USER_HEX", "admin"))
parser.add_argument("--password", default=decode_env_hex("PANEL_PASSWORD_HEX", "123456"))
parser.add_argument("--backend", choices=("iptables", "nftables"), default=os.environ.get("PANEL_BACKEND", "iptables"))
parser.add_argument("--theme", default=os.environ.get("PANEL_THEME", "glass"))
args, _unknown_args = parser.parse_known_args()
PANEL_THEME = "glass"

app = Flask(__name__)
app.secret_key = os.urandom(24)
MARK = "iptables-panel"
LIMIT_FILE = "/opt/iptables-panel/limits.tsv"
TRACK_PREFIX = "iptables-panel-track:"
RULE_LOCK = threading.RLock()

def serialized_rule_change(func):
    @functools.wraps(func)
    def wrapped(*args, **kwargs):
        with RULE_LOCK:
            return func(*args, **kwargs)
    return wrapped

CSS = """
<style>
*{box-sizing:border-box}body{min-height:100vh;margin:0;color:#10233e;background:linear-gradient(118deg,transparent 0 14%,rgba(98,185,194,.1) 14% 23%,transparent 23% 62%,rgba(123,104,238,.08) 62% 72%,transparent 72%),#eaf0f4;font-family:Inter,system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;letter-spacing:0}
.top{position:sticky;top:0;z-index:20;min-height:70px;padding:0 24px;display:flex;align-items:center;justify-content:space-between;gap:16px;border-bottom:1px solid rgba(115,132,151,.22);background:rgba(242,247,250,.78);box-shadow:0 8px 28px rgba(28,45,66,.06);backdrop-filter:blur(22px) saturate(1.35)}
.brand{display:flex;align-items:center;gap:12px;min-width:0;font-weight:800}.brand-mark{width:40px;height:40px;display:grid;place-items:center;flex:0 0 auto;border:1px solid rgba(255,255,255,.72);border-radius:8px;color:#fff;background:linear-gradient(145deg,#10233e,#285c68);box-shadow:inset 0 1px 0 rgba(255,255,255,.24),0 8px 20px rgba(16,35,62,.16)}.brand-name{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.backend{color:#637486;font-size:.78rem;font-weight:700;text-transform:uppercase}
.top-actions{display:flex;align-items:center;gap:12px}.state{display:inline-flex;align-items:center;gap:7px;color:#477177;font-size:.76rem;font-weight:750}.state-dot{width:8px;height:8px;border-radius:50%;background:#18a46c;box-shadow:0 0 0 4px rgba(24,164,108,.12)}
.wrap{position:relative;z-index:1;max-width:1400px;margin:0 auto;padding:28px 24px 48px}.page-head{margin-bottom:22px}.page-head h1{margin:0;font-size:1.7rem;line-height:1.2}.page-head p{margin:6px 0 0;color:#6a798a;font-size:.84rem}
.console{display:grid;grid-template-columns:minmax(300px,360px) minmax(0,1fr);align-items:start;gap:20px}.control{min-width:0;display:grid;gap:20px}.card,.metrics,.login-card{overflow:hidden;border:1px solid rgba(255,255,255,.74);border-radius:8px;background:linear-gradient(135deg,rgba(255,255,255,.7),rgba(255,255,255,.38));box-shadow:inset 0 1px 0 rgba(255,255,255,.94),0 18px 44px rgba(34,55,78,.11);backdrop-filter:blur(26px) saturate(1.4)}
.compose{position:sticky;top:92px}.head{min-height:56px;padding:17px 20px;display:flex;align-items:center;justify-content:space-between;gap:12px;border-bottom:1px solid rgba(115,132,151,.16);background:rgba(255,255,255,.28);font-weight:800}.caption{color:#748293;font-size:.75rem}.body{padding:20px}.grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:15px 12px}.wide{grid-column:1/-1}
label{display:block;margin-bottom:6px;color:#586a7d;font-size:.79rem;font-weight:750}input,select{width:100%;min-height:44px;padding:8px 10px;border:1px solid rgba(115,132,151,.26);border-radius:8px;color:#10233e;background:rgba(255,255,255,.58);box-shadow:inset 0 1px 0 rgba(255,255,255,.76);font:inherit}input:focus,select:focus{outline:0;border-color:#168798;box-shadow:0 0 0 3px rgba(22,135,152,.12)}
button,.btn{min-height:38px;padding:8px 13px;border:1px solid transparent;border-radius:8px;font:inherit;font-weight:750;text-decoration:none;cursor:pointer}.primary{width:100%;min-height:46px;color:#fff;border-color:#176f7c;background:linear-gradient(135deg,#176f7c,#188b88);box-shadow:inset 0 1px 0 rgba(255,255,255,.24),0 12px 24px rgba(23,111,124,.18)}.ghost{color:#10233e;border-color:rgba(115,132,151,.26);background:rgba(255,255,255,.48)}.danger{color:#b53746;border-color:rgba(201,74,88,.34);background:rgba(255,255,255,.42)}.danger:hover{color:#fff;background:#b53746}
.metrics{display:grid;grid-template-columns:1.1fr 1.4fr 1fr 1fr}.metric{min-width:0;padding:18px 20px;border-left:1px solid rgba(115,132,151,.14)}.metric:first-child{border-left:0}.muted{color:#6a798a}.metric .muted{font-size:.75rem;font-weight:700;text-transform:uppercase}.num{margin-top:8px;font-size:1.55rem;line-height:1.1;font-weight:850}.proto-key{margin-right:8px;color:#168798;font-size:.72rem}.proto-key.udp{color:#7654b8}.rule-count{min-width:28px;height:26px;padding:0 8px;display:inline-grid;place-items:center;border-radius:6px;color:#176f7c;background:rgba(23,111,124,.09);font-size:.78rem}
.table-wrap{overflow:auto}table{width:100%;border-collapse:collapse}th,td{padding:14px;border-bottom:1px solid rgba(115,132,151,.12);text-align:left}th{color:#6a798a;background:rgba(234,240,244,.42);font-size:.72rem;text-transform:uppercase;white-space:nowrap}tr:last-child td{border-bottom:0}.pill{display:inline-block;padding:5px 8px;border-radius:6px;color:#fff;background:#10233e;font-size:.84rem;font-weight:750;white-space:nowrap}.tcp{min-width:44px;text-align:center;background:#2262b7}.udp{min-width:44px;text-align:center;background:#7654b8}.port{font-weight:850;overflow-wrap:anywhere}.traffic{color:#2f5660;font-weight:700;white-space:nowrap}.expiry{color:#657386;font-size:.83rem;white-space:nowrap}.action{text-align:right}.msg{margin-bottom:18px;padding:12px 14px;border:1px solid rgba(22,135,152,.18);border-radius:8px;color:#176f7c;background:rgba(255,255,255,.48);font-weight:700}
.login{position:relative;z-index:1;min-height:calc(100vh - 70px);display:grid;place-items:center;padding:20px}.login-card{width:min(100%,420px);padding:30px}.login-mark{width:48px;height:48px;margin:0 auto 16px;display:grid;place-items:center;border-radius:8px;color:#fff;background:linear-gradient(145deg,#10233e,#285c68);font-weight:850}.login-card h2{margin:0;text-align:center}.login-card p{margin:7px 0 22px;color:#6a798a;text-align:center;font-size:.86rem}
.theme-glass{position:relative;overflow-x:hidden;background:linear-gradient(118deg,transparent 0 12%,rgba(92,184,190,.18) 12% 21%,transparent 21% 58%,rgba(139,114,210,.12) 58% 69%,transparent 69%),linear-gradient(150deg,#dbeef1,#f4f7f8 46%,#e3eef0 74%,#eef0f7)}.theme-glass:before{content:"";position:fixed;inset:0;pointer-events:none;background:linear-gradient(105deg,transparent 0 28%,rgba(255,255,255,.54) 28% 36%,transparent 36% 72%,rgba(114,202,198,.12) 72% 80%,transparent 80%)}
@media(max-width:1040px){.console{grid-template-columns:310px minmax(0,1fr)}.metrics{grid-template-columns:repeat(2,minmax(0,1fr))}.metric:nth-child(3){border-left:0}.metric:nth-child(n+3){border-top:1px solid rgba(115,132,151,.14)}}
@media(max-width:820px){.top{min-height:62px;padding:0 14px}.brand-mark{width:36px;height:36px}.brand-name{max-width:46vw}.state{display:none}.wrap{padding:20px 14px 34px}.console{grid-template-columns:1fr}.control{grid-row:1}.compose{position:static;grid-row:2}.rules{order:2}thead{display:none}table,tbody,tr,td{display:block;width:100%}tbody{padding:10px}tbody tr{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));margin-bottom:10px;overflow:hidden;border:1px solid rgba(115,132,151,.16);border-radius:8px;background:rgba(255,255,255,.28)}tbody tr:last-child{margin-bottom:0}tbody td{min-width:0;padding:11px 12px;border:0;border-bottom:1px solid rgba(115,132,151,.1)}tbody td:before{content:attr(data-label);display:block;margin-bottom:5px;color:#738193;font-size:.68rem;font-weight:750;text-transform:uppercase}.full,.action{grid-column:1/-1}.action{text-align:left}.action form,.action button{width:100%}.empty{grid-column:1/-1}.empty:before{display:none}}
@media(max-width:460px){.page-head h1{font-size:1.4rem}.metric{padding:15px 14px}.num{font-size:1.3rem}.grid{grid-template-columns:1fr}.wide{grid-column:auto}}
</style>
<style>@media(max-width:820px){.backend{display:none}.control{display:contents}.metrics{grid-row:1}.compose{grid-row:2}.rules{grid-row:3}}</style>
"""

CSS += """
<style>
:root{--ink:#18201f;--muted:#65716f;--line:rgba(58,75,72,.16);--teal:#087f75;--teal-dark:#08645e;--violet:#6d4bc3;--red:#c63f4e}
body.theme-glass{color:var(--ink);background:linear-gradient(122deg,transparent 0 18%,rgba(66,170,161,.11) 18% 31%,transparent 31% 67%,rgba(109,75,195,.08) 67% 77%,transparent 77%),#edf2f1}
.theme-glass:before{background:linear-gradient(110deg,transparent 0 29%,rgba(255,255,255,.64) 29% 40%,transparent 40% 73%,rgba(107,205,197,.12) 73% 83%,transparent 83%);opacity:.78}
.theme-glass .top{position:sticky;top:0;min-height:62px;color:#f7fbfa;border-bottom-color:rgba(255,255,255,.1);background:rgba(24,32,31,.92);box-shadow:0 8px 26px rgba(25,36,34,.12);backdrop-filter:blur(20px) saturate(1.25)}
.brand-mark{width:36px;height:36px;background:var(--teal)}.backend{color:#b9cbc8}.state{color:#bde6df}.ghost{color:#f7fbfa;border-color:rgba(255,255,255,.25);background:rgba(255,255,255,.06)}
.wrap{max-width:1460px;padding:28px 24px 48px}.page-head{margin-bottom:20px}.page-head h1{color:var(--ink);font-size:1.65rem}.runtime-line{display:flex;align-items:center;gap:8px;margin-top:9px;flex-wrap:wrap}.runtime-chip{min-height:26px;padding:4px 8px;border:1px solid var(--line);border-radius:6px;color:#485654;background:rgba(255,255,255,.46);font-size:.74rem;font-weight:750}
.console{grid-template-columns:minmax(0,1fr);gap:16px}.compose{position:static}.control{display:grid;gap:16px}.card,.metrics,.login-card{border-color:rgba(255,255,255,.72);background:rgba(255,255,255,.64);box-shadow:inset 0 1px 0 rgba(255,255,255,.88),0 12px 34px rgba(35,52,49,.09);backdrop-filter:blur(24px) saturate(1.25)}
.head{min-height:58px;padding:14px 18px;border-bottom-color:var(--line)}.head-group{display:flex;align-items:baseline;gap:10px;min-width:0}.route-path{color:var(--muted);font-size:.75rem;font-weight:650}.body{padding:16px 18px 18px}
.grid{grid-template-columns:.9fr .65fr 1.35fr 1.35fr .65fr .9fr .7fr 1.1fr .95fr;align-items:end;gap:12px}.grid>div,.wide{min-width:0;grid-column:auto}.grid label{color:#53615f;font-size:.78rem}input,select{border-color:rgba(58,75,72,.2);color:var(--ink);background:rgba(255,255,255,.66)}input:focus,select:focus{border-color:var(--teal);box-shadow:0 0 0 3px rgba(8,127,117,.12)}.primary{min-height:44px;border-color:var(--teal);background:var(--teal);box-shadow:none}.primary:hover{background:var(--teal-dark)}
.metrics{grid-template-columns:1fr 1.25fr 1fr 1fr}.metric{padding:15px 18px;border-left-color:var(--line)}.metric .muted{color:var(--muted);font-size:.72rem}.num{margin-top:5px;color:var(--ink);font-size:1.35rem}.proto-key{color:var(--teal)}.proto-key.udp{color:var(--violet)}
th{padding:11px 14px;color:var(--muted);background:rgba(226,234,232,.42)}td{padding:13px 14px;border-bottom-color:rgba(58,75,72,.1)}.pill{background:#24312f}.tcp{background:var(--teal)}.udp{background:var(--violet)}.danger{color:var(--red);border-color:rgba(198,63,78,.3)}.danger:hover{background:var(--red)}
.quota-track{width:min(150px,100%);height:4px;margin-top:7px;overflow:hidden;border-radius:4px;background:rgba(58,75,72,.12)}.quota-fill{height:100%;border-radius:inherit;background:var(--teal)}
@media(max-width:1260px){.grid{grid-template-columns:repeat(4,minmax(0,1fr))}.field-relay,.field-target,.field-remark,.field-submit{grid-column:span 2}}
@media(max-width:820px){.wrap{padding-left:14px;padding-right:14px}.page-head h1{font-size:1.48rem}.console{display:grid}.control{display:grid;grid-row:auto}.compose,.metrics,.rules{grid-row:auto}.grid{grid-template-columns:repeat(2,minmax(0,1fr))}.field-relay,.field-target,.field-remark,.field-submit{grid-column:span 2}}
@media(max-width:500px){.page-head h1{font-size:1.38rem}.metrics{grid-template-columns:repeat(2,minmax(0,1fr))}.metric:nth-child(3){border-left:0}.grid{grid-template-columns:1fr}.field-relay,.field-target,.field-remark,.field-submit{grid-column:auto}.route-path{display:none}}
</style>
"""

LOGIN = """
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Panel Login</title>""" + CSS + """</head>
<body class="theme-glass"><div class="top"><div class="brand"><span class="brand-mark">IP</span><span class="brand-name">流量中转管理面板</span></div></div><main class="login"><div class="login-card">
<div class="login-mark">IP</div><h2>中转面板登录</h2><p>流量中转管理面板</p>{% if error %}<div class="msg">{{ error }}</div>{% endif %}
<form method="post" action="/login"><label>用户名</label><input name="username" autocomplete="username" required>
<label style="margin-top:12px">密码</label><input name="password" type="password" autocomplete="current-password" required>
<button class="primary" style="width:100%;margin-top:18px">登录</button></form></div></main></body></html>
"""

PAGE = """
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Forward Panel</title>""" + CSS + """</head>
<body class="theme-{{ theme }}"><div class="top"><div class="brand"><span class="brand-mark">IP</span><span class="brand-name">流量中转管理面板</span><span class="backend">{{ backend }}</span></div><div class="top-actions"><span class="state"><span class="state-dot"></span>服务在线</span><a class="btn ghost" href="/logout">退出</a></div></div>
<main class="wrap"><header class="page-head"><h1>端口转发控制台</h1><div class="runtime-line"><span class="runtime-chip">Python + {{ backend }}</span><span class="runtime-chip">内核转发</span></div></header>{% if msg %}<div class="msg">{{ msg }}</div>{% endif %}
<div class="console"><aside class="card compose"><div class="head"><div class="head-group"><span>新建转发规则</span><span class="route-path">域名:端口 → 目标出口</span></div><span class="caption">DNAT</span></div><div class="body"><form method="post" action="/add" class="grid">
<div class="field-protocol"><label>协议</label><select name="protocol"><option value="tcp">TCP</option><option value="udp">UDP</option><option value="all">TCP + UDP</option></select></div>
<div class="field-listener"><label>监听端口</label><input name="local_port" type="number" min="1" max="65535" required></div><div class="field-relay"><label>中转入口域名</label><input name="relay_host" placeholder="选填，如 relay.example.com" inputmode="url"></div><div class="field-target"><label>目标 IP / 域名</label><input name="target_ip" required></div><div class="field-target-port"><label>目标端口</label><input name="target_port" type="number" min="1" max="65535" required></div>
<div class="field-remark"><label>备注</label><input name="remark"></div><div class="field-quota"><label>流量上限 MB</label><input name="quota_mb" type="number" min="1"></div>
<div class="field-expiry"><label>到期时间 UTC+8</label><input name="expires_at" type="datetime-local"></div><div class="field-submit"><button class="primary">添加规则</button></div></form></div></aside>
<div class="control"><section class="metrics"><div class="metric"><div class="muted">总规则</div><div class="num">{{ rules|length }}</div></div><div class="metric"><div class="muted">总流量</div><div class="num">{{ total_traffic_text }}</div></div>
<div class="metric"><div class="muted">TCP 规则</div><div class="num"><span class="proto-key">TCP</span>{{ tcp_count }}</div></div><div class="metric"><div class="muted">UDP 规则</div><div class="num"><span class="proto-key udp">UDP</span>{{ udp_count }}</div></div></section>
<section class="card rules"><div class="head"><span>当前生效规则</span><span class="rule-count">{{ rules|length }}</span></div><div class="table-wrap"><table><thead><tr><th>协议</th><th>中转入口</th><th>目标地址</th><th>备注</th><th>总流量<br><small>上行 + 下行</small></th><th>到期时间</th><th class="action">操作</th></tr></thead><tbody>
{% for r in rules %}<tr><td data-label="协议"><span class="pill {% if r.protocol == 'TCP' %}tcp{% else %}udp{% endif %}">{{ r.protocol }}</span></td><td data-label="中转入口"><span class="port">{% if r.relay_host %}{{ r.relay_host }}{% else %}*{% endif %}:{{ r.local_port }}</span></td>
<td class="full" data-label="目标地址"><span class="pill">{{ r.target_ip }}:{{ r.target_port }}</span></td><td class="muted full" data-label="备注">{{ r.remark or '-' }}</td><td class="traffic" data-label="总流量">{{ r.traffic_text }}{% if r.quota_bytes %}<div class="quota-track"><div class="quota-fill" style="width:{{ r.traffic_percent }}%"></div></div>{% endif %}</td><td class="expiry" data-label="到期时间">{{ r.expires_text }}</td><td class="action" data-label="操作">
<form method="post" action="/delete" style="display:inline"><input type="hidden" name="protocol" value="{{ r.protocol|lower }}"><input type="hidden" name="local_port" value="{{ r.local_port }}">
<input type="hidden" name="target_ip" value="{{ r.target_ip }}"><input type="hidden" name="target_port" value="{{ r.target_port }}"><input type="hidden" name="remark" value="{{ r.remark }}">
<input type="hidden" name="rule_comment" value="{{ r.rule_comment }}">
<input type="hidden" name="pre_handle" value="{{ r.pre_handle }}"><input type="hidden" name="post_handle" value="{{ r.post_handle }}"><button class="danger" onclick="return confirm('确定删除这条规则?')">删除</button></form></td></tr>
{% else %}<tr><td colspan="7" class="empty" style="text-align:center;color:#6b7685;padding:34px">当前没有规则</td></tr>{% endfor %}
</tbody></table></div></section></div></div></main></body></html>
"""

def run(cmd, check=True):
    return subprocess.run(cmd, capture_output=True, text=True, check=check)

def valid_port(value):
    return value and value.isdigit() and 1 <= int(value) <= 65535

def normalize_target(value):
    return socket.gethostbyname(value.strip())

def normalize_relay_host(value):
    value = (value or "").strip().rstrip(".")
    if not value:
        return ""
    host = value.lower()
    if not host.isascii():
        raise ValueError("invalid relay host")
    try:
        ipaddress.ip_address(host)
    except ValueError:
        pass
    else:
        raise ValueError("relay host must be a domain")
    labels = host.split(".")
    if len(host) > 253 or len(labels) < 2 or any(not re.fullmatch(r"(?!-)[a-z0-9-]{1,63}(?<!-)", label) for label in labels):
        raise ValueError("invalid relay host")
    if not socket.gethostbyname_ex(host)[2]:
        raise ValueError("relay host does not resolve")
    return host

def comment_for(remark):
    remark = (remark or "").replace('"', "").replace("'", "").strip()
    return f"{MARK} | {remark}" if remark else MARK

def visible_remark(comment):
    if comment.startswith(f"{MARK} | "):
        return comment[len(MARK) + 3:]
    if comment == MARK:
        return ""
    return comment

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
        return datetime.datetime.strptime(value, "%Y-%m-%dT%H:%M").strftime("%Y-%m-%dT%H:%M")
    except ValueError:
        return None

def utc8_now():
    return datetime.datetime.utcnow() + datetime.timedelta(hours=8)

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

def format_expires(value):
    return value.replace("T", " ") + " UTC+8" if value else "不限"

def track_id_for(proto, local_port, target_ip, target_port, remark):
    raw = f"{proto.lower()}|{local_port}|{target_ip}|{target_port}|{remark or ''}"
    return hashlib.sha1(raw.encode("utf-8")).hexdigest()[:16]

def legacy_track_id_for(proto, local_port, target_ip, target_port, remark):
    raw = f"{proto.lower()}|{local_port}|{target_ip}|{target_port}|{remark or ''}"
    value = 0xcbf29ce484222325
    for byte in raw.encode("utf-8"):
        value ^= byte
        value = (value * 0x100000001b3) & 0xffffffffffffffff
    return f"{value:016x}"

def existing_track_id(proto, local_port, target_ip, target_port, remark, traffic, limits):
    current = track_id_for(proto, local_port, target_ip, target_port, remark)
    legacy = legacy_track_id_for(proto, local_port, target_ip, target_port, remark)
    if current in traffic or current in limits:
        return current
    return legacy if legacy in traffic or legacy in limits else current

def tracking_comment(track_id):
    return TRACK_PREFIX + track_id

def load_limits():
    limits = {}
    try:
        with open(LIMIT_FILE, "r", encoding="utf-8") as limit_file:
            for line in limit_file:
                parts = line.rstrip("\n").split("\t")
                if len(parts) >= 3:
                    limits[parts[0]] = {
                        "quota_bytes": int(parts[1] or 0),
                        "expires_at": parts[2],
                        "base_bytes": int(parts[3] or 0) if len(parts) >= 4 else 0,
                        "target_host": parts[4] if len(parts) >= 5 else "",
                        "relay_host": parts[5] if len(parts) >= 6 else "",
                    }
    except Exception:
        pass
    return limits

def save_limits(limits):
    tmp_path = LIMIT_FILE + ".tmp"
    with open(tmp_path, "w", encoding="utf-8") as limit_file:
        for track_id, limit in limits.items():
            limit_file.write(
                f"{track_id}\t{int(limit.get('quota_bytes', 0) or 0)}\t{limit.get('expires_at', '')}"
                f"\t{int(limit.get('base_bytes', 0) or 0)}\t{limit.get('target_host', '')}"
                f"\t{limit.get('relay_host', '')}\n"
            )
    os.replace(tmp_path, LIMIT_FILE)

def setup_nftables():
    run(["nft", "add", "table", "ip", "iptables_panel"], check=False)
    run(["nft", "add", "chain", "ip", "iptables_panel", "prerouting", "{", "type", "nat", "hook", "prerouting", "priority", "dstnat", ";", "policy", "accept", ";", "}"], check=False)
    run(["nft", "add", "chain", "ip", "iptables_panel", "postrouting", "{", "type", "nat", "hook", "postrouting", "priority", "srcnat", ";", "policy", "accept", ";", "}"], check=False)
    run(["nft", "add", "chain", "ip", "iptables_panel", "forward", "{", "type", "filter", "hook", "forward", "priority", "filter", ";", "policy", "accept", ";", "}"], check=False)

def get_iptables_tracking_bytes():
    usage = {}
    res = run(["iptables-save", "-c"], check=False)
    for line in res.stdout.splitlines():
        if "-A FORWARD" not in line or TRACK_PREFIX not in line:
            continue
        counter_m = re.match(r"\[(\d+):(\d+)\]\s+", line)
        comment_m = re.search(r'--comment\s+"?(' + re.escape(TRACK_PREFIX) + r'[a-f0-9]+)"?', line)
        if counter_m and comment_m:
            track_id = comment_m.group(1).replace(TRACK_PREFIX, "")
            usage[track_id] = usage.get(track_id, 0) + int(counter_m.group(2))
    return usage

def get_nft_tracking_bytes():
    usage = {}
    setup_nftables()
    output = run(["nft", "-a", "list", "chain", "ip", "iptables_panel", "forward"], check=False).stdout
    for line in output.splitlines():
        if TRACK_PREFIX not in line:
            continue
        comment_m = re.search(r'comment "(' + re.escape(TRACK_PREFIX) + r'[a-f0-9]+)"', line)
        bytes_m = re.search(r"counter packets \d+ bytes (\d+)", line)
        if comment_m and bytes_m:
            track_id = comment_m.group(1).replace(TRACK_PREFIX, "")
            usage[track_id] = usage.get(track_id, 0) + int(bytes_m.group(1))
    return usage

def get_tracking_bytes():
    return get_nft_tracking_bytes() if args.backend == "nftables" else get_iptables_tracking_bytes()

def add_tracking_rules(proto, target_ip, target_port, track_id):
    comment = tracking_comment(track_id)
    if args.backend == "nftables":
        setup_nftables()
        run(["nft", "add", "rule", "ip", "iptables_panel", "forward", "meta", "l4proto", proto, "ip", "daddr", target_ip, "th", "dport", target_port, "counter", "comment", comment])
        run(["nft", "add", "rule", "ip", "iptables_panel", "forward", "meta", "l4proto", proto, "ip", "saddr", target_ip, "th", "sport", target_port, "counter", "comment", comment])
    else:
        run(["iptables", "-A", "FORWARD", "-p", proto, "-d", target_ip, "--dport", target_port, "-m", "comment", "--comment", comment, "-j", "ACCEPT"])
        run(["iptables", "-A", "FORWARD", "-p", proto, "-s", target_ip, "--sport", target_port, "-m", "comment", "--comment", comment, "-j", "ACCEPT"])

def delete_tracking_rules(proto, target_ip, target_port, track_id):
    comment = tracking_comment(track_id)
    if args.backend == "nftables":
        output = run(["nft", "-a", "list", "chain", "ip", "iptables_panel", "forward"], check=False).stdout
        for line in output.splitlines():
            if comment in line:
                handle_m = re.search(r"# handle (\d+)", line)
                if handle_m:
                    run(["nft", "delete", "rule", "ip", "iptables_panel", "forward", "handle", handle_m.group(1)], check=False)
    else:
        run(["iptables", "-D", "FORWARD", "-p", proto, "-d", target_ip, "--dport", target_port, "-m", "comment", "--comment", comment, "-j", "ACCEPT"], check=False)
        run(["iptables", "-D", "FORWARD", "-p", proto, "-s", target_ip, "--sport", target_port, "-m", "comment", "--comment", comment, "-j", "ACCEPT"], check=False)

def list_iptables_rules():
    res = run(["iptables-save", "-t", "nat"], check=False)
    traffic = get_tracking_bytes()
    limits = load_limits()
    rules = []
    for line in res.stdout.splitlines():
        if not line.startswith("-A PREROUTING") or "-j DNAT" not in line:
            continue
        proto_m = re.search(r"-p\s+(tcp|udp)", line)
        lport_m = re.search(r"--dport\s+(\d+)", line)
        target_m = re.search(r"--to-destination\s+([\d.]+):(\d+)", line)
        remark_m = re.search(r'--comment\s+"([^"]+)"', line)
        if proto_m and lport_m and target_m:
            proto = proto_m.group(1)
            local_port = lport_m.group(1)
            target_ip = target_m.group(1)
            target_port = target_m.group(2)
            rule_comment = remark_m.group(1) if remark_m else ""
            remark = visible_remark(rule_comment)
            track_id = existing_track_id(proto, local_port, target_ip, target_port, remark, traffic, limits)
            limit = limits.get(track_id, {})
            quota_bytes = int(limit.get("quota_bytes", 0) or 0)
            used_bytes = traffic.get(track_id, 0) + int(limit.get("base_bytes", 0) or 0)
            rules.append({
                "protocol": proto.upper(),
                "local_port": local_port,
                "target_ip": target_ip,
                "target_port": target_port,
                "relay_host": limit.get("relay_host", ""),
                "remark": remark,
                "rule_comment": rule_comment,
                "pre_handle": "",
                "post_handle": "",
                "track_id": track_id,
                "traffic_bytes": used_bytes,
                "quota_bytes": quota_bytes,
                "traffic_percent": min(100, round(used_bytes * 100 / quota_bytes)) if quota_bytes else 0,
                "traffic_text": f"{format_bytes(used_bytes)} / {format_bytes(quota_bytes) if quota_bytes else '不限'}",
                "expires_at": limit.get("expires_at", ""),
                "expires_text": format_expires(limit.get("expires_at", "")),
            })
    return rules

def list_nftables_rules():
    setup_nftables()
    traffic = get_tracking_bytes()
    limits = load_limits()
    pre = run(["nft", "-a", "list", "chain", "ip", "iptables_panel", "prerouting"], check=False).stdout
    post = run(["nft", "-a", "list", "chain", "ip", "iptables_panel", "postrouting"], check=False).stdout
    post_handles = {}
    for line in post.splitlines():
        proto_m = re.search(r"meta l4proto (tcp|udp)", line)
        daddr_m = re.search(r"ip daddr ([\d.]+)", line)
        dport_m = re.search(r"th dport (\d+)", line)
        handle_m = re.search(r"# handle (\d+)", line)
        if proto_m and daddr_m and dport_m and handle_m:
            post_handles[(proto_m.group(1), daddr_m.group(1), dport_m.group(1))] = handle_m.group(1)

    rules = []
    for line in pre.splitlines():
        proto_m = re.search(r"meta l4proto (tcp|udp)", line)
        lport_m = re.search(r"th dport (\d+)", line)
        target_m = re.search(r"dnat to ([\d.]+):(\d+)", line)
        remark_m = re.search(r'comment "([^"]+)"', line)
        handle_m = re.search(r"# handle (\d+)", line)
        if proto_m and lport_m and target_m and handle_m:
            proto = proto_m.group(1)
            local_port = lport_m.group(1)
            target_ip = target_m.group(1)
            target_port = target_m.group(2)
            rule_comment = remark_m.group(1) if remark_m else ""
            remark = visible_remark(rule_comment)
            track_id = existing_track_id(proto, local_port, target_ip, target_port, remark, traffic, limits)
            limit = limits.get(track_id, {})
            quota_bytes = int(limit.get("quota_bytes", 0) or 0)
            used_bytes = traffic.get(track_id, 0) + int(limit.get("base_bytes", 0) or 0)
            rules.append({
                "protocol": proto.upper(),
                "local_port": local_port,
                "target_ip": target_ip,
                "target_port": target_port,
                "relay_host": limit.get("relay_host", ""),
                "remark": remark,
                "rule_comment": rule_comment,
                "pre_handle": handle_m.group(1),
                "post_handle": post_handles.get((proto, target_ip, target_port), ""),
                "track_id": track_id,
                "traffic_bytes": used_bytes,
                "quota_bytes": quota_bytes,
                "traffic_percent": min(100, round(used_bytes * 100 / quota_bytes)) if quota_bytes else 0,
                "traffic_text": f"{format_bytes(used_bytes)} / {format_bytes(quota_bytes) if quota_bytes else '不限'}",
                "expires_at": limit.get("expires_at", ""),
                "expires_text": format_expires(limit.get("expires_at", "")),
            })
    return rules

def list_rules():
    return list_nftables_rules() if args.backend == "nftables" else list_iptables_rules()

def add_rule(proto, local_port, target_ip, target_port, remark):
    comment = comment_for(remark)
    try:
        if args.backend == "nftables":
            setup_nftables()
            run(["nft", "add", "rule", "ip", "iptables_panel", "prerouting", "meta", "l4proto", proto, "th", "dport", local_port, "dnat", "to", f"{target_ip}:{target_port}", "comment", comment])
            run(["nft", "add", "rule", "ip", "iptables_panel", "postrouting", "ip", "daddr", target_ip, "meta", "l4proto", proto, "th", "dport", target_port, "masquerade", "comment", comment])
        else:
            pre = ["iptables", "-t", "nat", "-A", "PREROUTING", "-p", proto, "--dport", local_port, "-m", "comment", "--comment", comment, "-j", "DNAT", "--to-destination", f"{target_ip}:{target_port}"]
            post = ["iptables", "-t", "nat", "-A", "POSTROUTING", "-p", proto, "-d", target_ip, "--dport", target_port, "-m", "comment", "--comment", comment, "-j", "MASQUERADE"]
            run(pre)
            run(post)
        add_tracking_rules(proto, target_ip, target_port, track_id_for(proto, local_port, target_ip, target_port, remark))
    except Exception:
        for rule in list_rules():
            if rule["protocol"].lower() == proto and rule["local_port"] == local_port and rule["target_ip"] == target_ip and rule["target_port"] == target_port and rule["remark"] == remark:
                delete_rule({
                    "protocol": proto, "local_port": local_port, "target_ip": target_ip,
                    "target_port": target_port, "remark": remark,
                    "rule_comment": rule.get("rule_comment", ""),
                    "pre_handle": rule.get("pre_handle", ""), "post_handle": rule.get("post_handle", ""),
                })
        raise

def delete_rule(form):
    proto = form["protocol"]
    local_port = form["local_port"]
    target_ip = form["target_ip"]
    target_port = form["target_port"]
    remark = form.get("remark", "")
    track_id = track_id_for(proto, local_port, target_ip, target_port, remark)
    legacy_track_id = legacy_track_id_for(proto, local_port, target_ip, target_port, remark)
    if args.backend == "nftables" and form.get("pre_handle"):
        run(["nft", "delete", "rule", "ip", "iptables_panel", "prerouting", "handle", form["pre_handle"]], check=False)
        if form.get("post_handle"):
            run(["nft", "delete", "rule", "ip", "iptables_panel", "postrouting", "handle", form["post_handle"]], check=False)
        delete_tracking_rules(proto, target_ip, target_port, track_id)
        if legacy_track_id != track_id:
            delete_tracking_rules(proto, target_ip, target_port, legacy_track_id)
        limits = load_limits()
        limits.pop(track_id, None)
        limits.pop(legacy_track_id, None)
        save_limits(limits)
        return

    comment = form.get("rule_comment") or comment_for(form.get("remark", ""))
    pre = ["iptables", "-t", "nat", "-D", "PREROUTING", "-p", proto, "--dport", local_port, "-m", "comment", "--comment", comment, "-j", "DNAT", "--to-destination", f"{target_ip}:{target_port}"]
    post = ["iptables", "-t", "nat", "-D", "POSTROUTING", "-p", proto, "-d", target_ip, "--dport", target_port, "-m", "comment", "--comment", comment, "-j", "MASQUERADE"]
    run(pre, check=False)
    run(post, check=False)
    delete_tracking_rules(proto, target_ip, target_port, track_id)
    if legacy_track_id != track_id:
        delete_tracking_rules(proto, target_ip, target_port, legacy_track_id)
    limits = load_limits()
    limits.pop(track_id, None)
    limits.pop(legacy_track_id, None)
    save_limits(limits)

def enforce_limits_once():
    limits = load_limits()
    if not limits:
        return
    changed = False
    for rule in list_rules():
        limit = limits.get(rule["track_id"], {})
        quota_bytes = int(limit.get("quota_bytes", 0) or 0)
        expires_at = limit.get("expires_at", "")
        if (quota_bytes and rule["traffic_bytes"] >= quota_bytes) or is_expired(expires_at):
            delete_rule({
                "protocol": rule["protocol"].lower(),
                "local_port": rule["local_port"],
                "target_ip": rule["target_ip"],
                "target_port": rule["target_port"],
                "remark": rule["remark"],
                "rule_comment": rule.get("rule_comment", ""),
                "pre_handle": rule.get("pre_handle", ""),
                "post_handle": rule.get("post_handle", ""),
            })
            changed = True
    if changed:
        save_limits(load_limits())

def refresh_domain_rules_once():
    limits = load_limits()
    changed = False
    for rule in list_rules():
        limit = limits.get(rule["track_id"], {})
        target_host = limit.get("target_host", "")
        if not target_host:
            continue
        try:
            target_ips = socket.gethostbyname_ex(target_host)[2]
        except Exception:
            continue
        if not target_ips or rule["target_ip"] in target_ips:
            continue
        target_ip = target_ips[0]
        proto = rule["protocol"].lower()
        try:
            add_rule(proto, rule["local_port"], target_ip, rule["target_port"], rule["remark"])
            delete_rule({
                "protocol": proto,
                "local_port": rule["local_port"],
                "target_ip": rule["target_ip"],
                "target_port": rule["target_port"],
                "remark": rule["remark"],
                "rule_comment": rule.get("rule_comment", ""),
                "pre_handle": rule.get("pre_handle", ""),
                "post_handle": rule.get("post_handle", ""),
            })
        except Exception as exc:
            print(f"domain refresh failed for {target_host}: {exc}")
            continue
        limits.pop(rule["track_id"], None)
        new_track_id = track_id_for(proto, rule["local_port"], target_ip, rule["target_port"], rule["remark"])
        limits[new_track_id] = {
            "quota_bytes": int(limit.get("quota_bytes", 0) or 0),
            "expires_at": limit.get("expires_at", ""),
            "base_bytes": rule["traffic_bytes"],
            "target_host": target_host,
            "relay_host": limit.get("relay_host", ""),
        }
        changed = True
    if changed:
        save_limits(limits)

def limit_watcher():
    cycles = 0
    while True:
        try:
            with RULE_LOCK:
                enforce_limits_once()
                cycles += 1
                if cycles % 2 == 0:
                    refresh_domain_rules_once()
        except Exception as exc:
            print(exc)
        time.sleep(30)

def require_login():
    return session.get("logged_in") is True

@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        if request.form.get("username") == args.user and request.form.get("password") == args.password:
            session["logged_in"] = True
            return redirect(url_for("index"))
        return render_template_string(LOGIN, error="用户名或密码错误")
    return render_template_string(LOGIN)

@app.route("/logout")
def logout():
    session.clear()
    return redirect(url_for("login"))

@app.route("/")
def index():
    if not require_login():
        return redirect(url_for("login"))
    rules = list_rules()
    return render_template_string(
        PAGE,
        rules=rules,
        backend=args.backend,
        theme=PANEL_THEME,
        total_traffic_text=format_bytes(sum(int(r.get("traffic_bytes", 0) or 0) for r in rules)),
        tcp_count=sum(1 for r in rules if r["protocol"] == "TCP"),
        udp_count=sum(1 for r in rules if r["protocol"] == "UDP"),
        msg=request.args.get("msg", ""),
    )

@app.route("/add", methods=["POST"])
@serialized_rule_change
def add():
    if not require_login():
        return redirect(url_for("login"))
    local_port = request.form.get("local_port", "")
    target_port = request.form.get("target_port", "")
    quota_bytes = parse_quota_mb(request.form.get("quota_mb"))
    expires_at = parse_expires_at(request.form.get("expires_at"))
    if not valid_port(local_port) or not valid_port(target_port):
        return redirect(url_for("index", msg="端口必须是 1-65535"))
    if int(local_port) == args.port:
        return redirect(url_for("index", msg="监听端口已被面板服务占用"))
    if quota_bytes is None:
        return redirect(url_for("index", msg="流量上限必须是数字，单位 MB"))
    if expires_at is None:
        return redirect(url_for("index", msg="到期时间格式无效，请使用 UTC+8 时间"))
    try:
        relay_host = normalize_relay_host(request.form.get("relay_host"))
    except Exception:
        return redirect(url_for("index", msg="中转入口域名无效或无法解析"))
    target_input = request.form.get("target_ip", "").strip()
    try:
        target_ip = normalize_target(target_input)
    except Exception:
        return redirect(url_for("index", msg="目标 IP 或域名无效"))
    protos = ["tcp", "udp"] if request.form.get("protocol") == "all" else [request.form.get("protocol", "tcp")]
    current = list_rules()
    if any(r["local_port"] == local_port for r in current):
        return redirect(url_for("index", msg="监听端口已被占用；如需 TCP + UDP，请一次选择双栈"))
    created_protos = []
    try:
        limits = load_limits()
        for proto in protos:
            remark = request.form.get("remark", "").replace('"', "").replace("'", "").strip()
            if target_ip != target_input:
                remark = f"{remark} [{target_input}]".strip()
            add_rule(proto, local_port, target_ip, target_port, remark)
            created_protos.append(proto)
            if quota_bytes or expires_at or target_ip != target_input or relay_host:
                limits[track_id_for(proto, local_port, target_ip, target_port, remark)] = {
                    "quota_bytes": quota_bytes,
                    "expires_at": expires_at,
                    "base_bytes": 0,
                    "target_host": target_input if target_ip != target_input else "",
                    "relay_host": relay_host,
                }
        save_limits(limits)
        return redirect(url_for("index", msg="添加成功"))
    except Exception as exc:
        for rule in list_rules():
            if rule["protocol"].lower() in created_protos and rule["local_port"] == local_port and rule["target_ip"] == target_ip and rule["target_port"] == target_port:
                delete_rule({
                    "protocol": rule["protocol"].lower(), "local_port": local_port,
                    "target_ip": target_ip, "target_port": target_port, "remark": rule["remark"],
                    "rule_comment": rule.get("rule_comment", ""),
                    "pre_handle": rule.get("pre_handle", ""), "post_handle": rule.get("post_handle", ""),
                })
        return redirect(url_for("index", msg=f"添加失败: {html.escape(str(exc))[:300]}"))

@app.route("/delete", methods=["POST"])
@serialized_rule_change
def delete():
    if not require_login():
        return redirect(url_for("login"))
    delete_rule(request.form)
    return redirect(url_for("index", msg="删除完成"))

threading.Thread(target=limit_watcher, daemon=True).start()

if __name__ == "__main__":
    subprocess.run(["sysctl", "-w", "net.ipv4.ip_forward=1"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if args.backend == "nftables":
        setup_nftables()
    app.run(host="0.0.0.0", port=args.port, threaded=True, use_reloader=False)
PYEOF

  python3 -m py_compile "$INSTALL_DIR/panel.py.new"
  mv -f "$INSTALL_DIR/panel.py.new" "$INSTALL_DIR/panel.py"
}

write_rust_panel() {
  cat << 'RSEOF' > "$INSTALL_DIR/panel.rs.new"
use std::collections::HashMap;
use std::env;
use std::fs;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream, ToSocketAddrs};
use std::process::Command;
use std::sync::{mpsc, Arc, Mutex};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

#[derive(Clone)]
struct Config {
    port: u16,
    user: String,
    password: String,
    backend: String,
    theme: String,
    token: String,
    rule_lock: Arc<Mutex<()>>,
}

#[derive(Clone, Default)]
struct Rule {
    protocol: String,
    local_port: String,
    target_ip: String,
    target_port: String,
    relay_host: String,
    remark: String,
    rule_comment: String,
    pre_handle: String,
    post_handle: String,
    track_id: String,
    traffic_bytes: u64,
    quota_bytes: u64,
    traffic_text: String,
    expires_at: String,
    expires_text: String,
}

fn arg_value(args: &[String], name: &str, default: &str) -> String {
    args.windows(2)
        .find(|pair| pair[0] == name)
        .map(|pair| pair[1].clone())
        .unwrap_or_else(|| default.to_string())
}

fn decode_hex_env(name: &str, default: &str) -> String {
    let value = match env::var(name) {
        Ok(value) if !value.is_empty() && value.len() % 2 == 0 => value,
        _ => return default.to_string(),
    };
    let mut bytes = Vec::with_capacity(value.len() / 2);
    for index in (0..value.len()).step_by(2) {
        match u8::from_str_radix(&value[index..index + 2], 16) {
            Ok(byte) => bytes.push(byte),
            Err(_) => return default.to_string(),
        }
    }
    String::from_utf8(bytes).unwrap_or_else(|_| default.to_string())
}

fn shell(cmd: &str, args: &[&str]) -> Result<String, String> {
    let out = Command::new(cmd).args(args).output().map_err(|e| e.to_string())?;
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).to_string())
    } else {
        Err(String::from_utf8_lossy(&out.stderr).to_string())
    }
}

fn shell_ok(cmd: &str, args: &[&str]) {
    let _ = Command::new(cmd).args(args).output();
}

fn html_escape(value: &str) -> String {
    value.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
}

fn url_decode(value: &str) -> String {
    let mut out = String::new();
    let bytes = value.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'+' {
            out.push(' ');
            i += 1;
        } else if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(hex) = u8::from_str_radix(&value[i + 1..i + 3], 16) {
                out.push(hex as char);
                i += 3;
            } else {
                out.push(bytes[i] as char);
                i += 1;
            }
        } else {
            out.push(bytes[i] as char);
            i += 1;
        }
    }
    out
}

fn parse_form(body: &str) -> HashMap<String, String> {
    let mut map = HashMap::new();
    for pair in body.split('&') {
        let mut parts = pair.splitn(2, '=');
        if let Some(k) = parts.next() {
            let v = parts.next().unwrap_or("");
            map.insert(url_decode(k), url_decode(v));
        }
    }
    map
}

fn token_after(line: &str, token: &str) -> Option<String> {
    let parts: Vec<&str> = line.split_whitespace().collect();
    for i in 0..parts.len() {
        if parts[i] == token && i + 1 < parts.len() {
            return Some(parts[i + 1].trim_matches('"').to_string());
        }
    }
    None
}

fn quoted_after(line: &str, token: &str) -> String {
    if let Some(pos) = line.find(token) {
        let rest = &line[pos + token.len()..];
        if let Some(start) = rest.find('"') {
            let rest = &rest[start + 1..];
            if let Some(end) = rest.find('"') {
                return rest[..end].to_string();
            }
        }
    }
    String::new()
}

fn visible_remark(comment: &str) -> String {
    comment.strip_prefix("iptables-panel | ").unwrap_or(comment).replace("iptables-panel", "")
}

fn comment_for(remark: &str) -> String {
    let clean = remark.replace('"', "").replace('\'', "").trim().to_string();
    if clean.is_empty() { "iptables-panel".to_string() } else { format!("iptables-panel | {}", clean) }
}

fn track_id_for(proto: &str, local_port: &str, target_ip: &str, target_port: &str, remark: &str) -> String {
    let raw = format!("{}|{}|{}|{}|{}", proto.to_lowercase(), local_port, target_ip, target_port, remark);
    let mut message = raw.into_bytes();
    let bit_len = (message.len() as u64) * 8;
    message.push(0x80);
    while message.len() % 64 != 56 {
        message.push(0);
    }
    message.extend_from_slice(&bit_len.to_be_bytes());

    let mut state = [0x67452301_u32, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0];
    for chunk in message.chunks(64) {
        let mut words = [0_u32; 80];
        for (index, word) in words.iter_mut().take(16).enumerate() {
            let offset = index * 4;
            *word = u32::from_be_bytes([chunk[offset], chunk[offset + 1], chunk[offset + 2], chunk[offset + 3]]);
        }
        for index in 16..80 {
            words[index] = (words[index - 3] ^ words[index - 8] ^ words[index - 14] ^ words[index - 16]).rotate_left(1);
        }
        let (mut a, mut b, mut c, mut d, mut e) = (state[0], state[1], state[2], state[3], state[4]);
        for (index, word) in words.iter().enumerate() {
            let (function, constant) = match index {
                0..=19 => ((b & c) | ((!b) & d), 0x5a827999),
                20..=39 => (b ^ c ^ d, 0x6ed9eba1),
                40..=59 => ((b & c) | (b & d) | (c & d), 0x8f1bbcdc),
                _ => (b ^ c ^ d, 0xca62c1d6),
            };
            let temp = a.rotate_left(5).wrapping_add(function).wrapping_add(e).wrapping_add(constant).wrapping_add(*word);
            e = d;
            d = c;
            c = b.rotate_left(30);
            b = a;
            a = temp;
        }
        state[0] = state[0].wrapping_add(a);
        state[1] = state[1].wrapping_add(b);
        state[2] = state[2].wrapping_add(c);
        state[3] = state[3].wrapping_add(d);
        state[4] = state[4].wrapping_add(e);
    }
    format!("{:08x}{:08x}", state[0], state[1])
}

fn legacy_track_id_for(proto: &str, local_port: &str, target_ip: &str, target_port: &str, remark: &str) -> String {
    let raw = format!("{}|{}|{}|{}|{}", proto.to_lowercase(), local_port, target_ip, target_port, remark);
    let mut hash: u64 = 0xcbf29ce484222325;
    for byte in raw.as_bytes() {
        hash ^= *byte as u64;
        hash = hash.wrapping_mul(0x100000001b3);
    }
    format!("{:016x}", hash)
}

fn existing_track_id(proto: &str, local_port: &str, target_ip: &str, target_port: &str, remark: &str, usage: &HashMap<String, u64>, limits: &HashMap<String, Limit>) -> String {
    let current = track_id_for(proto, local_port, target_ip, target_port, remark);
    let legacy = legacy_track_id_for(proto, local_port, target_ip, target_port, remark);
    if usage.contains_key(&current) || limits.contains_key(&current) {
        current
    } else if usage.contains_key(&legacy) || limits.contains_key(&legacy) {
        legacy
    } else {
        current
    }
}

fn tracking_comment(track_id: &str) -> String {
    format!("iptables-panel-track:{}", track_id)
}

#[derive(Clone, Default)]
struct Limit {
    quota_bytes: u64,
    expires_at: String,
    base_bytes: u64,
    target_host: String,
    relay_host: String,
}

fn load_limits() -> HashMap<String, Limit> {
    let mut limits = HashMap::new();
    if let Ok(content) = fs::read_to_string("/opt/iptables-panel/limits.tsv") {
        for line in content.lines() {
            let parts: Vec<&str> = line.split('\t').collect();
            if parts.len() >= 3 {
                limits.insert(parts[0].to_string(), Limit {
                    quota_bytes: parts[1].parse().unwrap_or(0),
                    expires_at: parts[2].to_string(),
                    base_bytes: parts.get(3).and_then(|value| value.parse().ok()).unwrap_or(0),
                    target_host: parts.get(4).unwrap_or(&"").to_string(),
                    relay_host: parts.get(5).unwrap_or(&"").to_string(),
                });
            }
        }
    }
    limits
}

fn save_limits(limits: &HashMap<String, Limit>) {
    let mut content = String::new();
    for (track_id, limit) in limits {
        content.push_str(&format!("{}\t{}\t{}\t{}\t{}\t{}\n", track_id, limit.quota_bytes, limit.expires_at, limit.base_bytes, limit.target_host, limit.relay_host));
    }
    let _ = fs::write("/opt/iptables-panel/limits.tsv.tmp", content);
    let _ = fs::rename("/opt/iptables-panel/limits.tsv.tmp", "/opt/iptables-panel/limits.tsv");
}

fn parse_quota_mb(value: Option<&String>) -> Option<u64> {
    let raw = value.map(String::as_str).unwrap_or("").trim();
    if raw.is_empty() {
        return Some(0);
    }
    raw.parse::<u64>().ok().filter(|v| *v > 0).map(|v| v * 1024 * 1024)
}

fn parse_expires_at(value: Option<&String>) -> Option<String> {
    let raw = value.map(String::as_str).unwrap_or("").trim();
    if raw.is_empty() {
        return Some(String::new());
    }
    let bytes = raw.as_bytes();
    let valid = bytes.len() == 16
        && bytes[4] == b'-'
        && bytes[7] == b'-'
        && bytes[10] == b'T'
        && bytes[13] == b':'
        && raw.chars().enumerate().all(|(i, ch)| matches!(i, 4 | 7 | 10 | 13) || ch.is_ascii_digit());
    if valid { Some(raw.to_string()) } else { None }
}

fn normalize_relay_host(value: Option<&String>) -> Option<String> {
    let host = value.map(String::as_str).unwrap_or("").trim().trim_end_matches('.').to_lowercase();
    if host.is_empty() {
        return Some(String::new());
    }
    if host.len() > 253 || !host.is_ascii() || host.parse::<std::net::IpAddr>().is_ok() {
        return None;
    }
    let labels: Vec<&str> = host.split('.').collect();
    if labels.len() < 2 || labels.iter().any(|label| {
        label.is_empty()
            || label.len() > 63
            || label.starts_with('-')
            || label.ends_with('-')
            || !label.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
    }) {
        return None;
    }
    let resolves_ipv4 = format!("{}:0", host)
        .to_socket_addrs()
        .map(|mut addresses| addresses.any(|address| address.is_ipv4()))
        .unwrap_or(false);
    if resolves_ipv4 { Some(host) } else { None }
}

fn utc8_now_string() -> String {
    shell("date", &["-u", "-d", "+8 hours", "+%Y-%m-%dT%H:%M"]).unwrap_or_default().trim().to_string()
}

fn is_expired(value: &str) -> bool {
    !value.is_empty() && utc8_now_string().as_str() >= value
}

fn format_bytes(value: u64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"];
    let mut size = value as f64;
    for unit in units {
        if size < 1024.0 || unit == "TB" {
            return if unit == "B" { format!("{} B", size as u64) } else { format!("{:.1} {}", size, unit) };
        }
        size /= 1024.0;
    }
    format!("{} B", value)
}

fn format_expires(value: &str) -> String {
    if value.is_empty() { "不限".to_string() } else { format!("{} UTC+8", value.replace('T', " ")) }
}

fn setup_nftables() {
    shell_ok("nft", &["add", "table", "ip", "iptables_panel"]);
    shell_ok("nft", &["add", "chain", "ip", "iptables_panel", "prerouting", "{", "type", "nat", "hook", "prerouting", "priority", "dstnat", ";", "policy", "accept", ";", "}"]);
    shell_ok("nft", &["add", "chain", "ip", "iptables_panel", "postrouting", "{", "type", "nat", "hook", "postrouting", "priority", "srcnat", ";", "policy", "accept", ";", "}"]);
    shell_ok("nft", &["add", "chain", "ip", "iptables_panel", "forward", "{", "type", "filter", "hook", "forward", "priority", "filter", ";", "policy", "accept", ";", "}"]);
}

fn tracking_bytes_iptables() -> HashMap<String, u64> {
    let mut usage = HashMap::new();
    let output = shell("iptables-save", &["-c"]).unwrap_or_default();
    for line in output.lines() {
        if !line.contains("-A FORWARD") || !line.contains("iptables-panel-track:") {
            continue;
        }
        let bytes = line.split(']').next().and_then(|left| left.rsplit(':').next()).and_then(|v| v.parse::<u64>().ok()).unwrap_or(0);
        if let Some(pos) = line.find("iptables-panel-track:") {
            let id = line[pos + "iptables-panel-track:".len()..].split(|c: char| c == '"' || c.is_whitespace()).next().unwrap_or("").to_string();
            if !id.is_empty() {
                *usage.entry(id).or_insert(0) += bytes;
            }
        }
    }
    usage
}

fn tracking_bytes_nftables() -> HashMap<String, u64> {
    setup_nftables();
    let mut usage = HashMap::new();
    let output = shell("nft", &["-a", "list", "chain", "ip", "iptables_panel", "forward"]).unwrap_or_default();
    for line in output.lines() {
        if !line.contains("iptables-panel-track:") {
            continue;
        }
        let parts: Vec<&str> = line.split_whitespace().collect();
        let mut bytes = 0_u64;
        for i in 0..parts.len() {
            if parts[i] == "bytes" && i + 1 < parts.len() {
                bytes = parts[i + 1].parse().unwrap_or(0);
            }
        }
        if let Some(pos) = line.find("iptables-panel-track:") {
            let id = line[pos + "iptables-panel-track:".len()..].split(|c: char| c == '"' || c.is_whitespace()).next().unwrap_or("").to_string();
            if !id.is_empty() {
                *usage.entry(id).or_insert(0) += bytes;
            }
        }
    }
    usage
}

fn tracking_bytes(backend: &str) -> HashMap<String, u64> {
    if backend == "nftables" { tracking_bytes_nftables() } else { tracking_bytes_iptables() }
}

fn add_tracking_rules(config: &Config, proto: &str, target_ip: &str, target_port: &str, track_id: &str) -> Result<(), String> {
    let comment = tracking_comment(track_id);
    if config.backend == "nftables" {
        setup_nftables();
        shell("nft", &["add", "rule", "ip", "iptables_panel", "forward", "meta", "l4proto", proto, "ip", "daddr", target_ip, "th", "dport", target_port, "counter", "comment", &comment])?;
        shell("nft", &["add", "rule", "ip", "iptables_panel", "forward", "meta", "l4proto", proto, "ip", "saddr", target_ip, "th", "sport", target_port, "counter", "comment", &comment])?;
    } else {
        shell("iptables", &["-A", "FORWARD", "-p", proto, "-d", target_ip, "--dport", target_port, "-m", "comment", "--comment", &comment, "-j", "ACCEPT"])?;
        shell("iptables", &["-A", "FORWARD", "-p", proto, "-s", target_ip, "--sport", target_port, "-m", "comment", "--comment", &comment, "-j", "ACCEPT"])?;
    }
    Ok(())
}

fn delete_tracking_rules(config: &Config, proto: &str, target_ip: &str, target_port: &str, track_id: &str) {
    let comment = tracking_comment(track_id);
    if config.backend == "nftables" {
        let output = shell("nft", &["-a", "list", "chain", "ip", "iptables_panel", "forward"]).unwrap_or_default();
        for line in output.lines() {
            if line.contains(&comment) {
                let handle = handle_from(line);
                if !handle.is_empty() {
                    shell_ok("nft", &["delete", "rule", "ip", "iptables_panel", "forward", "handle", &handle]);
                }
            }
        }
    } else {
        shell_ok("iptables", &["-D", "FORWARD", "-p", proto, "-d", target_ip, "--dport", target_port, "-m", "comment", "--comment", &comment, "-j", "ACCEPT"]);
        shell_ok("iptables", &["-D", "FORWARD", "-p", proto, "-s", target_ip, "--sport", target_port, "-m", "comment", "--comment", &comment, "-j", "ACCEPT"]);
    }
}

fn list_iptables_rules() -> Vec<Rule> {
    let output = shell("iptables-save", &["-t", "nat"]).unwrap_or_default();
    let usage = tracking_bytes_iptables();
    let limits = load_limits();
    let mut rules = Vec::new();
    for line in output.lines() {
        if !line.starts_with("-A PREROUTING") || !line.contains("-j DNAT") {
            continue;
        }
        let protocol = if line.contains("-p tcp") { "TCP" } else if line.contains("-p udp") { "UDP" } else { continue };
        let Some(local_port) = token_after(line, "--dport") else { continue };
        let Some(target) = token_after(line, "--to-destination") else { continue };
        let mut target_parts = target.splitn(2, ':');
        let target_ip = target_parts.next().unwrap_or("").to_string();
        let target_port = target_parts.next().unwrap_or("").to_string();
        if target_ip.is_empty() || target_port.is_empty() {
            continue;
        }
        let comment = quoted_after(line, "--comment");
        let remark = visible_remark(&comment);
        let track_id = existing_track_id(protocol, &local_port, &target_ip, &target_port, &remark, &usage, &limits);
        let limit = limits.get(&track_id).cloned().unwrap_or_default();
        let used = usage.get(&track_id).copied().unwrap_or(0).saturating_add(limit.base_bytes);
        rules.push(Rule {
            protocol: protocol.to_string(),
            local_port,
            target_ip,
            target_port,
            relay_host: limit.relay_host.clone(),
            remark,
            rule_comment: comment,
            track_id,
            traffic_bytes: used,
            quota_bytes: limit.quota_bytes,
            traffic_text: format!("{} / {}", format_bytes(used), if limit.quota_bytes > 0 { format_bytes(limit.quota_bytes) } else { "不限".to_string() }),
            expires_at: limit.expires_at.clone(),
            expires_text: format_expires(&limit.expires_at),
            ..Rule::default()
        });
    }
    rules
}

fn handle_from(line: &str) -> String {
    line.rsplit("# handle ").next().unwrap_or("").trim().to_string()
}

fn list_nftables_rules() -> Vec<Rule> {
    setup_nftables();
    let usage = tracking_bytes_nftables();
    let limits = load_limits();
    let pre = shell("nft", &["-a", "list", "chain", "ip", "iptables_panel", "prerouting"]).unwrap_or_default();
    let post = shell("nft", &["-a", "list", "chain", "ip", "iptables_panel", "postrouting"]).unwrap_or_default();
    let mut post_handles: HashMap<String, String> = HashMap::new();
    for line in post.lines() {
        if !line.contains("masquerade") || !line.contains("# handle ") {
            continue;
        }
        let proto = if line.contains("meta l4proto tcp") { "tcp" } else if line.contains("meta l4proto udp") { "udp" } else { continue };
        let parts: Vec<&str> = line.split_whitespace().collect();
        let mut daddr = "";
        let mut dport = "";
        for i in 0..parts.len() {
            if parts[i] == "daddr" && i + 1 < parts.len() { daddr = parts[i + 1]; }
            if parts[i] == "dport" && i + 1 < parts.len() { dport = parts[i + 1]; }
        }
        if !daddr.is_empty() && !dport.is_empty() {
            post_handles.insert(format!("{}:{}:{}", proto, daddr, dport), handle_from(line));
        }
    }

    let mut rules = Vec::new();
    for line in pre.lines() {
        if !line.contains("dnat to") || !line.contains("# handle ") {
            continue;
        }
        let proto = if line.contains("meta l4proto tcp") { "tcp" } else if line.contains("meta l4proto udp") { "udp" } else { continue };
        let parts: Vec<&str> = line.split_whitespace().collect();
        let mut local_port = "";
        let mut target = "";
        for i in 0..parts.len() {
            if parts[i] == "dport" && i + 1 < parts.len() { local_port = parts[i + 1]; }
            if parts[i] == "to" && i + 1 < parts.len() { target = parts[i + 1]; }
        }
        let mut target_parts = target.splitn(2, ':');
        let target_ip = target_parts.next().unwrap_or("").to_string();
        let target_port = target_parts.next().unwrap_or("").to_string();
        if local_port.is_empty() || target_ip.is_empty() || target_port.is_empty() {
            continue;
        }
        let comment = quoted_after(line, "comment");
        let remark = visible_remark(&comment);
        let key = format!("{}:{}:{}", proto, target_ip, target_port);
        let track_id = existing_track_id(proto, local_port, &target_ip, &target_port, &remark, &usage, &limits);
        let limit = limits.get(&track_id).cloned().unwrap_or_default();
        let used = usage.get(&track_id).copied().unwrap_or(0).saturating_add(limit.base_bytes);
        rules.push(Rule {
            protocol: proto.to_uppercase(),
            local_port: local_port.to_string(),
            target_ip,
            target_port,
            relay_host: limit.relay_host.clone(),
            remark,
            rule_comment: comment,
            pre_handle: handle_from(line),
            post_handle: post_handles.get(&key).cloned().unwrap_or_default(),
            track_id,
            traffic_bytes: used,
            quota_bytes: limit.quota_bytes,
            traffic_text: format!("{} / {}", format_bytes(used), if limit.quota_bytes > 0 { format_bytes(limit.quota_bytes) } else { "不限".to_string() }),
            expires_at: limit.expires_at.clone(),
            expires_text: format_expires(&limit.expires_at),
        });
    }
    rules
}

fn list_rules(backend: &str) -> Vec<Rule> {
    if backend == "nftables" { list_nftables_rules() } else { list_iptables_rules() }
}

fn valid_port(value: &str) -> bool {
    value.parse::<u16>().map(|v| v > 0).unwrap_or(false)
}

fn add_rule(config: &Config, proto: &str, local_port: &str, target_ip: &str, target_port: &str, remark: &str) -> Result<(), String> {
    let comment = comment_for(remark);
    let track_id = track_id_for(proto, local_port, target_ip, target_port, remark);
    let result = (|| -> Result<(), String> {
        if config.backend == "nftables" {
            setup_nftables();
            shell("nft", &["add", "rule", "ip", "iptables_panel", "prerouting", "meta", "l4proto", proto, "th", "dport", local_port, "dnat", "to", &format!("{}:{}", target_ip, target_port), "comment", &comment])?;
            shell("nft", &["add", "rule", "ip", "iptables_panel", "postrouting", "ip", "daddr", target_ip, "meta", "l4proto", proto, "th", "dport", target_port, "masquerade", "comment", &comment])?;
        } else {
            shell("iptables", &["-t", "nat", "-A", "PREROUTING", "-p", proto, "--dport", local_port, "-m", "comment", "--comment", &comment, "-j", "DNAT", "--to-destination", &format!("{}:{}", target_ip, target_port)])?;
            shell("iptables", &["-t", "nat", "-A", "POSTROUTING", "-p", proto, "-d", target_ip, "--dport", target_port, "-m", "comment", "--comment", &comment, "-j", "MASQUERADE"])?;
        }
        add_tracking_rules(config, proto, target_ip, target_port, &track_id)
    })();

    if let Err(error) = result {
        let mut removed = false;
        for rule in list_rules(&config.backend) {
            if rule.protocol.to_lowercase() == proto && rule.local_port == local_port && rule.target_ip == target_ip && rule.target_port == target_port && rule.remark == remark {
                let mut form = HashMap::new();
                form.insert("protocol".to_string(), proto.to_string());
                form.insert("local_port".to_string(), local_port.to_string());
                form.insert("target_ip".to_string(), target_ip.to_string());
                form.insert("target_port".to_string(), target_port.to_string());
                form.insert("remark".to_string(), remark.to_string());
                form.insert("rule_comment".to_string(), rule.rule_comment.clone());
                form.insert("pre_handle".to_string(), rule.pre_handle);
                form.insert("post_handle".to_string(), rule.post_handle);
                delete_rule(config, &form);
                removed = true;
            }
        }
        if !removed {
            delete_tracking_rules(config, proto, target_ip, target_port, &track_id);
        }
        return Err(error);
    }
    Ok(())
}

fn delete_rule(config: &Config, form: &HashMap<String, String>) {
    let proto = form.get("protocol").map(String::as_str).unwrap_or("tcp");
    let local_port = form.get("local_port").map(String::as_str).unwrap_or("");
    let target_ip = form.get("target_ip").map(String::as_str).unwrap_or("");
    let target_port = form.get("target_port").map(String::as_str).unwrap_or("");
    let remark = form.get("remark").map(String::as_str).unwrap_or("");
    let track_id = track_id_for(proto, local_port, target_ip, target_port, remark);
    let legacy_track_id = legacy_track_id_for(proto, local_port, target_ip, target_port, remark);
    if config.backend == "nftables" {
        if let Some(handle) = form.get("pre_handle") {
            if !handle.is_empty() {
                shell_ok("nft", &["delete", "rule", "ip", "iptables_panel", "prerouting", "handle", handle]);
            }
        }
        if let Some(handle) = form.get("post_handle") {
            if !handle.is_empty() {
                shell_ok("nft", &["delete", "rule", "ip", "iptables_panel", "postrouting", "handle", handle]);
            }
        }
        delete_tracking_rules(config, proto, target_ip, target_port, &track_id);
        if legacy_track_id != track_id {
            delete_tracking_rules(config, proto, target_ip, target_port, &legacy_track_id);
        }
        let mut limits = load_limits();
        limits.remove(&track_id);
        limits.remove(&legacy_track_id);
        save_limits(&limits);
        return;
    }

    let comment = form.get("rule_comment").cloned().unwrap_or_else(|| comment_for(remark));
    shell_ok("iptables", &["-t", "nat", "-D", "PREROUTING", "-p", proto, "--dport", local_port, "-m", "comment", "--comment", &comment, "-j", "DNAT", "--to-destination", &format!("{}:{}", target_ip, target_port)]);
    shell_ok("iptables", &["-t", "nat", "-D", "POSTROUTING", "-p", proto, "-d", target_ip, "--dport", target_port, "-m", "comment", "--comment", &comment, "-j", "MASQUERADE"]);
    delete_tracking_rules(config, proto, target_ip, target_port, &track_id);
    if legacy_track_id != track_id {
        delete_tracking_rules(config, proto, target_ip, target_port, &legacy_track_id);
    }
    let mut limits = load_limits();
    limits.remove(&track_id);
    limits.remove(&legacy_track_id);
    save_limits(&limits);
}

fn enforce_limits_once(config: &Config) {
    let limits = load_limits();
    if limits.is_empty() {
        return;
    }
    for rule in list_rules(&config.backend) {
        if let Some(limit) = limits.get(&rule.track_id) {
            if (limit.quota_bytes > 0 && rule.traffic_bytes >= limit.quota_bytes) || is_expired(&limit.expires_at) {
                let mut form = HashMap::new();
                form.insert("protocol".to_string(), rule.protocol.to_lowercase());
                form.insert("local_port".to_string(), rule.local_port.clone());
                form.insert("target_ip".to_string(), rule.target_ip.clone());
                form.insert("target_port".to_string(), rule.target_port.clone());
                form.insert("remark".to_string(), rule.remark.clone());
                form.insert("rule_comment".to_string(), rule.rule_comment.clone());
                form.insert("pre_handle".to_string(), rule.pre_handle.clone());
                form.insert("post_handle".to_string(), rule.post_handle.clone());
                delete_rule(config, &form);
            }
        }
    }
}

fn resolve_targets(host: &str) -> Vec<String> {
    let output = shell("getent", &["ahostsv4", host]).unwrap_or_default();
    let mut targets = Vec::new();
    for line in output.lines() {
        if let Some(address) = line.split_whitespace().next() {
            if !targets.iter().any(|current| current == address) {
                targets.push(address.to_string());
            }
        }
    }
    targets
}

fn resolve_target(host: &str) -> Option<String> {
    resolve_targets(host).into_iter().next()
}

fn refresh_domain_rules_once(config: &Config) {
    let mut limits = load_limits();
    let mut changed = false;
    for rule in list_rules(&config.backend) {
        let Some(limit) = limits.get(&rule.track_id).cloned() else { continue };
        if limit.target_host.is_empty() {
            continue;
        }
        let target_ips = resolve_targets(&limit.target_host);
        if target_ips.is_empty() || target_ips.iter().any(|address| address == &rule.target_ip) {
            continue;
        }
        let target_ip = target_ips[0].clone();
        let proto = rule.protocol.to_lowercase();
        if add_rule(config, &proto, &rule.local_port, &target_ip, &rule.target_port, &rule.remark).is_err() {
            continue;
        }
        let mut form = HashMap::new();
        form.insert("protocol".to_string(), proto.clone());
        form.insert("local_port".to_string(), rule.local_port.clone());
        form.insert("target_ip".to_string(), rule.target_ip.clone());
        form.insert("target_port".to_string(), rule.target_port.clone());
        form.insert("remark".to_string(), rule.remark.clone());
        form.insert("rule_comment".to_string(), rule.rule_comment.clone());
        form.insert("pre_handle".to_string(), rule.pre_handle.clone());
        form.insert("post_handle".to_string(), rule.post_handle.clone());
        delete_rule(config, &form);

        limits.remove(&rule.track_id);
        limits.insert(track_id_for(&proto, &rule.local_port, &target_ip, &rule.target_port, &rule.remark), Limit {
            quota_bytes: limit.quota_bytes,
            expires_at: limit.expires_at,
            base_bytes: rule.traffic_bytes,
            target_host: limit.target_host,
            relay_host: limit.relay_host,
        });
        changed = true;
    }
    if changed {
        save_limits(&limits);
    }
}

fn limit_watcher(config: Config) {
    let mut cycles = 0_u64;
    loop {
        if let Ok(_guard) = config.rule_lock.lock() {
            enforce_limits_once(&config);
            cycles += 1;
            if cycles % 2 == 0 {
                refresh_domain_rules_once(&config);
            }
        }
        thread::sleep(Duration::from_secs(30));
    }
}

fn page(config: &Config, msg: &str) -> String {
    let rules = list_rules(&config.backend);
    let tcp_count = rules.iter().filter(|r| r.protocol == "TCP").count();
    let udp_count = rules.iter().filter(|r| r.protocol == "UDP").count();
    let total_traffic_text = format_bytes(rules.iter().map(|r| r.traffic_bytes).sum::<u64>());
    let mut rows = String::new();
    for r in &rules {
        let badge = if r.protocol == "TCP" { "tcp" } else { "udp" };
        let relay_entry = format!("{}:{}", if r.relay_host.is_empty() { "*" } else { r.relay_host.as_str() }, r.local_port);
        let quota_progress = if r.quota_bytes > 0 {
            let percent = std::cmp::min(100, r.traffic_bytes.saturating_mul(100) / r.quota_bytes);
            format!("<div class=\"quota-track\"><div class=\"quota-fill\" style=\"width:{}%\"></div></div>", percent)
        } else {
            String::new()
        };
        rows.push_str(&format!(
            "<tr><td data-label=\"协议\"><span class=\"pill {}\">{}</span></td><td data-label=\"中转入口\"><span class=\"port\">{}</span></td><td class=\"full\" data-label=\"目标地址\"><span class=\"pill\">{}:{}</span></td><td class=\"muted full\" data-label=\"备注\">{}</td><td class=\"traffic\" data-label=\"总流量\">{}{}</td><td class=\"expiry\" data-label=\"到期时间\">{}</td><td class=\"action\" data-label=\"操作\"><form method=\"post\" action=\"/delete\"><input type=\"hidden\" name=\"protocol\" value=\"{}\"><input type=\"hidden\" name=\"local_port\" value=\"{}\"><input type=\"hidden\" name=\"target_ip\" value=\"{}\"><input type=\"hidden\" name=\"target_port\" value=\"{}\"><input type=\"hidden\" name=\"remark\" value=\"{}\"><input type=\"hidden\" name=\"rule_comment\" value=\"{}\"><input type=\"hidden\" name=\"pre_handle\" value=\"{}\"><input type=\"hidden\" name=\"post_handle\" value=\"{}\"><button class=\"danger\" onclick=\"return confirm('确定删除这条规则?')\">删除</button></form></td></tr>",
            badge, html_escape(&r.protocol), html_escape(&relay_entry), html_escape(&r.target_ip), html_escape(&r.target_port),
            html_escape(&r.remark), html_escape(&r.traffic_text), quota_progress, html_escape(&r.expires_text), r.protocol.to_lowercase(), html_escape(&r.local_port), html_escape(&r.target_ip),
            html_escape(&r.target_port), html_escape(&r.remark), html_escape(&r.rule_comment), html_escape(&r.pre_handle), html_escape(&r.post_handle)
        ));
    }
    if rows.is_empty() {
        rows.push_str("<tr><td colspan=\"7\" class=\"empty\" style=\"text-align:center;color:#6b7685;padding:34px\">当前没有规则</td></tr>");
    }
    format!(
        r#"<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Forward Panel</title>{}</head><body class="theme-{}"><div class="top"><div class="brand"><span class="brand-mark">IP</span><span class="brand-name">流量中转管理面板</span><span class="backend">{}</span></div><div class="top-actions"><span class="state"><span class="state-dot"></span>服务在线</span><a class="btn ghost" href="/logout">退出</a></div></div><main class="wrap"><header class="page-head"><h1>端口转发控制台</h1><div class="runtime-line"><span class="runtime-chip">Rust + {}</span><span class="runtime-chip">内核转发</span></div></header>{}<div class="console"><aside class="card compose"><div class="head"><div class="head-group"><span>新建转发规则</span><span class="route-path">域名:端口 → 目标出口</span></div><span class="caption">DNAT</span></div><div class="body"><form method="post" action="/add" class="grid"><div class="field-protocol"><label>协议</label><select name="protocol"><option value="tcp">TCP</option><option value="udp">UDP</option><option value="all">TCP + UDP</option></select></div><div class="field-listener"><label>监听端口</label><input name="local_port" type="number" min="1" max="65535" required></div><div class="field-relay"><label>中转入口域名</label><input name="relay_host" placeholder="选填，如 relay.example.com" inputmode="url"></div><div class="field-target"><label>目标 IP / 域名</label><input name="target_ip" required></div><div class="field-target-port"><label>目标端口</label><input name="target_port" type="number" min="1" max="65535" required></div><div class="field-remark"><label>备注</label><input name="remark"></div><div class="field-quota"><label>流量上限 MB</label><input name="quota_mb" type="number" min="1"></div><div class="field-expiry"><label>到期时间 UTC+8</label><input name="expires_at" type="datetime-local"></div><div class="field-submit"><button class="primary">添加规则</button></div></form></div></aside><div class="control"><section class="metrics"><div class="metric"><div class="muted">总规则</div><div class="num">{}</div></div><div class="metric"><div class="muted">总流量</div><div class="num">{}</div></div><div class="metric"><div class="muted">TCP 规则</div><div class="num"><span class="proto-key">TCP</span>{}</div></div><div class="metric"><div class="muted">UDP 规则</div><div class="num"><span class="proto-key udp">UDP</span>{}</div></div></section><section class="card rules"><div class="head"><span>当前生效规则</span><span class="rule-count">{}</span></div><div class="table-wrap"><table><thead><tr><th>协议</th><th>中转入口</th><th>目标地址</th><th>备注</th><th>总流量<br><small>上行 + 下行</small></th><th>到期时间</th><th class="action">操作</th></tr></thead><tbody>{}</tbody></table></div></section></div></div></main></body></html>"#,
        style(),
        html_escape(&config.theme),
        html_escape(&config.backend),
        html_escape(&config.backend),
        if msg.is_empty() { String::new() } else { format!("<div class=\"msg\">{}</div>", html_escape(msg)) },
        rules.len(), total_traffic_text, tcp_count, udp_count, rules.len(),
        rows
    )
}

fn style() -> &'static str {
    concat!(
    "<style>body{margin:0;background:#f4f6f8;color:#172033;font-family:Inter,system-ui,-apple-system,BlinkMacSystemFont,\"Segoe UI\",sans-serif}.top{height:64px;border-bottom:1px solid #d9e0e8;background:#fff;display:flex;align-items:center;justify-content:space-between;padding:0 22px}.brand{font-weight:800}.wrap{max-width:1120px;margin:0 auto;padding:26px 18px 44px}.card{background:#fff;border:1px solid #d9e0e8;border-radius:8px;box-shadow:0 10px 26px rgba(23,32,51,.06);margin-top:18px;overflow:hidden}.head{padding:16px 18px;border-bottom:1px solid #d9e0e8;background:#fbfcfe;font-weight:750}.body{padding:18px}.grid{display:grid;grid-template-columns:repeat(5,minmax(0,1fr));gap:12px}label{display:block;color:#6b7685;font-weight:700;font-size:.86rem;margin-bottom:6px}input,select{width:100%;min-height:42px;border:1px solid #d9e0e8;border-radius:8px;padding:8px 10px;color:#172033}button,.btn{border:0;border-radius:8px;padding:10px 14px;font-weight:750;text-decoration:none;display:inline-block}.primary{background:#2563eb;color:#fff}.danger{background:#dc2626;color:#fff}.ghost{border:1px solid #d9e0e8;background:#fff;color:#172033}table{width:100%;border-collapse:collapse}th{background:#f7f9fb;color:#6b7685;text-align:left;font-size:.82rem;text-transform:uppercase}th,td{padding:13px 16px;border-bottom:1px solid #edf1f5}.pill{display:inline-block;border-radius:6px;padding:5px 8px;background:#111827;color:#fff;font-weight:750}.tcp{background:#2563eb}.udp{background:#7c3aed}.msg{padding:12px 14px;border-radius:8px;background:#eef6ff;color:#1d4ed8;margin-top:16px}.metrics{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:14px;margin-top:18px}.metric{background:#fff;border:1px solid #d9e0e8;border-radius:8px;padding:16px 18px}.num{font-size:1.8rem;font-weight:850}.muted{color:#6b7685}.theme-glass{background:linear-gradient(120deg,rgba(255,255,255,.2) 0 8%,transparent 8% 26%,rgba(125,211,252,.18) 26% 34%,transparent 34% 62%,rgba(216,180,254,.16) 62% 70%,transparent 70%),linear-gradient(150deg,#dff7ff,#f7fbff 34%,#d8f3ee 67%,#f4e9ff);color:#0b1b35;position:relative;overflow-x:hidden}.theme-glass:before{content:'';position:fixed;inset:-18%;pointer-events:none;background:linear-gradient(105deg,transparent 0 18%,rgba(255,255,255,.62) 19%,transparent 25% 48%,rgba(103,232,249,.22) 52%,transparent 59%),linear-gradient(62deg,transparent 0 24%,rgba(196,181,253,.24) 28%,transparent 36% 70%,rgba(255,255,255,.42) 74%,transparent 82%);filter:blur(22px) saturate(1.25);transform:rotate(-6deg);opacity:.88}.theme-glass .top,.theme-glass .wrap{position:relative;z-index:1}.theme-glass .top,.theme-glass .card,.theme-glass .metric{position:relative;background:linear-gradient(135deg,rgba(255,255,255,.72),rgba(255,255,255,.3) 42%,rgba(255,255,255,.55)),linear-gradient(120deg,rgba(125,211,252,.16),rgba(216,180,254,.14));border-color:rgba(255,255,255,.62);box-shadow:inset 0 1px 0 rgba(255,255,255,.92),inset 0 -20px 44px rgba(255,255,255,.24),0 24px 64px rgba(54,78,112,.18);backdrop-filter:blur(28px) saturate(1.65)}.theme-glass .top:before,.theme-glass .card:before,.theme-glass .metric:before{content:'';position:absolute;inset:1px;pointer-events:none;border-radius:inherit;background:linear-gradient(120deg,rgba(255,255,255,.82),transparent 24% 64%,rgba(255,255,255,.42)),linear-gradient(180deg,rgba(255,255,255,.22),transparent 46%);opacity:.7;mix-blend-mode:screen}.theme-glass .top>*,.theme-glass .card>*,.theme-glass .metric>*{position:relative;z-index:1}.theme-glass input,.theme-glass select{background:linear-gradient(180deg,rgba(255,255,255,.74),rgba(255,255,255,.38));border-color:rgba(255,255,255,.68);box-shadow:inset 0 1px 0 rgba(255,255,255,.88),inset 0 0 18px rgba(255,255,255,.32),0 10px 24px rgba(54,78,112,.12);backdrop-filter:blur(18px) saturate(1.45)}.theme-glass .brand:after{content:'C';margin-left:8px;color:#3157d5}.login{min-height:calc(100vh - 65px);display:grid;place-items:center;padding:18px}.login-card{width:min(100%,420px);background:#fff;border:1px solid #d9e0e8;border-radius:8px;padding:28px;box-shadow:0 10px 26px rgba(23,32,51,.06)}@media(max-width:850px){.grid,.metrics{grid-template-columns:1fr}.top{padding:0 14px}.wrap{padding:20px 14px 34px}table{min-width:760px}}</style>"
    ,
    r#"<style>*{box-sizing:border-box}body{min-height:100vh;color:#10233e;background:linear-gradient(118deg,transparent 0 14%,rgba(98,185,194,.1) 14% 23%,transparent 23% 62%,rgba(123,104,238,.08) 62% 72%,transparent 72%),#eaf0f4;letter-spacing:0}.top{position:sticky;top:0;z-index:20;height:auto;min-height:70px;padding:0 24px;gap:16px;border-bottom-color:rgba(115,132,151,.22);background:rgba(242,247,250,.78);box-shadow:0 8px 28px rgba(28,45,66,.06);backdrop-filter:blur(22px) saturate(1.35)}.brand{display:flex;align-items:center;gap:12px;min-width:0}.brand:after,.theme-glass .brand:after{display:none}.brand-mark{width:40px;height:40px;display:grid;place-items:center;flex:0 0 auto;border:1px solid rgba(255,255,255,.72);border-radius:8px;color:#fff;background:linear-gradient(145deg,#10233e,#285c68);box-shadow:inset 0 1px 0 rgba(255,255,255,.24),0 8px 20px rgba(16,35,62,.16)}.brand-name{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.backend{color:#637486;font-size:.78rem;text-transform:uppercase}.top-actions{display:flex;align-items:center;gap:12px}.state{display:inline-flex;align-items:center;gap:7px;color:#477177;font-size:.76rem}.state-dot{width:8px;height:8px;border-radius:50%;background:#18a46c;box-shadow:0 0 0 4px rgba(24,164,108,.12)}.wrap{max-width:1400px;padding:28px 24px 48px}.page-head{margin-bottom:22px}.page-head h1{margin:0;font-size:1.7rem}.page-head p{margin:6px 0 0;color:#6a798a;font-size:.84rem}.console{display:grid;grid-template-columns:minmax(300px,360px) minmax(0,1fr);align-items:start;gap:20px}.control{min-width:0;display:grid;gap:20px}.card,.metrics,.login-card{overflow:hidden;border:1px solid rgba(255,255,255,.74);border-radius:8px;background:linear-gradient(135deg,rgba(255,255,255,.7),rgba(255,255,255,.38));box-shadow:inset 0 1px 0 rgba(255,255,255,.94),0 18px 44px rgba(34,55,78,.11);backdrop-filter:blur(26px) saturate(1.4)}.card{margin-top:0}.compose{position:sticky;top:92px}.head{min-height:56px;padding:17px 20px;display:flex;align-items:center;justify-content:space-between;gap:12px;border-bottom-color:rgba(115,132,151,.16);background:rgba(255,255,255,.28)}.caption{color:#748293;font-size:.75rem}.body{padding:20px}.grid{grid-template-columns:repeat(2,minmax(0,1fr));gap:15px 12px}.wide{grid-column:1/-1}label{color:#586a7d;font-size:.79rem}input,select{min-height:44px;border-color:rgba(115,132,151,.26);background:rgba(255,255,255,.58)}button,.btn{min-height:38px;border:1px solid transparent;cursor:pointer}.primary{width:100%;min-height:46px;border-color:#176f7c;background:linear-gradient(135deg,#176f7c,#188b88);box-shadow:inset 0 1px 0 rgba(255,255,255,.24),0 12px 24px rgba(23,111,124,.18)}.ghost{border-color:rgba(115,132,151,.26);background:rgba(255,255,255,.48)}.danger{color:#b53746;border-color:rgba(201,74,88,.34);background:rgba(255,255,255,.42)}.metrics{grid-template-columns:1.1fr 1.4fr 1fr 1fr;gap:0;margin-top:0}.metric{min-width:0;padding:18px 20px;border:0;border-left:1px solid rgba(115,132,151,.14);border-radius:0;background:transparent}.metric:first-child{border-left:0}.metric .muted{font-size:.75rem;text-transform:uppercase}.num{margin-top:8px;color:#10233e;font-size:1.55rem;line-height:1.1}.proto-key{margin-right:8px;color:#168798;font-size:.72rem}.proto-key.udp{color:#7654b8}.rule-count{min-width:28px;height:26px;padding:0 8px;display:inline-grid;place-items:center;border-radius:6px;color:#176f7c;background:rgba(23,111,124,.09);font-size:.78rem}.table-wrap{overflow:auto}th,td{padding:14px;border-bottom-color:rgba(115,132,151,.12)}th{color:#6a798a;background:rgba(234,240,244,.42);font-size:.72rem}.pill{background:#10233e;font-size:.84rem;white-space:nowrap}.tcp{min-width:44px;text-align:center;background:#2262b7}.udp{min-width:44px;text-align:center;background:#7654b8}.port{font-weight:850}.traffic{color:#2f5660;font-weight:700;white-space:nowrap}.expiry{color:#657386;font-size:.83rem;white-space:nowrap}.action{text-align:right}.msg{margin:0 0 18px;border:1px solid rgba(22,135,152,.18);color:#176f7c;background:rgba(255,255,255,.48)}.login{min-height:calc(100vh - 70px);padding:20px}.login-card{padding:30px}.login-mark{width:48px;height:48px;margin:0 auto 16px;display:grid;place-items:center;border-radius:8px;color:#fff;background:linear-gradient(145deg,#10233e,#285c68);font-weight:850}.login-card h2{margin:0;text-align:center}.login-card p{margin:7px 0 22px;color:#6a798a;text-align:center;font-size:.86rem}.theme-glass{background:linear-gradient(118deg,transparent 0 12%,rgba(92,184,190,.18) 12% 21%,transparent 21% 58%,rgba(139,114,210,.12) 58% 69%,transparent 69%),linear-gradient(150deg,#dbeef1,#f4f7f8 46%,#e3eef0 74%,#eef0f7)}.theme-glass:before{inset:0;transform:none;filter:none;opacity:.82;background:linear-gradient(105deg,transparent 0 28%,rgba(255,255,255,.54) 28% 36%,transparent 36% 72%,rgba(114,202,198,.12) 72% 80%,transparent 80%)}.theme-glass .top,.theme-glass .card,.theme-glass .metrics,.theme-glass .login-card{background:linear-gradient(135deg,rgba(255,255,255,.7),rgba(255,255,255,.38));border-color:rgba(255,255,255,.74);box-shadow:inset 0 1px 0 rgba(255,255,255,.94),0 18px 44px rgba(34,55,78,.11);backdrop-filter:blur(26px) saturate(1.4)}.theme-glass .metrics:before{display:none}@media(max-width:1040px){.console{grid-template-columns:310px minmax(0,1fr)}.metrics{grid-template-columns:repeat(2,minmax(0,1fr))}.metric:nth-child(3){border-left:0}.metric:nth-child(n+3){border-top:1px solid rgba(115,132,151,.14)}}@media(max-width:820px){.top{min-height:62px;padding:0 14px}.brand-mark{width:36px;height:36px}.brand-name{max-width:46vw}.state{display:none}.wrap{padding:20px 14px 34px}.console{grid-template-columns:1fr}.control{grid-row:1}.compose{position:static;grid-row:2}.rules{order:2}table{min-width:0}thead{display:none}table,tbody,tr,td{display:block;width:100%}tbody{padding:10px}tbody tr{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));margin-bottom:10px;overflow:hidden;border:1px solid rgba(115,132,151,.16);border-radius:8px;background:rgba(255,255,255,.28)}tbody td{min-width:0;padding:11px 12px;border:0;border-bottom:1px solid rgba(115,132,151,.1)}tbody td:before{content:attr(data-label);display:block;margin-bottom:5px;color:#738193;font-size:.68rem;font-weight:750;text-transform:uppercase}.full,.action{grid-column:1/-1}.action{text-align:left}.action form,.action button{width:100%}.empty{grid-column:1/-1}.empty:before{display:none}}@media(max-width:460px){.page-head h1{font-size:1.4rem}.metric{padding:15px 14px}.num{font-size:1.3rem}.grid{grid-template-columns:1fr}.wide{grid-column:auto}}</style>"#
    ,
    r#"<style>@media(max-width:820px){.backend{display:none}.control{display:contents}.metrics{grid-row:1}.compose{grid-row:2}.rules{grid-row:3}}</style>"#,
    r#"<style>:root{--ink:#18201f;--muted:#65716f;--line:rgba(58,75,72,.16);--teal:#087f75;--teal-dark:#08645e;--violet:#6d4bc3;--red:#c63f4e}body.theme-glass{color:var(--ink);background:linear-gradient(122deg,transparent 0 18%,rgba(66,170,161,.11) 18% 31%,transparent 31% 67%,rgba(109,75,195,.08) 67% 77%,transparent 77%),#edf2f1}.theme-glass:before{background:linear-gradient(110deg,transparent 0 29%,rgba(255,255,255,.64) 29% 40%,transparent 40% 73%,rgba(107,205,197,.12) 73% 83%,transparent 83%);opacity:.78}.top{min-height:62px;color:#f7fbfa;border-bottom-color:rgba(255,255,255,.1);background:rgba(24,32,31,.92);box-shadow:0 8px 26px rgba(25,36,34,.12);backdrop-filter:blur(20px) saturate(1.25)}.brand-mark{width:36px;height:36px;background:var(--teal)}.backend{color:#b9cbc8}.state{color:#bde6df}.ghost{color:#f7fbfa;border-color:rgba(255,255,255,.25);background:rgba(255,255,255,.06)}.wrap{max-width:1460px;padding:28px 24px 48px}.page-head{margin-bottom:20px}.page-head h1{color:var(--ink);font-size:1.65rem}.runtime-line{display:flex;align-items:center;gap:8px;margin-top:9px;flex-wrap:wrap}.runtime-chip{min-height:26px;padding:4px 8px;border:1px solid var(--line);border-radius:6px;color:#485654;background:rgba(255,255,255,.46);font-size:.74rem;font-weight:750}.console{grid-template-columns:minmax(0,1fr);gap:16px}.compose{position:static}.control{display:grid;gap:16px}.card,.metrics,.login-card{border-color:rgba(255,255,255,.72);background:rgba(255,255,255,.64);box-shadow:inset 0 1px 0 rgba(255,255,255,.88),0 12px 34px rgba(35,52,49,.09);backdrop-filter:blur(24px) saturate(1.25)}.theme-glass .top:before,.theme-glass .card:before,.theme-glass .metric:before{display:none}.head{min-height:58px;padding:14px 18px;border-bottom-color:var(--line)}.head-group{display:flex;align-items:baseline;gap:10px;min-width:0}.route-path{color:var(--muted);font-size:.75rem;font-weight:650}.body{padding:16px 18px 18px}.grid{grid-template-columns:1.15fr .72fr 1.45fr .72fr 1fr .76fr 1.15fr 1.02fr;align-items:end;gap:12px}.grid>div,.wide{min-width:0;grid-column:auto}.grid label{color:#53615f;font-size:.78rem}input,select{border-color:rgba(58,75,72,.2);color:var(--ink);background:rgba(255,255,255,.66)}input:focus,select:focus{outline:0;border-color:var(--teal);box-shadow:0 0 0 3px rgba(8,127,117,.12)}.primary{min-height:44px;border-color:var(--teal);background:var(--teal);box-shadow:none}.metrics{grid-template-columns:1fr 1.25fr 1fr 1fr}.metric{padding:15px 18px;border-left-color:var(--line)}.metric .muted{color:var(--muted);font-size:.72rem}.num{margin-top:5px;color:var(--ink);font-size:1.35rem}.proto-key{color:var(--teal)}.proto-key.udp{color:var(--violet)}th{padding:11px 14px;color:var(--muted);background:rgba(226,234,232,.42)}td{padding:13px 14px;border-bottom-color:rgba(58,75,72,.1)}.pill{background:#24312f}.tcp{background:var(--teal)}.udp{background:var(--violet)}.danger{color:var(--red);border-color:rgba(198,63,78,.3)}.danger:hover{background:var(--red)}.quota-track{width:min(150px,100%);height:4px;margin-top:7px;overflow:hidden;border-radius:4px;background:rgba(58,75,72,.12)}.quota-fill{height:100%;border-radius:inherit;background:var(--teal)}@media(max-width:1260px){.grid{grid-template-columns:repeat(4,minmax(0,1fr))}.field-target,.field-remark,.field-submit{grid-column:span 2}}@media(max-width:820px){.wrap{padding-left:14px;padding-right:14px}.page-head h1{font-size:1.48rem}.console{display:grid}.control{display:grid;grid-row:auto}.compose,.metrics,.rules{grid-row:auto}.grid{grid-template-columns:repeat(2,minmax(0,1fr))}.field-target,.field-remark,.field-submit{grid-column:span 2}}@media(max-width:500px){.page-head h1{font-size:1.38rem}.metrics{grid-template-columns:repeat(2,minmax(0,1fr))}.metric:nth-child(3){border-left:0}.grid{grid-template-columns:1fr}.field-target,.field-remark,.field-submit{grid-column:auto}.route-path{display:none}}</style>"#
    ,
    r#"<style>.theme-glass .top{position:sticky;top:0}</style>"#,
    r#"<style>.grid{grid-template-columns:.9fr .65fr 1.35fr 1.35fr .65fr .9fr .7fr 1.1fr .95fr}.port{overflow-wrap:anywhere}@media(max-width:1260px){.grid{grid-template-columns:repeat(4,minmax(0,1fr))}.field-relay,.field-target,.field-remark,.field-submit{grid-column:span 2}}@media(max-width:820px){.grid{grid-template-columns:repeat(2,minmax(0,1fr))}.field-relay,.field-target,.field-remark,.field-submit{grid-column:span 2}}@media(max-width:500px){.grid{grid-template-columns:1fr}.field-relay,.field-target,.field-remark,.field-submit{grid-column:auto}}</style>"#
    )
}

fn login_page(error: &str) -> String {
    format!(r#"<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Panel Login</title>{}</head><body class="theme-glass"><div class="top"><div class="brand"><span class="brand-mark">IP</span><span class="brand-name">流量中转管理面板</span></div></div><main class="login"><div class="login-card"><div class="login-mark">IP</div><h2>中转面板登录</h2><p>流量中转管理面板</p>{}<form method="post" action="/login"><label>用户名</label><input name="username" autocomplete="username" required><label style="margin-top:12px">密码</label><input name="password" type="password" autocomplete="current-password" required><button class="primary" style="margin-top:18px">登录</button></form></div></main></body></html>"#, style(), if error.is_empty() { String::new() } else { format!("<div class=\"msg\">{}</div>", html_escape(error)) })
}

fn read_request(stream: &mut TcpStream) -> String {
    let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
    let mut buf = Vec::new();
    let mut tmp = [0_u8; 4096];
    loop {
        match stream.read(&mut tmp) {
            Ok(0) => break,
            Ok(n) => {
                buf.extend_from_slice(&tmp[..n]);
                if buf.len() > 65_536 {
                    break;
                }
                let req = String::from_utf8_lossy(&buf).to_string();
                if let Some(pos) = req.find("\r\n\r\n") {
                    let headers = &req[..pos];
                    let mut len = 0_usize;
                    for line in headers.lines() {
                        if line.to_lowercase().starts_with("content-length:") {
                            len = line[15..].trim().parse().unwrap_or(0);
                        }
                    }
                    if buf.len() >= pos + 4 + len {
                        break;
                    }
                }
            }
            Err(_) => break,
        }
    }
    String::from_utf8_lossy(&buf).to_string()
}

fn is_authed(headers: &str, token: &str) -> bool {
    headers.contains(&format!("session={}", token))
}

fn respond(stream: &mut TcpStream, status: &str, body: &str, headers: &[String]) {
    let mut response = format!("HTTP/1.1 {}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\n", status, body.as_bytes().len());
    for h in headers {
        response.push_str(h);
        response.push_str("\r\n");
    }
    response.push_str("\r\n");
    response.push_str(body);
    let _ = stream.write_all(response.as_bytes());
}

fn redirect(stream: &mut TcpStream, location: &str, headers: &[String]) {
    let body = "";
    let mut all = vec![format!("Location: {}", location)];
    all.extend_from_slice(headers);
    respond(stream, "302 Found", body, &all);
}

fn handle(mut stream: TcpStream, config: Config) {
    let req = read_request(&mut stream);
    let mut parts = req.splitn(2, "\r\n\r\n");
    let headers = parts.next().unwrap_or("");
    let body = parts.next().unwrap_or("");
    let first = headers.lines().next().unwrap_or("");
    let mut first_parts = first.split_whitespace();
    let method = first_parts.next().unwrap_or("");
    let path = first_parts.next().unwrap_or("/");
    let authed = is_authed(headers, &config.token);

    if path == "/login" && method == "POST" {
        let form = parse_form(body);
        if form.get("username") == Some(&config.user) && form.get("password") == Some(&config.password) {
            redirect(&mut stream, "/", &[format!("Set-Cookie: session={}; HttpOnly; Path=/", config.token)]);
        } else {
            respond(&mut stream, "200 OK", &login_page("用户名或密码错误"), &[]);
        }
        return;
    }

    if path == "/logout" {
        redirect(&mut stream, "/login", &[String::from("Set-Cookie: session=deleted; Max-Age=0; Path=/")]);
        return;
    }

    if !authed {
        if path == "/login" {
            respond(&mut stream, "200 OK", &login_page(""), &[]);
        } else {
            redirect(&mut stream, "/login", &[]);
        }
        return;
    }

    if path == "/add" && method == "POST" {
        let _rule_guard = match config.rule_lock.lock() {
            Ok(guard) => guard,
            Err(_) => {
                redirect(&mut stream, "/?msg=failed", &[]);
                return;
            }
        };
        let form = parse_form(body);
        let local_port = form.get("local_port").cloned().unwrap_or_default();
        let target_port = form.get("target_port").cloned().unwrap_or_default();
        let quota_bytes = match parse_quota_mb(form.get("quota_mb")) {
            Some(value) => value,
            None => {
                redirect(&mut stream, "/?msg=bad_quota", &[]);
                return;
            }
        };
        let expires_at = match parse_expires_at(form.get("expires_at")) {
            Some(value) => value,
            None => {
                redirect(&mut stream, "/?msg=bad_expires", &[]);
                return;
            }
        };
        let relay_host = match normalize_relay_host(form.get("relay_host")) {
            Some(value) => value,
            None => {
                redirect(&mut stream, "/?msg=bad_relay", &[]);
                return;
            }
        };
        if !valid_port(&local_port) || !valid_port(&target_port) {
            redirect(&mut stream, "/?msg=bad_port", &[]);
            return;
        }
        if local_port.parse::<u16>().ok() == Some(config.port) {
            redirect(&mut stream, "/?msg=panel_port", &[]);
            return;
        }
        let target_input = form.get("target_ip").cloned().unwrap_or_default();
        let resolved_target = resolve_target(&target_input);
        let target_ip = resolved_target.clone().unwrap_or_else(|| target_input.clone());
        let uses_domain = resolved_target.is_some() && target_ip != target_input;
        let selected = form.get("protocol").map(String::as_str).unwrap_or("tcp");
        let protos = if selected == "all" { vec!["tcp", "udp"] } else { vec![selected] };
        let current = list_rules(&config.backend);
        if current.iter().any(|r| r.local_port == local_port) {
            redirect(&mut stream, "/?msg=duplicate", &[]);
            return;
        }
        let mut limits = load_limits();
        let mut created_rules: Vec<(String, String)> = Vec::new();
        for proto in protos {
            let mut remark = form.get("remark").cloned().unwrap_or_default().replace('"', "").replace('\'', "").trim().to_string();
            if uses_domain {
                remark = format!("{} [{}]", remark, target_input).trim().to_string();
            }
            if add_rule(&config, proto, &local_port, &target_ip, &target_port, &remark).is_err() {
                let current_rules = list_rules(&config.backend);
                for (created_proto, created_remark) in &created_rules {
                    if let Some(rule) = current_rules.iter().find(|rule| rule.protocol.to_lowercase() == *created_proto && rule.local_port == local_port && rule.target_ip == target_ip && rule.target_port == target_port && rule.remark == *created_remark) {
                        let mut rollback_form = HashMap::new();
                        rollback_form.insert("protocol".to_string(), created_proto.clone());
                        rollback_form.insert("local_port".to_string(), local_port.clone());
                        rollback_form.insert("target_ip".to_string(), target_ip.clone());
                        rollback_form.insert("target_port".to_string(), target_port.clone());
                        rollback_form.insert("remark".to_string(), created_remark.clone());
                        rollback_form.insert("rule_comment".to_string(), rule.rule_comment.clone());
                        rollback_form.insert("pre_handle".to_string(), rule.pre_handle.clone());
                        rollback_form.insert("post_handle".to_string(), rule.post_handle.clone());
                        delete_rule(&config, &rollback_form);
                    }
                }
                redirect(&mut stream, "/?msg=failed", &[]);
                return;
            }
            created_rules.push((proto.to_string(), remark.clone()));
            if quota_bytes > 0 || !expires_at.is_empty() || uses_domain || !relay_host.is_empty() {
                limits.insert(track_id_for(proto, &local_port, &target_ip, &target_port, &remark), Limit {
                    quota_bytes,
                    expires_at: expires_at.clone(),
                    base_bytes: 0,
                    target_host: if uses_domain { target_input.clone() } else { String::new() },
                    relay_host: relay_host.clone(),
                });
            }
        }
        save_limits(&limits);
        redirect(&mut stream, "/?msg=added", &[]);
        return;
    }

    if path == "/delete" && method == "POST" {
        let _rule_guard = match config.rule_lock.lock() {
            Ok(guard) => guard,
            Err(_) => {
                redirect(&mut stream, "/?msg=failed", &[]);
                return;
            }
        };
        let form = parse_form(body);
        delete_rule(&config, &form);
        redirect(&mut stream, "/?msg=deleted", &[]);
        return;
    }

    let msg = if path.contains("msg=bad_port") { "端口必须是 1-65535" } else if path.contains("msg=bad_quota") { "流量上限必须是数字，单位 MB" } else if path.contains("msg=bad_expires") { "到期时间格式无效，请使用 UTC+8 时间" } else if path.contains("msg=bad_relay") { "中转入口域名无效或无法解析" } else if path.contains("msg=panel_port") { "监听端口已被面板服务占用" } else if path.contains("msg=duplicate") { "监听端口已被占用；如需 TCP + UDP，请一次选择双栈" } else if path.contains("msg=failed") { "操作失败" } else if path.contains("msg=added") { "添加成功" } else if path.contains("msg=deleted") { "删除完成" } else { "" };
    respond(&mut stream, "200 OK", &page(&config, msg), &[]);
}

fn main() {
    let args: Vec<String> = env::args().collect();
    let env_port = env::var("PANEL_PORT").unwrap_or_else(|_| "5000".to_string());
    let env_user = decode_hex_env("PANEL_USER_HEX", "admin");
    let env_password = decode_hex_env("PANEL_PASSWORD_HEX", "123456");
    let env_backend = env::var("PANEL_BACKEND").unwrap_or_else(|_| "iptables".to_string());
    let port = arg_value(&args, "--port", &env_port).parse::<u16>().unwrap_or(5000);
    let user = arg_value(&args, "--user", &env_user);
    let password = arg_value(&args, "--password", &env_password);
    let backend = arg_value(&args, "--backend", &env_backend);
    let theme = env::var("PANEL_THEME").unwrap_or_else(|_| "glass".to_string());
    let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_nanos();
    let token = format!("{}-{}", std::process::id(), now);
    let config = Config { port, user, password, backend, theme, token, rule_lock: Arc::new(Mutex::new(())) };

    shell_ok("sysctl", &["-w", "net.ipv4.ip_forward=1"]);
    if config.backend == "nftables" {
        setup_nftables();
    }
    let watcher_config = config.clone();
    thread::spawn(move || limit_watcher(watcher_config));

    let listener = TcpListener::bind(("0.0.0.0", config.port)).expect("failed to bind port");
    println!("panel running on 0.0.0.0:{}", config.port);
    let (sender, receiver) = mpsc::sync_channel::<TcpStream>(128);
    let receiver = Arc::new(Mutex::new(receiver));
    for _ in 0..4 {
        let worker_receiver = Arc::clone(&receiver);
        let worker_config = config.clone();
        thread::spawn(move || loop {
            let stream = match worker_receiver.lock() {
                Ok(queue) => match queue.recv() {
                    Ok(stream) => stream,
                    Err(_) => break,
                },
                Err(_) => break,
            };
            handle(stream, worker_config.clone());
        });
    }
    for stream in listener.incoming().flatten() {
        if sender.send(stream).is_err() {
            break;
        }
    }
}
RSEOF

  rustc --crate-name iptables_panel "$INSTALL_DIR/panel.rs.new" -O -o "$PANEL_BINARY.new"
  mv -f "$INSTALL_DIR/panel.rs.new" "$INSTALL_DIR/panel.rs"
  mv -f "$PANEL_BINARY.new" "$PANEL_BINARY"
}

write_service() {
  if [ "$PANEL_RUNTIME" = "python" ]; then
    EXEC_START="/usr/bin/python3 -m gunicorn --workers 1 --threads 4 --timeout 30 --bind 0.0.0.0:$PANEL_PORT panel:app"
  else
    EXEC_START="$PANEL_BINARY"
  fi

  mkdir -p "$CONFIG_DIR"
  chmod 700 "$CONFIG_DIR"
  PANEL_USER_HEX=$(hex_encode "$PANEL_USER")
  PANEL_PASSWORD_HEX=$(hex_encode "$PANEL_PASS")
  cat << EOF > "$CONFIG_FILE"
PANEL_CHANNEL=experimental
PANEL_RUNTIME=$PANEL_RUNTIME
PANEL_BACKEND=$FIREWALL_BACKEND
PANEL_THEME=$PANEL_THEME
PANEL_PORT=$PANEL_PORT
PANEL_USER_HEX=$PANEL_USER_HEX
PANEL_PASSWORD_HEX=$PANEL_PASSWORD_HEX
EOF
  chmod 600 "$CONFIG_FILE"

  cat << EOF > "$SERVICE_FILE"
[Unit]
Description=Multi Backend Traffic Forwarding Web Panel
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=$CONFIG_FILE
ExecStart=$EXEC_START
Restart=always
RestartSec=3
UMask=0077
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=$INSTALL_DIR

[Install]
WantedBy=multi-user.target
EOF
}

mkdir -p "$INSTALL_DIR"
prepare_rust_build_memory
install_common_deps

echo "📁 正在写入 $PANEL_RUNTIME 面板程序..."
if [ "$PANEL_RUNTIME" = "python" ]; then
  write_python_panel
else
  write_rust_panel
fi
cleanup_temp_swap

echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-iptables-panel.conf
sysctl -p /etc/sysctl.d/99-iptables-panel.conf > /dev/null 2>&1 || true

write_service
systemctl daemon-reload
systemctl enable iptables-panel > /dev/null 2>&1
systemctl restart iptables-panel
PANEL_HEALTHY=0
for _attempt in 1 2 3 4 5 6 7 8 9 10; do
  if systemctl is-active --quiet iptables-panel \
    && curl -fsS --max-time 2 "http://127.0.0.1:$PANEL_PORT/login" > /dev/null 2>&1; then
    PANEL_HEALTHY=1
    break
  fi
  sleep 1
done
if [ "$PANEL_HEALTHY" != "1" ]; then
  echo "❌ 面板服务启动失败，最近日志如下："
  journalctl -u iptables-panel -n 20 --no-pager
  exit 1
fi

echo "====================================================="
echo "✅ 安装/升级成功"
echo "组合: $PANEL_RUNTIME + $FIREWALL_BACKEND"
echo "UI theme: $PANEL_THEME"
echo "访问地址: http://你的服务器IP:$PANEL_PORT"
echo "账号: $PANEL_USER"
echo "密码: $PANEL_PASS"
echo "====================================================="
