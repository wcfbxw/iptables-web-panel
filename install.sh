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

echo ""
echo "⏳ 正在安装依赖环境 (Python3 & Flask)..."
apt-get update -y > /dev/null 2>&1
apt-get install -y python3 python3-pip iptables > /dev/null 2>&1
pip3 install flask --break-system-packages > /dev/null 2>&1 || pip3 install flask > /dev/null 2>&1

echo "📁 正在配置程序文件..."
mkdir -p $INSTALL_DIR

# 写入支持双语、备注和域名的 panel.py
cat << 'EOF' > $INSTALL_DIR/panel.py
import subprocess, ipaddress, os, argparse, re, socket
from flask import Flask, request, render_template_string, session, redirect, url_for

parser = argparse.ArgumentParser()
parser.add_argument('--port', type=int, default=5000)
parser.add_argument('--user', type=str, default='admin')
parser.add_argument('--password', type=str, default='123456')
args = parser.parse_args()

ADMIN_USER, ADMIN_PASS, PANEL_PORT = args.user, args.password, args.port
app = Flask(__name__)
app.secret_key = os.urandom(24)

# --- 双语字典 (加入备注字段和域名提示) ---
T = {
    'zh': {
        'login_title': '🛡️ 中转面板登录', 'username': '用户名', 'password': '密码', 'login_btn': '安全登录',
        'panel_title': '🚀 流量中转管理面板', 'logout': '安全退出', 'add_rule': '➕ 新增端口转发',
        'protocol': '转发协议', 'local_port': '监听端口', 'target_ip': '目标 IP 或 域名', 'target_port': '目标端口',
        'remark': '备注信息', 'remark_ph': '选填 (如: Web/游戏服)', 'add_btn': '立即添加转发规则', 
        'cur_rules': '📋 当前生效规则', 'proto': '协议', 'forward_to': '转发至',
        'action': '操作', 'delete': '🗑️ 删除', 'no_rules': '当前没有配置任何转发规则。',
        'confirm_del': '确定要删除这条规则吗？', 'tcp_only': '纯 TCP (网页/SSH)',
        'udp_only': '纯 UDP (Hysteria2)', 'dual_stack': 'TCP + UDP 双栈',
        'lang_btn': '🌐 English', 'switch_to': 'en', 'err_port': '端口必须是 1-65535 之间的数字！',
        'err_ip': '无效的 IP 地址或域名解析失败！', 'err_duplicate': '规则已存在，无需重复添加。',
        'add_success': '添加成功！', 'del_success': '删除成功',
        'login_error': '用户名或密码错误', 'overview': '运行概览', 'total_rules': '总规则',
        'tcp_rules': 'TCP 规则', 'udp_rules': 'UDP 规则'
    },
    'en': {
        'login_title': '🛡️ Panel Login', 'username': 'Username', 'password': 'Password', 'login_btn': 'Secure Login',
        'panel_title': '🚀 Traffic Forwarding Panel', 'logout': 'Logout', 'add_rule': '➕ Add Port Forwarding',
        'protocol': 'Protocol', 'local_port': 'Local Port', 'target_ip': 'Target IP / Domain', 'target_port': 'Target Port',
        'remark': 'Remark / Note', 'remark_ph': 'Optional', 'add_btn': 'Add Forwarding Rule', 
        'cur_rules': '📋 Active Rules', 'proto': 'Protocol', 'forward_to': 'Forward to',
        'action': 'Action', 'delete': '🗑️ Delete', 'no_rules': 'No rules configured currently.',
        'confirm_del': 'Are you sure you want to delete this rule?', 'tcp_only': 'TCP Only (Web)',
        'udp_only': 'UDP Only (Hysteria2)', 'dual_stack': 'TCP + UDP Dual',
        'lang_btn': '🌐 中文', 'switch_to': 'zh', 'err_port': 'Ports must be numbers between 1 and 65535!',
        'err_ip': 'Invalid IP or Domain resolution failed!', 'err_duplicate': 'Rule already exists. No duplicate was added.',
        'add_success': 'Added successfully!', 'del_success': 'Deleted',
        'login_error': 'Invalid username or password', 'overview': 'Overview', 'total_rules': 'Total Rules',
        'tcp_rules': 'TCP Rules', 'udp_rules': 'UDP Rules'
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
            grid-template-columns: repeat(3, minmax(0, 1fr));
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
    </style>
</head>
<body>
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
        <h1 class="login-title mb-4">{{ t.login_title }}</h1>
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
        <h1 class="page-title">{{ t.panel_title }}</h1>
        <div class="page-actions">
            <a href="/logout" class="btn btn-outline-danger">{{ t.logout }}</a>
        </div>
    </div>
    {% if message %}<div class="alert alert-{{ status }}">{{ message }}</div>{% endif %}

    <div class="metric-grid" aria-label="{{ t.overview }}">
        <div class="metric">
            <div class="metric-label">{{ t.total_rules }}</div>
            <div class="metric-value">{{ rules|length }}</div>
        </div>
        <div class="metric">
            <div class="metric-label">{{ t.tcp_rules }}</div>
            <div class="metric-value">{{ rules|selectattr('protocol', 'equalto', 'TCP')|list|length }}</div>
        </div>
        <div class="metric">
            <div class="metric-label">{{ t.udp_rules }}</div>
            <div class="metric-value">{{ rules|selectattr('protocol', 'equalto', 'UDP')|list|length }}</div>
        </div>
    </div>
    
    <section class="panel-card">
        <div class="panel-header">{{ t.add_rule }}</div>
        <div class="panel-body">
            <form method="POST" action="/add" class="row g-3">
                <div class="col-lg-2 col-md-4"><label class="form-label">{{ t.protocol }}</label>
                    <select class="form-select" name="protocol">
                        <option value="tcp">{{ t.tcp_only }}</option>
                        <option value="udp" selected>{{ t.udp_only }}</option>
                        <option value="all">{{ t.dual_stack }}</option>
                    </select>
                </div>
                <div class="col-lg-2 col-md-4"><label class="form-label">{{ t.local_port }}</label><input type="number" min="1" max="65535" class="form-control" name="local_port" required></div>
                <div class="col-lg-3 col-md-4"><label class="form-label">{{ t.target_ip }}</label><input type="text" class="form-control" name="target_ip" required></div>
                <div class="col-lg-2 col-md-4"><label class="form-label">{{ t.target_port }}</label><input type="number" min="1" max="65535" class="form-control" name="target_port" required></div>
                <div class="col-lg-3 col-md-8"><label class="form-label">{{ t.remark }}</label><input type="text" class="form-control" name="remark" placeholder="{{ t.remark_ph }}"></div>
                <div class="col-12"><button type="submit" class="btn btn-primary w-100">{{ t.add_btn }}</button></div>
            </form>
        </div>
    </section>

    <section class="panel-card">
        <div class="panel-header">{{ t.cur_rules }}</div>
        <div class="table-responsive p-0">
            <table class="table table-hover">
                <thead><tr><th class="ps-4">{{ t.proto }}</th><th>{{ t.local_port }}</th><th>{{ t.forward_to }}</th><th>{{ t.target_ip }} : {{ t.target_port }}</th><th>{{ t.remark }}</th><th class="text-end pe-4">{{ t.action }}</th></tr></thead>
                <tbody>
                    {% for rule in rules %}
                    <tr>
                        <td class="ps-4"><span class="badge {% if rule.protocol == 'TCP' %}badge-tcp{% else %}badge-udp{% endif %}">{{ rule.protocol }}</span></td>
                        <td class="fw-bold">{{ rule.local_port }}</td><td class="text-muted">{{ t.forward_to }}</td>
                        <td><span class="target-pill">{{ rule.target_ip }} : {{ rule.target_port }}</span></td>
                        <td><div class="remark-cell" title="{{ rule.remark }}">{% if rule.remark %}{{ rule.remark }}{% else %}-{% endif %}</div></td>
                        <td class="text-end pe-4">
                            <form method="POST" action="/delete" style="display:inline;">
                                <input type="hidden" name="protocol" value="{{ rule.protocol | lower }}">
                                <input type="hidden" name="local_port" value="{{ rule.local_port }}">
                                <input type="hidden" name="target_ip" value="{{ rule.target_ip }}">
                                <input type="hidden" name="target_port" value="{{ rule.target_port }}">
                                <input type="hidden" name="remark" value="{{ rule.remark }}">
                                <button type="submit" class="btn btn-danger btn-sm" onclick="return confirm('{{ t.confirm_del }}');">{{ t.delete }}</button>
                            </form>
                        </td>
                    </tr>
                    {% else %}<tr><td colspan="6" class="text-center empty-row">{{ t.no_rules }}</td></tr>{% endfor %}
                </tbody>
            </table>
        </div>
    </section>
</main></body></html>
"""

def get_t(): return T[session.get('lang', 'zh')]

def get_parsed_rules():
    rules_list = []
    try:
        res = subprocess.run(['sudo', 'iptables-save', '-t', 'nat'], capture_output=True, text=True)
        for line in res.stdout.split('\n'):
            if line.startswith('-A PREROUTING') and '-j DNAT' in line:
                proto_m = re.search(r'-p\s+(tcp|udp)', line)
                lport_m = re.search(r'--dport\s+(\d+)', line)
                target_m = re.search(r'--to-destination\s+([\d\.]+):(\d+)', line)
                remark_m = re.search(r'--comment\s+"([^"]+)"', line)
                
                if proto_m and lport_m and target_m:
                    rules_list.append({
                        'protocol': proto_m.group(1).upper(),
                        'local_port': lport_m.group(1),
                        'target_ip': target_m.group(1),
                        'target_port': target_m.group(2),
                        'remark': remark_m.group(1) if remark_m else ''
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
        return render_template_string(LOGIN_HTML, t=t, error=t['login_error'])
    return render_template_string(LOGIN_HTML, t=t)

@app.route('/logout')
def logout(): session.pop('logged_in', None); return redirect(url_for('login'))

@app.route('/', methods=['GET'])
def index():
    if not session.get('logged_in'): return redirect(url_for('login'))
    return render_template_string(DASHBOARD_HTML, t=get_t(), rules=get_parsed_rules(), message=request.args.get('msg'), status=request.args.get('status', 'success'))

@app.route('/add', methods=['POST'])
def add_rule():
    if not session.get('logged_in'): return redirect(url_for('login'))
    t = get_t()
    p, l_port, t_input, t_port = request.form.get('protocol'), request.form.get('local_port'), request.form.get('target_ip', '').strip(), request.form.get('target_port')
    
    remark = request.form.get('remark', '').replace('"', '').replace("'", "").strip()

    if not valid_port(l_port) or not valid_port(t_port): return redirect(url_for('index', msg=t['err_port'], status="danger"))
    
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
        for proto in protos:
            cmd_pre = ['sudo', 'iptables', '-t', 'nat', '-A', 'PREROUTING', '-p', proto, '--dport', l_port]
            if remark: cmd_pre.extend(['-m', 'comment', '--comment', remark])
            cmd_pre.extend(['-j', 'DNAT', '--to-destination', f'{t_ip}:{t_port}'])
            subprocess.run(cmd_pre, check=True)
            
            subprocess.run(['sudo', 'iptables', '-t', 'nat', '-A', 'POSTROUTING', '-p', proto, '-d', t_ip, '--dport', t_port, '-j', 'MASQUERADE'], check=True)
        return redirect(url_for('index', msg=t['add_success'], status="success"))
    except Exception as e: return redirect(url_for('index', msg=f"Failed: {e}", status="danger"))

@app.route('/delete', methods=['POST'])
def delete_rule():
    if not session.get('logged_in'): return redirect(url_for('login'))
    t = get_t()
    p, l_port, t_ip, t_port, remark = request.form.get('protocol'), request.form.get('local_port'), request.form.get('target_ip'), request.form.get('target_port'), request.form.get('remark', '')
    try:
        cmd_pre = ['sudo', 'iptables', '-t', 'nat', '-D', 'PREROUTING', '-p', p, '--dport', l_port]
        if remark: cmd_pre.extend(['-m', 'comment', '--comment', remark])
        cmd_pre.extend(['-j', 'DNAT', '--to-destination', f'{t_ip}:{t_port}'])
        subprocess.run(cmd_pre, check=True)
        
        subprocess.run(['sudo', 'iptables', '-t', 'nat', '-D', 'POSTROUTING', '-p', p, '-d', t_ip, '--dport', t_port, '-j', 'MASQUERADE'], check=True)
        return redirect(url_for('index', msg=t['del_success'], status="warning"))
    except Exception as e: return redirect(url_for('index', msg=f"Failed: {e}", status="danger"))

if __name__ == '__main__':
    subprocess.run(['sudo', 'sysctl', '-w', 'net.ipv4.ip_forward=1'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
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
ExecStart=/usr/bin/python3 $INSTALL_DIR/panel.py --port $PANEL_PORT --user $PANEL_USER --password $PANEL_PASS
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable iptables-panel > /dev/null 2>&1
systemctl restart iptables-panel

echo "====================================================="
echo "✅ 安装/更新成功！面板已在后台运行并设置开机自启。"
echo "🌐 访问地址: http://你的服务器IP:$PANEL_PORT"
echo "👤 登录账号: $PANEL_USER"
echo "🔑 登录密码: $PANEL_PASS"
echo "====================================================="
