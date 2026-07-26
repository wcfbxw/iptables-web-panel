#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
  echo "❌ 请使用 root 权限运行此脚本 (例如: sudo bash install-v2.sh)"
  exit 1
fi

INSTALL_DIR="/opt/iptables-panel"
SERVICE_FILE="/etc/systemd/system/iptables-panel.service"
PANEL_BINARY="$INSTALL_DIR/panel"

echo "====================================================="
echo "   🚀 Iptables/Nftables 多后端流量中转面板安装器"
echo "====================================================="
echo "可选组合:"
echo "1) Python + iptables"
echo "2) Python + nftables"
echo "3) Rust + iptables"
echo "4) Rust + nftables"
echo ""
read -p "请选择安装组合 [默认: 1]: " INSTALL_MODE
INSTALL_MODE=${INSTALL_MODE:-1}

case "$INSTALL_MODE" in
  2) PANEL_RUNTIME="python"; FIREWALL_BACKEND="nftables" ;;
  3) PANEL_RUNTIME="rust"; FIREWALL_BACKEND="iptables" ;;
  4) PANEL_RUNTIME="rust"; FIREWALL_BACKEND="nftables" ;;
  *) PANEL_RUNTIME="python"; FIREWALL_BACKEND="iptables" ;;
esac

read -p "👉 请设置面板运行端口 [默认: 5000]: " PANEL_PORT
PANEL_PORT=${PANEL_PORT:-5000}

read -p "👉 请设置管理员用户名 [默认: admin]: " PANEL_USER
PANEL_USER=${PANEL_USER:-admin}

read -p "👉 请设置管理员密码 [默认: 123456]: " PANEL_PASS
PANEL_PASS=${PANEL_PASS:-123456}

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
    pip3 install flask --break-system-packages > /dev/null 2>&1 || pip3 install flask > /dev/null 2>&1
  else
    apt-get install -y rustc > /dev/null 2>&1
  fi
}

write_python_panel() {
  cat << 'PYEOF' > "$INSTALL_DIR/panel.py"
import argparse
import datetime
import hashlib
import html
import os
import re
import socket
import subprocess
import threading
import time
from flask import Flask, redirect, render_template_string, request, session, url_for

parser = argparse.ArgumentParser()
parser.add_argument("--port", type=int, default=5000)
parser.add_argument("--user", default="admin")
parser.add_argument("--password", default="123456")
parser.add_argument("--backend", choices=("iptables", "nftables"), default="iptables")
parser.add_argument("--theme", default="map")
args = parser.parse_args()
PANEL_THEME = "glass"

app = Flask(__name__)
app.secret_key = os.urandom(24)
MARK = "iptables-panel"
LIMIT_FILE = "/opt/iptables-panel/limits.tsv"
TRACK_PREFIX = "iptables-panel-track:"

CSS = """
<style>
body{margin:0;background:#f4f6f8;color:#172033;font-family:Inter,system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
.top{height:64px;border-bottom:1px solid #d9e0e8;background:#fff;display:flex;align-items:center;justify-content:space-between;padding:0 22px}
.brand{font-weight:800}.wrap{max-width:1120px;margin:0 auto;padding:26px 18px 44px}.card{background:#fff;border:1px solid #d9e0e8;border-radius:8px;box-shadow:0 10px 26px rgba(23,32,51,.06);margin-top:18px;overflow:hidden}
.head{padding:16px 18px;border-bottom:1px solid #d9e0e8;background:#fbfcfe;font-weight:750}.body{padding:18px}.grid{display:grid;grid-template-columns:repeat(5,minmax(0,1fr));gap:12px}
label{display:block;color:#6b7685;font-weight:700;font-size:.86rem;margin-bottom:6px}input,select{width:100%;min-height:42px;border:1px solid #d9e0e8;border-radius:8px;padding:8px 10px;color:#172033}
button,.btn{border:0;border-radius:8px;padding:10px 14px;font-weight:750;text-decoration:none;display:inline-block}.primary{background:#2563eb;color:#fff}.danger{background:#dc2626;color:#fff}.ghost{border:1px solid #d9e0e8;background:#fff;color:#172033}
table{width:100%;border-collapse:collapse}th{background:#f7f9fb;color:#6b7685;text-align:left;font-size:.82rem;text-transform:uppercase}th,td{padding:13px 16px;border-bottom:1px solid #edf1f5}.pill{display:inline-block;border-radius:6px;padding:5px 8px;background:#111827;color:#fff;font-weight:750}.tcp{background:#2563eb}.udp{background:#7c3aed}.msg{padding:12px 14px;border-radius:8px;background:#eef6ff;color:#1d4ed8;margin-top:16px}
.metrics{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:14px}.metric{background:#fff;border:1px solid #d9e0e8;border-radius:8px;padding:16px 18px}.num{font-size:1.8rem;font-weight:850}.muted{color:#6b7685}
.login{min-height:calc(100vh - 65px);display:grid;place-items:center;padding:18px}.login-card{width:min(100%,420px);background:#fff;border:1px solid #d9e0e8;border-radius:8px;padding:28px;box-shadow:0 10px 26px rgba(23,32,51,.06)}
.theme-glass{background:linear-gradient(120deg,rgba(255,255,255,.2) 0 8%,transparent 8% 26%,rgba(125,211,252,.18) 26% 34%,transparent 34% 62%,rgba(216,180,254,.16) 62% 70%,transparent 70%),linear-gradient(150deg,#dff7ff,#f7fbff 34%,#d8f3ee 67%,#f4e9ff);color:#0b1b35;position:relative;overflow-x:hidden}.theme-glass:before{content:"";position:fixed;inset:-18%;pointer-events:none;background:linear-gradient(105deg,transparent 0 18%,rgba(255,255,255,.62) 19%,transparent 25% 48%,rgba(103,232,249,.22) 52%,transparent 59%),linear-gradient(62deg,transparent 0 24%,rgba(196,181,253,.24) 28%,transparent 36% 70%,rgba(255,255,255,.42) 74%,transparent 82%);filter:blur(22px) saturate(1.25);transform:rotate(-6deg);opacity:.88}.theme-glass .top,.theme-glass .wrap{position:relative;z-index:1}.theme-glass .top,.theme-glass .card,.theme-glass .metric,.theme-glass .glass-item{position:relative;background:linear-gradient(135deg,rgba(255,255,255,.72),rgba(255,255,255,.3) 42%,rgba(255,255,255,.55)),linear-gradient(120deg,rgba(125,211,252,.16),rgba(216,180,254,.14));border-color:rgba(255,255,255,.62);box-shadow:inset 0 1px 0 rgba(255,255,255,.92),inset 0 -20px 44px rgba(255,255,255,.24),0 24px 64px rgba(54,78,112,.18);backdrop-filter:blur(28px) saturate(1.65)}.theme-glass .top:before,.theme-glass .card:before,.theme-glass .metric:before,.theme-glass .glass-item:before{content:"";position:absolute;inset:1px;pointer-events:none;border-radius:inherit;background:linear-gradient(120deg,rgba(255,255,255,.82),transparent 24% 64%,rgba(255,255,255,.42)),linear-gradient(180deg,rgba(255,255,255,.22),transparent 46%);opacity:.7;mix-blend-mode:screen}.theme-glass .top>*,.theme-glass .card>*,.theme-glass .metric>*,.theme-glass .glass-item>*{position:relative;z-index:1}.theme-glass .head,.theme-glass th{background:rgba(255,255,255,.34)}.theme-glass input,.theme-glass select{background:linear-gradient(180deg,rgba(255,255,255,.74),rgba(255,255,255,.38));border-color:rgba(255,255,255,.68);box-shadow:inset 0 1px 0 rgba(255,255,255,.88),inset 0 0 18px rgba(255,255,255,.32),0 10px 24px rgba(54,78,112,.12);backdrop-filter:blur(18px) saturate(1.45)}.theme-glass .brand:after{content:"C";margin-left:8px;color:#3157d5}.glass-rail{display:grid;grid-template-columns:repeat(3,1fr);gap:14px;margin-top:18px}.glass-item{border:1px solid rgba(255,255,255,.62);border-radius:8px;padding:14px 16px}
@media(max-width:850px){.grid,.metrics{grid-template-columns:1fr}.top{padding:0 14px}.wrap{padding:20px 14px 34px}table{min-width:760px}}
@media(max-width:850px){.glass-rail{grid-template-columns:1fr}}
</style>
"""

LOGIN = """
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Panel Login</title>""" + CSS + """</head>
<body><div class="top"><div class="brand">IP Forward Panel</div></div><main class="login"><div class="login-card">
<h2 style="text-align:center;margin-top:0">中转面板登录</h2>{% if error %}<div class="msg">{{ error }}</div>{% endif %}
<form method="post" action="/login"><label>用户名</label><input name="username" autocomplete="username" required>
<label style="margin-top:12px">密码</label><input name="password" type="password" autocomplete="current-password" required>
<button class="primary" style="width:100%;margin-top:18px">登录</button></form></div></main></body></html>
"""

PAGE = """
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Forward Panel</title>""" + CSS + """</head>
<body class="theme-{{ theme }}"><div class="top"><div class="brand">IP Forward Panel · {{ backend }}</div><a class="btn ghost" href="/logout">退出</a></div>
<main class="wrap"><h1 style="margin:0">流量中转管理面板</h1>{% if msg %}<div class="msg">{{ msg }}</div>{% endif %}
<section class="metrics"><div class="metric"><div class="muted">总规则</div><div class="num">{{ rules|length }}</div></div><div class="metric"><div class="muted">总流量</div><div class="num">{{ total_traffic_text }}</div></div>
<div class="metric"><div class="muted">TCP</div><div class="num">{{ tcp_count }}</div></div><div class="metric"><div class="muted">UDP</div><div class="num">{{ udp_count }}</div></div></section>
<section class="glass-rail"><div class="glass-item"><span class="muted">Style</span><br><b>Liquid Glass C</b></div><div class="glass-item"><span class="muted">Traffic</span><br><b>Upload + Download</b></div><div class="glass-item"><span class="muted">Time</span><br><b>UTC+8</b></div></section>
<section class="card"><div class="head">新增端口转发</div><div class="body"><form method="post" action="/add" class="grid">
<div><label>协议</label><select name="protocol"><option value="tcp">TCP</option><option value="udp">UDP</option><option value="all">TCP + UDP</option></select></div>
<div><label>监听端口</label><input name="local_port" type="number" min="1" max="65535" required></div>
<div><label>目标 IP / 域名</label><input name="target_ip" required></div>
<div><label>目标端口</label><input name="target_port" type="number" min="1" max="65535" required></div>
<div><label>备注</label><input name="remark"></div><div><label>流量上限 MB</label><input name="quota_mb" type="number" min="1"></div>
<div><label>到期时间 UTC+8</label><input name="expires_at" type="datetime-local"></div><div style="grid-column:1/-1"><button class="primary" style="width:100%">添加规则</button></div>
</form></div></section>
<section class="card"><div class="head">当前规则</div><div style="overflow:auto"><table><thead><tr><th>协议</th><th>监听</th><th>转发至</th><th>备注</th><th>流量<br><small>上行 + 下行总和</small></th><th>到期时间</th><th style="text-align:right">操作</th></tr></thead><tbody>
{% for r in rules %}<tr><td><span class="pill {% if r.protocol == 'TCP' %}tcp{% else %}udp{% endif %}">{{ r.protocol }}</span></td><td><b>{{ r.local_port }}</b></td>
<td><span class="pill">{{ r.target_ip }}:{{ r.target_port }}</span></td><td class="muted">{{ r.remark or '-' }}</td><td class="muted">{{ r.traffic_text }}</td><td class="muted">{{ r.expires_text }}</td><td style="text-align:right">
<form method="post" action="/delete" style="display:inline"><input type="hidden" name="protocol" value="{{ r.protocol|lower }}"><input type="hidden" name="local_port" value="{{ r.local_port }}">
<input type="hidden" name="target_ip" value="{{ r.target_ip }}"><input type="hidden" name="target_port" value="{{ r.target_port }}"><input type="hidden" name="remark" value="{{ r.remark }}">
<input type="hidden" name="pre_handle" value="{{ r.pre_handle }}"><input type="hidden" name="post_handle" value="{{ r.post_handle }}"><button class="danger" onclick="return confirm('确定删除这条规则?')">删除</button></form></td></tr>
{% else %}<tr><td colspan="7" style="text-align:center;color:#6b7685;padding:34px">当前没有规则</td></tr>{% endfor %}
</tbody></table></div></section></main></body></html>
"""

def run(cmd, check=True):
    return subprocess.run(cmd, capture_output=True, text=True, check=check)

def valid_port(value):
    return value and value.isdigit() and 1 <= int(value) <= 65535

def normalize_target(value):
    return socket.gethostbyname(value.strip())

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

def tracking_comment(track_id):
    return TRACK_PREFIX + track_id

def load_limits():
    limits = {}
    try:
        with open(LIMIT_FILE, "r", encoding="utf-8") as limit_file:
            for line in limit_file:
                parts = line.rstrip("\n").split("\t")
                if len(parts) >= 3:
                    limits[parts[0]] = {"quota_bytes": int(parts[1] or 0), "expires_at": parts[2]}
    except Exception:
        pass
    return limits

def save_limits(limits):
    tmp_path = LIMIT_FILE + ".tmp"
    with open(tmp_path, "w", encoding="utf-8") as limit_file:
        for track_id, limit in limits.items():
            limit_file.write(f"{track_id}\t{int(limit.get('quota_bytes', 0) or 0)}\t{limit.get('expires_at', '')}\n")
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
            remark = visible_remark(remark_m.group(1) if remark_m else "")
            track_id = track_id_for(proto, local_port, target_ip, target_port, remark)
            limit = limits.get(track_id, {})
            quota_bytes = int(limit.get("quota_bytes", 0) or 0)
            used_bytes = traffic.get(track_id, 0)
            rules.append({
                "protocol": proto.upper(),
                "local_port": local_port,
                "target_ip": target_ip,
                "target_port": target_port,
                "remark": remark,
                "pre_handle": "",
                "post_handle": "",
                "track_id": track_id,
                "traffic_bytes": used_bytes,
                "quota_bytes": quota_bytes,
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
            remark = visible_remark(remark_m.group(1) if remark_m else "")
            track_id = track_id_for(proto, local_port, target_ip, target_port, remark)
            limit = limits.get(track_id, {})
            quota_bytes = int(limit.get("quota_bytes", 0) or 0)
            used_bytes = traffic.get(track_id, 0)
            rules.append({
                "protocol": proto.upper(),
                "local_port": local_port,
                "target_ip": target_ip,
                "target_port": target_port,
                "remark": remark,
                "pre_handle": handle_m.group(1),
                "post_handle": post_handles.get((proto, target_ip, target_port), ""),
                "track_id": track_id,
                "traffic_bytes": used_bytes,
                "quota_bytes": quota_bytes,
                "traffic_text": f"{format_bytes(used_bytes)} / {format_bytes(quota_bytes) if quota_bytes else '不限'}",
                "expires_at": limit.get("expires_at", ""),
                "expires_text": format_expires(limit.get("expires_at", "")),
            })
    return rules

def list_rules():
    return list_nftables_rules() if args.backend == "nftables" else list_iptables_rules()

def add_rule(proto, local_port, target_ip, target_port, remark):
    comment = comment_for(remark)
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

def delete_rule(form):
    proto = form["protocol"]
    local_port = form["local_port"]
    target_ip = form["target_ip"]
    target_port = form["target_port"]
    remark = form.get("remark", "")
    track_id = track_id_for(proto, local_port, target_ip, target_port, remark)
    if args.backend == "nftables" and form.get("pre_handle"):
        run(["nft", "delete", "rule", "ip", "iptables_panel", "prerouting", "handle", form["pre_handle"]], check=False)
        if form.get("post_handle"):
            run(["nft", "delete", "rule", "ip", "iptables_panel", "postrouting", "handle", form["post_handle"]], check=False)
        delete_tracking_rules(proto, target_ip, target_port, track_id)
        limits = load_limits()
        limits.pop(track_id, None)
        save_limits(limits)
        return

    comment = comment_for(form.get("remark", ""))
    pre = ["iptables", "-t", "nat", "-D", "PREROUTING", "-p", proto, "--dport", local_port, "-m", "comment", "--comment", comment, "-j", "DNAT", "--to-destination", f"{target_ip}:{target_port}"]
    post = ["iptables", "-t", "nat", "-D", "POSTROUTING", "-p", proto, "-d", target_ip, "--dport", target_port, "-m", "comment", "--comment", comment, "-j", "MASQUERADE"]
    run(pre, check=False)
    run(post, check=False)
    delete_tracking_rules(proto, target_ip, target_port, track_id)
    limits = load_limits()
    limits.pop(track_id, None)
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
                "pre_handle": rule.get("pre_handle", ""),
                "post_handle": rule.get("post_handle", ""),
            })
            changed = True
    if changed:
        save_limits(load_limits())

def limit_watcher():
    while True:
        try:
            enforce_limits_once()
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
def add():
    if not require_login():
        return redirect(url_for("login"))
    local_port = request.form.get("local_port", "")
    target_port = request.form.get("target_port", "")
    quota_bytes = parse_quota_mb(request.form.get("quota_mb"))
    expires_at = parse_expires_at(request.form.get("expires_at"))
    if not valid_port(local_port) or not valid_port(target_port):
        return redirect(url_for("index", msg="端口必须是 1-65535"))
    if quota_bytes is None:
        return redirect(url_for("index", msg="流量上限必须是数字，单位 MB"))
    if expires_at is None:
        return redirect(url_for("index", msg="到期时间格式无效，请使用 UTC+8 时间"))
    try:
        target_ip = normalize_target(request.form.get("target_ip", ""))
    except Exception:
        return redirect(url_for("index", msg="目标 IP 或域名无效"))
    protos = ["tcp", "udp"] if request.form.get("protocol") == "all" else [request.form.get("protocol", "tcp")]
    current = list_rules()
    for proto in protos:
        if any(r["protocol"].lower() == proto and r["local_port"] == local_port and r["target_ip"] == target_ip and r["target_port"] == target_port for r in current):
            return redirect(url_for("index", msg="规则已存在"))
    try:
        limits = load_limits()
        for proto in protos:
            remark = request.form.get("remark", "")
            add_rule(proto, local_port, target_ip, target_port, remark)
            if quota_bytes or expires_at:
                limits[track_id_for(proto, local_port, target_ip, target_port, remark)] = {
                    "quota_bytes": quota_bytes,
                    "expires_at": expires_at,
                }
        save_limits(limits)
        return redirect(url_for("index", msg="添加成功"))
    except Exception as exc:
        return redirect(url_for("index", msg=f"添加失败: {html.escape(str(exc))[:300]}"))

@app.route("/delete", methods=["POST"])
def delete():
    if not require_login():
        return redirect(url_for("login"))
    delete_rule(request.form)
    return redirect(url_for("index", msg="删除完成"))

if __name__ == "__main__":
    subprocess.run(["sysctl", "-w", "net.ipv4.ip_forward=1"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if args.backend == "nftables":
        setup_nftables()
    threading.Thread(target=limit_watcher, daemon=True).start()
    app.run(host="0.0.0.0", port=args.port)
PYEOF
}

write_rust_panel() {
  cat << 'RSEOF' > "$INSTALL_DIR/panel.rs"
use std::collections::HashMap;
use std::env;
use std::fs;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::process::Command;
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
}

#[derive(Clone, Default)]
struct Rule {
    protocol: String,
    local_port: String,
    target_ip: String,
    target_port: String,
    remark: String,
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
    let mut hash: u64 = 0xcbf29ce484222325;
    for byte in raw.as_bytes() {
        hash ^= *byte as u64;
        hash = hash.wrapping_mul(0x100000001b3);
    }
    format!("{:016x}", hash)
}

fn tracking_comment(track_id: &str) -> String {
    format!("iptables-panel-track:{}", track_id)
}

#[derive(Clone, Default)]
struct Limit {
    quota_bytes: u64,
    expires_at: String,
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
                });
            }
        }
    }
    limits
}

fn save_limits(limits: &HashMap<String, Limit>) {
    let mut content = String::new();
    for (track_id, limit) in limits {
        content.push_str(&format!("{}\t{}\t{}\n", track_id, limit.quota_bytes, limit.expires_at));
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

fn add_tracking_rules(config: &Config, proto: &str, target_ip: &str, target_port: &str, track_id: &str) {
    let comment = tracking_comment(track_id);
    if config.backend == "nftables" {
        setup_nftables();
        let target = format!("{}:{}", target_ip, target_port);
        let _ = target;
        shell_ok("nft", &["add", "rule", "ip", "iptables_panel", "forward", "meta", "l4proto", proto, "ip", "daddr", target_ip, "th", "dport", target_port, "counter", "comment", &comment]);
        shell_ok("nft", &["add", "rule", "ip", "iptables_panel", "forward", "meta", "l4proto", proto, "ip", "saddr", target_ip, "th", "sport", target_port, "counter", "comment", &comment]);
    } else {
        shell_ok("iptables", &["-A", "FORWARD", "-p", proto, "-d", target_ip, "--dport", target_port, "-m", "comment", "--comment", &comment, "-j", "ACCEPT"]);
        shell_ok("iptables", &["-A", "FORWARD", "-p", proto, "-s", target_ip, "--sport", target_port, "-m", "comment", "--comment", &comment, "-j", "ACCEPT"]);
    }
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
        let track_id = track_id_for(protocol, &local_port, &target_ip, &target_port, &remark);
        let used = usage.get(&track_id).copied().unwrap_or(0);
        let limit = limits.get(&track_id).cloned().unwrap_or_default();
        rules.push(Rule {
            protocol: protocol.to_string(),
            local_port,
            target_ip,
            target_port,
            remark,
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
        let track_id = track_id_for(proto, local_port, &target_ip, &target_port, &remark);
        let used = usage.get(&track_id).copied().unwrap_or(0);
        let limit = limits.get(&track_id).cloned().unwrap_or_default();
        rules.push(Rule {
            protocol: proto.to_uppercase(),
            local_port: local_port.to_string(),
            target_ip,
            target_port,
            remark,
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
    if config.backend == "nftables" {
        setup_nftables();
        shell("nft", &["add", "rule", "ip", "iptables_panel", "prerouting", "meta", "l4proto", proto, "th", "dport", local_port, "dnat", "to", &format!("{}:{}", target_ip, target_port), "comment", &comment])?;
        shell("nft", &["add", "rule", "ip", "iptables_panel", "postrouting", "ip", "daddr", target_ip, "meta", "l4proto", proto, "th", "dport", target_port, "masquerade", "comment", &comment])?;
    } else {
        shell("iptables", &["-t", "nat", "-A", "PREROUTING", "-p", proto, "--dport", local_port, "-m", "comment", "--comment", &comment, "-j", "DNAT", "--to-destination", &format!("{}:{}", target_ip, target_port)])?;
        shell("iptables", &["-t", "nat", "-A", "POSTROUTING", "-p", proto, "-d", target_ip, "--dport", target_port, "-m", "comment", "--comment", &comment, "-j", "MASQUERADE"])?;
    }
    let track_id = track_id_for(proto, local_port, target_ip, target_port, remark);
    add_tracking_rules(config, proto, target_ip, target_port, &track_id);
    Ok(())
}

fn delete_rule(config: &Config, form: &HashMap<String, String>) {
    let proto = form.get("protocol").map(String::as_str).unwrap_or("tcp");
    let local_port = form.get("local_port").map(String::as_str).unwrap_or("");
    let target_ip = form.get("target_ip").map(String::as_str).unwrap_or("");
    let target_port = form.get("target_port").map(String::as_str).unwrap_or("");
    let remark = form.get("remark").map(String::as_str).unwrap_or("");
    let track_id = track_id_for(proto, local_port, target_ip, target_port, remark);
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
        let mut limits = load_limits();
        limits.remove(&track_id);
        save_limits(&limits);
        return;
    }

    let comment = comment_for(remark);
    shell_ok("iptables", &["-t", "nat", "-D", "PREROUTING", "-p", proto, "--dport", local_port, "-m", "comment", "--comment", &comment, "-j", "DNAT", "--to-destination", &format!("{}:{}", target_ip, target_port)]);
    shell_ok("iptables", &["-t", "nat", "-D", "POSTROUTING", "-p", proto, "-d", target_ip, "--dport", target_port, "-m", "comment", "--comment", &comment, "-j", "MASQUERADE"]);
    delete_tracking_rules(config, proto, target_ip, target_port, &track_id);
    let mut limits = load_limits();
    limits.remove(&track_id);
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
                form.insert("pre_handle".to_string(), rule.pre_handle.clone());
                form.insert("post_handle".to_string(), rule.post_handle.clone());
                delete_rule(config, &form);
            }
        }
    }
}

fn limit_watcher(config: Config) {
    loop {
        enforce_limits_once(&config);
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
        rows.push_str(&format!(
            "<tr><td><span class=\"pill {}\">{}</span></td><td><b>{}</b></td><td><span class=\"pill\">{}:{}</span></td><td class=\"muted\">{}</td><td class=\"muted\">{}</td><td class=\"muted\">{}</td><td style=\"text-align:right\"><form method=\"post\" action=\"/delete\"><input type=\"hidden\" name=\"protocol\" value=\"{}\"><input type=\"hidden\" name=\"local_port\" value=\"{}\"><input type=\"hidden\" name=\"target_ip\" value=\"{}\"><input type=\"hidden\" name=\"target_port\" value=\"{}\"><input type=\"hidden\" name=\"remark\" value=\"{}\"><input type=\"hidden\" name=\"pre_handle\" value=\"{}\"><input type=\"hidden\" name=\"post_handle\" value=\"{}\"><button class=\"danger\" onclick=\"return confirm('确定删除这条规则?')\">删除</button></form></td></tr>",
            badge, html_escape(&r.protocol), html_escape(&r.local_port), html_escape(&r.target_ip), html_escape(&r.target_port),
            html_escape(&r.remark), html_escape(&r.traffic_text), html_escape(&r.expires_text), r.protocol.to_lowercase(), html_escape(&r.local_port), html_escape(&r.target_ip),
            html_escape(&r.target_port), html_escape(&r.remark), html_escape(&r.pre_handle), html_escape(&r.post_handle)
        ));
    }
    if rows.is_empty() {
        rows.push_str("<tr><td colspan=\"7\" style=\"text-align:center;color:#6b7685;padding:34px\">当前没有规则</td></tr>");
    }
    format!(
        "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>Forward Panel</title>{}</head><body class=\"theme-{}\"><div class=\"top\"><div class=\"brand\">IP Forward Panel · {}</div><a class=\"btn ghost\" href=\"/logout\">退出</a></div><main class=\"wrap\"><h1 style=\"margin:0\">流量中转管理面板</h1>{}<section class=\"metrics\"><div class=\"metric\"><div class=\"muted\">总规则</div><div class=\"num\">{}</div></div><div class=\"metric\"><div class=\"muted\">总流量</div><div class=\"num\">{}</div></div><div class=\"metric\"><div class=\"muted\">TCP</div><div class=\"num\">{}</div></div><div class=\"metric\"><div class=\"muted\">UDP</div><div class=\"num\">{}</div></div></section><section class=\"theme-note\"><b>{}</b><span>{}</span></section><section class=\"card\"><div class=\"head\">新增端口转发</div><div class=\"body\"><form method=\"post\" action=\"/add\" class=\"grid\"><div><label>协议</label><select name=\"protocol\"><option value=\"tcp\">TCP</option><option value=\"udp\">UDP</option><option value=\"all\">TCP + UDP</option></select></div><div><label>监听端口</label><input name=\"local_port\" type=\"number\" min=\"1\" max=\"65535\" required></div><div><label>目标 IP / 域名</label><input name=\"target_ip\" required></div><div><label>目标端口</label><input name=\"target_port\" type=\"number\" min=\"1\" max=\"65535\" required></div><div><label>备注</label><input name=\"remark\"></div><div><label>流量上限 MB</label><input name=\"quota_mb\" type=\"number\" min=\"1\"></div><div><label>到期时间 UTC+8</label><input name=\"expires_at\" type=\"datetime-local\"></div><div style=\"grid-column:1/-1\"><button class=\"primary\" style=\"width:100%\">添加规则</button></div></form></div></section><section class=\"card\"><div class=\"head\">当前规则</div><div style=\"overflow:auto\"><table><thead><tr><th>协议</th><th>监听</th><th>转发至</th><th>备注</th><th>流量<br><small>上行 + 下行总和</small></th><th>到期时间</th><th style=\"text-align:right\">操作</th></tr></thead><tbody>{}</tbody></table></div></section></main></body></html>",
        style(),
        html_escape(&config.theme),
        html_escape(&config.backend),
        if msg.is_empty() { String::new() } else { format!("<div class=\"msg\">{}</div>", html_escape(msg)) },
        rules.len(), total_traffic_text, tcp_count, udp_count,
        "Liquid Glass C",
        "Liquid glass layout with traffic quota and UTC+8 expiration.",
        rows
    )
}

fn style() -> &'static str {
    "<style>body{margin:0;background:#f4f6f8;color:#172033;font-family:Inter,system-ui,-apple-system,BlinkMacSystemFont,\"Segoe UI\",sans-serif}.top{height:64px;border-bottom:1px solid #d9e0e8;background:#fff;display:flex;align-items:center;justify-content:space-between;padding:0 22px}.brand{font-weight:800}.wrap{max-width:1120px;margin:0 auto;padding:26px 18px 44px}.card{background:#fff;border:1px solid #d9e0e8;border-radius:8px;box-shadow:0 10px 26px rgba(23,32,51,.06);margin-top:18px;overflow:hidden}.head{padding:16px 18px;border-bottom:1px solid #d9e0e8;background:#fbfcfe;font-weight:750}.body{padding:18px}.grid{display:grid;grid-template-columns:repeat(5,minmax(0,1fr));gap:12px}label{display:block;color:#6b7685;font-weight:700;font-size:.86rem;margin-bottom:6px}input,select{width:100%;min-height:42px;border:1px solid #d9e0e8;border-radius:8px;padding:8px 10px;color:#172033}button,.btn{border:0;border-radius:8px;padding:10px 14px;font-weight:750;text-decoration:none;display:inline-block}.primary{background:#2563eb;color:#fff}.danger{background:#dc2626;color:#fff}.ghost{border:1px solid #d9e0e8;background:#fff;color:#172033}table{width:100%;border-collapse:collapse}th{background:#f7f9fb;color:#6b7685;text-align:left;font-size:.82rem;text-transform:uppercase}th,td{padding:13px 16px;border-bottom:1px solid #edf1f5}.pill{display:inline-block;border-radius:6px;padding:5px 8px;background:#111827;color:#fff;font-weight:750}.tcp{background:#2563eb}.udp{background:#7c3aed}.msg{padding:12px 14px;border-radius:8px;background:#eef6ff;color:#1d4ed8;margin-top:16px}.metrics{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:14px;margin-top:18px}.metric{background:#fff;border:1px solid #d9e0e8;border-radius:8px;padding:16px 18px}.num{font-size:1.8rem;font-weight:850}.muted{color:#6b7685}.theme-note{margin-top:18px;border:1px solid #d9e0e8;border-radius:8px;background:#fff;padding:14px 16px;display:flex;justify-content:space-between;gap:12px}.theme-glass{background:linear-gradient(120deg,rgba(255,255,255,.2) 0 8%,transparent 8% 26%,rgba(125,211,252,.18) 26% 34%,transparent 34% 62%,rgba(216,180,254,.16) 62% 70%,transparent 70%),linear-gradient(150deg,#dff7ff,#f7fbff 34%,#d8f3ee 67%,#f4e9ff);color:#0b1b35;position:relative;overflow-x:hidden}.theme-glass:before{content:'';position:fixed;inset:-18%;pointer-events:none;background:linear-gradient(105deg,transparent 0 18%,rgba(255,255,255,.62) 19%,transparent 25% 48%,rgba(103,232,249,.22) 52%,transparent 59%),linear-gradient(62deg,transparent 0 24%,rgba(196,181,253,.24) 28%,transparent 36% 70%,rgba(255,255,255,.42) 74%,transparent 82%);filter:blur(22px) saturate(1.25);transform:rotate(-6deg);opacity:.88}.theme-glass .top,.theme-glass .wrap{position:relative;z-index:1}.theme-glass .top,.theme-glass .card,.theme-glass .metric,.theme-glass .theme-note{position:relative;background:linear-gradient(135deg,rgba(255,255,255,.72),rgba(255,255,255,.3) 42%,rgba(255,255,255,.55)),linear-gradient(120deg,rgba(125,211,252,.16),rgba(216,180,254,.14));border-color:rgba(255,255,255,.62);box-shadow:inset 0 1px 0 rgba(255,255,255,.92),inset 0 -20px 44px rgba(255,255,255,.24),0 24px 64px rgba(54,78,112,.18);backdrop-filter:blur(28px) saturate(1.65)}.theme-glass .top:before,.theme-glass .card:before,.theme-glass .metric:before,.theme-glass .theme-note:before{content:'';position:absolute;inset:1px;pointer-events:none;border-radius:inherit;background:linear-gradient(120deg,rgba(255,255,255,.82),transparent 24% 64%,rgba(255,255,255,.42)),linear-gradient(180deg,rgba(255,255,255,.22),transparent 46%);opacity:.7;mix-blend-mode:screen}.theme-glass .top>*,.theme-glass .card>*,.theme-glass .metric>*,.theme-glass .theme-note>*{position:relative;z-index:1}.theme-glass input,.theme-glass select{background:linear-gradient(180deg,rgba(255,255,255,.74),rgba(255,255,255,.38));border-color:rgba(255,255,255,.68);box-shadow:inset 0 1px 0 rgba(255,255,255,.88),inset 0 0 18px rgba(255,255,255,.32),0 10px 24px rgba(54,78,112,.12);backdrop-filter:blur(18px) saturate(1.45)}.theme-glass .brand:after{content:'C';margin-left:8px;color:#3157d5}.login{min-height:calc(100vh - 65px);display:grid;place-items:center;padding:18px}.login-card{width:min(100%,420px);background:#fff;border:1px solid #d9e0e8;border-radius:8px;padding:28px;box-shadow:0 10px 26px rgba(23,32,51,.06)}@media(max-width:850px){.grid,.metrics{grid-template-columns:1fr}.top{padding:0 14px}.wrap{padding:20px 14px 34px}table{min-width:760px}.theme-note{display:block}}</style>"
}

fn login_page(error: &str) -> String {
    format!("<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>Panel Login</title>{}</head><body><div class=\"top\"><div class=\"brand\">IP Forward Panel</div></div><main class=\"login\"><div class=\"login-card\"><h2 style=\"text-align:center;margin-top:0\">中转面板登录</h2>{}<form method=\"post\" action=\"/login\"><label>用户名</label><input name=\"username\" autocomplete=\"username\" required><label style=\"margin-top:12px\">密码</label><input name=\"password\" type=\"password\" autocomplete=\"current-password\" required><button class=\"primary\" style=\"width:100%;margin-top:18px\">登录</button></form></div></main></body></html>", style(), if error.is_empty() { String::new() } else { format!("<div class=\"msg\">{}</div>", html_escape(error)) })
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
        if !valid_port(&local_port) || !valid_port(&target_port) {
            redirect(&mut stream, "/?msg=bad_port", &[]);
            return;
        }
        let target_input = form.get("target_ip").cloned().unwrap_or_default();
        let target_ip = shell("getent", &["hosts", &target_input])
            .ok()
            .and_then(|out| out.split_whitespace().next().map(str::to_string))
            .unwrap_or(target_input);
        let selected = form.get("protocol").map(String::as_str).unwrap_or("tcp");
        let protos = if selected == "all" { vec!["tcp", "udp"] } else { vec![selected] };
        let current = list_rules(&config.backend);
        for proto in &protos {
            if current.iter().any(|r| r.protocol.to_lowercase() == *proto && r.local_port == local_port && r.target_ip == target_ip && r.target_port == target_port) {
                redirect(&mut stream, "/?msg=duplicate", &[]);
                return;
            }
        }
        let mut limits = load_limits();
        for proto in protos {
            let remark = form.get("remark").map(String::as_str).unwrap_or("");
            if add_rule(&config, proto, &local_port, &target_ip, &target_port, remark).is_err() {
                redirect(&mut stream, "/?msg=failed", &[]);
                return;
            }
            if quota_bytes > 0 || !expires_at.is_empty() {
                limits.insert(track_id_for(proto, &local_port, &target_ip, &target_port, remark), Limit {
                    quota_bytes,
                    expires_at: expires_at.clone(),
                });
            }
        }
        save_limits(&limits);
        redirect(&mut stream, "/?msg=added", &[]);
        return;
    }

    if path == "/delete" && method == "POST" {
        let form = parse_form(body);
        delete_rule(&config, &form);
        redirect(&mut stream, "/?msg=deleted", &[]);
        return;
    }

    let msg = if path.contains("msg=bad_port") { "端口必须是 1-65535" } else if path.contains("msg=bad_quota") { "流量上限必须是数字，单位 MB" } else if path.contains("msg=bad_expires") { "到期时间格式无效，请使用 UTC+8 时间" } else if path.contains("msg=duplicate") { "规则已存在" } else if path.contains("msg=failed") { "操作失败" } else if path.contains("msg=added") { "添加成功" } else if path.contains("msg=deleted") { "删除完成" } else { "" };
    respond(&mut stream, "200 OK", &page(&config, msg), &[]);
}

fn main() {
    let args: Vec<String> = env::args().collect();
    let port = arg_value(&args, "--port", "5000").parse::<u16>().unwrap_or(5000);
    let user = arg_value(&args, "--user", "admin");
    let password = arg_value(&args, "--password", "123456");
    let backend = arg_value(&args, "--backend", "iptables");
    let theme = "glass".to_string();
    let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_nanos();
    let token = format!("{}-{}", std::process::id(), now);
    let config = Config { port, user, password, backend, theme, token };

    shell_ok("sysctl", &["-w", "net.ipv4.ip_forward=1"]);
    if config.backend == "nftables" {
        setup_nftables();
    }
    let watcher_config = config.clone();
    thread::spawn(move || limit_watcher(watcher_config));

    let listener = TcpListener::bind(("0.0.0.0", config.port)).expect("failed to bind port");
    println!("panel running on 0.0.0.0:{}", config.port);
    for stream in listener.incoming().flatten() {
        handle(stream, config.clone());
    }
}
RSEOF

  rustc "$INSTALL_DIR/panel.rs" -O -o "$PANEL_BINARY"
}

write_service() {
  if [ "$PANEL_RUNTIME" = "python" ]; then
    EXEC_START="/usr/bin/python3 $INSTALL_DIR/panel.py --port $PANEL_PORT --user $PANEL_USER --password $PANEL_PASS --backend $FIREWALL_BACKEND --theme $PANEL_THEME"
  else
    EXEC_START="$PANEL_BINARY --port $PANEL_PORT --user $PANEL_USER --password $PANEL_PASS --backend $FIREWALL_BACKEND --theme $PANEL_THEME"
  fi

  cat << EOF > "$SERVICE_FILE"
[Unit]
Description=Multi Backend Traffic Forwarding Web Panel
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=$EXEC_START
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
}

mkdir -p "$INSTALL_DIR"
install_common_deps

echo "📁 正在写入 $PANEL_RUNTIME 面板程序..."
if [ "$PANEL_RUNTIME" = "python" ]; then
  write_python_panel
else
  write_rust_panel
fi

echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-iptables-panel.conf
sysctl -p /etc/sysctl.d/99-iptables-panel.conf > /dev/null 2>&1 || true

write_service
systemctl daemon-reload
systemctl enable iptables-panel > /dev/null 2>&1
systemctl restart iptables-panel

echo "====================================================="
echo "✅ 安装/升级成功"
echo "组合: $PANEL_RUNTIME + $FIREWALL_BACKEND"
echo "UI theme: $PANEL_THEME"
echo "访问地址: http://你的服务器IP:$PANEL_PORT"
echo "账号: $PANEL_USER"
echo "密码: $PANEL_PASS"
echo "====================================================="
