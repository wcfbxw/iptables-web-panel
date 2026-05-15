#!/bin/bash

# 确保脚本以 root 权限运行
if [ "$EUID" -ne 0 ]; then 
  echo "❌ 请使用 root 权限运行此脚本 (例如: sudo bash install.sh)"
  exit 1
fi

echo "====================================================="
echo "   🚀 欢迎安装 Iptables 流量中转面板 (双语备注 Pro 版)   "
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
INSTALL_DIR="/opt/iptables-panel"
mkdir -p $INSTALL_DIR

# 写入支持双语和备注模块的 panel.py
cat << 'EOF' > $INSTALL_DIR/panel.py
import subprocess, ipaddress, os, argparse, re
from flask import Flask, request, render_template_string, session, redirect, url_for

parser = argparse.ArgumentParser()
parser.add_argument('--port', type=int, default=5000)
parser.add_argument('--user', type=str, default='admin')
parser.add_argument('--password', type=str, default='123456')
args = parser.parseargs()

ADMIN_USER, ADMIN_PASS, PANEL_PORT = args.user, args.password, args.port
app = Flask(__name__)
app.secret_key = os.urandom(24)

# --- 双语字典 (加入备注字段) ---
T = {
    'zh': {
        'login_title': '🛡️ 中转面板登录', 'username': '用户名', 'password': '密码', 'login_btn': '安全登录',
        'panel_title': '🚀 流量中转管理面板', 'logout': '安全退出', 'add_rule': '➕ 新增端口转发',
        'protocol': '转发协议', 'local_port': '监听端口', 'target_ip': '目标 IP 地址', 'target_port': '目标端口',
        'remark': '备注信息', 'remark_ph': '选填 (如: Web/游戏服)', 'add_btn': '立即添加转发规则', 
        'cur_rules': '📋 当前生效规则', 'proto': '协议', 'forward_to': '转发至',
        'action': '操作', 'delete': '🗑️ 删除', 'no_rules': '当前没有配置任何转发规则。',
        'confirm_del': '确定要删除这条规则吗？', 'tcp_only': '纯 TCP (网页/SSH)',
        'udp_only': '纯 UDP (Hysteria2)', 'dual_stack': 'TCP + UDP 双栈',
        'lang_btn': '🌐 English', 'switch_to': 'en', 'err_port': '端口必须是数字！', 'err_ip': '无效的 IP 地址！'
    },
    'en': {
        'login_title': '🛡️ Panel Login', 'username': 'Username', 'password': 'Password', 'login_btn': 'Secure Login',
        'panel_title': '🚀 Traffic Forwarding Panel', 'logout': 'Logout', 'add_rule': '➕ Add Port Forwarding',
        'protocol': 'Protocol', 'local_port': 'Local Port', 'target_ip': 'Target IP', 'target_port': 'Target Port',
        'remark': 'Remark / Note', 'remark_ph': 'Optional', 'add_btn': 'Add Forwarding Rule', 
        'cur_rules': '📋 Active Rules', 'proto': 'Protocol', 'forward_to': 'Forward to',
        'action': 'Action', 'delete': '🗑️ Delete', 'no_rules': 'No rules configured currently.',
        'confirm_del': 'Are you sure you want to delete this rule?', 'tcp_only': 'TCP Only (Web)',
        'udp_only': 'UDP Only (Hysteria2)', 'dual_stack': 'TCP + UDP Dual',
        'lang_btn': '🌐 中文', 'switch_to': 'zh', 'err_port': 'Ports must be numbers!', 'err_ip': 'Invalid IP!'
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
        body { background-color: #f8f9fa; }
        .card { border: none; box-shadow: 0 4px 12px rgba(0,0,0,0.05); margin-bottom: 25px; border-radius: 12px; }
        .card-header { background-color: #fff; font-weight: bold; border-radius: 12px 12px 0 0 !important; }
        .badge-tcp { background-color: #0d6efd; } .badge-udp { background-color: #6f42c1; }
    </style>
</head>
<body>
    <div class="container text-end mt-2">
        <a href="/lang/{{ t.switch_to }}" class="btn btn-sm btn-outline-secondary">{{ t.lang_btn }}</a>
    </div>
"""

LOGIN_HTML = HEADER_HTML + """
<div class="container" style="max-width: 400px; margin-top: 5vh;">
    <div class="card p-4">
        <h3 class="text-center mb-4 text-primary">{{ t.login_title }}</h3>
        {% if error %}<div class="alert alert-danger p-2 text-center">{{ error }}</div>{% endif %}
        <form method="POST" action="/login">
            <div class="mb-3"><label>{{ t.username }}</label><input type="text" class="form-control" name="username" required></div>
            <div class="mb-4"><label>{{ t.password }}</label><input type="password" class="form-control" name="password" required></div>
            <button type="submit" class="btn btn-primary w-100">{{ t.login_btn }}</button>
        </form>
    </div>
</div></body></html>
"""

DASHBOARD_HTML = HEADER_HTML + """
<div class="container" style="max-width: 1050px; margin-top: 20px; margin-bottom: 50px;">
    <div class="d-flex justify-content-between mb-4">
        <h2>{{ t.panel_title }}</h2>
        <a href="/logout" class="btn btn-outline-danger">{{ t.logout }}</a>
    </div>
    {% if message %}<div class="alert alert-{{ status }}">{{ message }}</div>{% endif %}
    
    <div class="card">
        <div class="card-header text-primary">{{ t.add_rule }}</div>
        <div class="card-body">
            <form method="POST" action="/add" class="row g-3">
                <div class="col-md-2"><label class="text-muted">{{ t.protocol }}</label>
                    <select class="form-select" name="protocol">
                        <option value="tcp">{{ t.tcp_only }}</option>
                        <option value="udp" selected>{{ t.udp_only }}</option>
                        <option value="all">{{ t.dual_stack }}</option>
                    </select>
                </div>
                <div class="col-md-2"><label class="text-muted">{{ t.local_port }}</label><input type="number" class="form-control" name="local_port" required></div>
                <div class="col-md-3"><label class="text-muted">{{ t.target_ip }}</label><input type="text" class="form-control" name="target_ip" required></div>
                <div class="col-md-2"><label class="text-muted">{{ t.target_port }}</label><input type="number" class="form-control" name="target_port" required></div>
                <div class="col-md-3"><label class="text-muted">{{ t.remark }}</label><input type="text" class="form-control" name="remark" placeholder="{{ t.remark_ph }}"></div>
                <div class="col-12 mt-4"><button type="submit" class="btn btn-primary w-100">{{ t.add_btn }}</button></div>
            </form>
        </div>
    </div>

    <div class="card">
        <div class="card-header text-success">{{ t.cur_rules }}</div>
        <div class="table-responsive p-0">
            <table class="table table-hover mb-0">
                <thead class="table-light"><tr><th class="ps-4">{{ t.proto }}</th><th>{{ t.local_port }}</th><th>➡️</th><th>{{ t.target_ip }} : {{ t.target_port }}</th><th>{{ t.remark }}</th><th class="text-end pe-4">{{ t.action }}</th></tr></thead>
                <tbody>
                    {% for rule in rules %}
                    <tr>
                        <td class="ps-4"><span class="badge {% if rule.protocol == 'TCP' %}badge-tcp{% else %}badge-udp{% endif %}">{{ rule.protocol }}</span></td>
                        <td class="fw-bold">{{ rule.local_port }}</td><td class="text-muted">{{ t.forward_to }}</td>
                        <td><span class="badge bg-dark">{{ rule.target_ip }} : {{ rule.target_port }}</span></td>
                        <td><span class="text-muted">{% if rule.remark %}{{ rule.remark }}{% else %}-{% endif %}</span></td>
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
                    {% else %}<tr><td colspan="6" class="text-center py-4">{{ t.no_rules }}</td></tr>{% endfor %}
                </tbody>
            </table>
        </div>
    </div>
</div></body></html>
"""

def get_t(): return T[session.get('lang', 'zh')]

# --- 解析底层 iptables-save 提取包含备注的规则 ---
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

@app.route('/lang/<lang>')
def switch_lang(lang):
    if lang in ['zh', 'en']: session['lang'] = lang
    return redirect(request.referrer or url_for('login'))

@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        if request.form.get('username') == ADMIN_USER and request.form.get('password') == ADMIN_PASS:
            session['logged_in'] = True; return redirect(url_for('index'))
        return render_template_string(LOGIN_HTML, t=get_t(), error="Error")
    return render_template_string(LOGIN_HTML, t=get_t())

@app.route('/logout')
def logout(): session.pop('logged_in', None); return redirect(url_for('login'))

@app.route('/', methods=['GET'])
def index():
    if not session.get('logged_in'): return redirect(url_for('login'))
    return render_template_string(DASHBOARD_HTML, t=get_t(), rules=get_parsed_rules(), message=request.args.get('msg'), status=request.args.get('status', 'success'))

@app.route('/add', methods=['POST'])
def add_rule():
    if not session.get('logged_in'): return redirect(url_for('login'))
    t, p, l_port, t_ip, t_port = get_t(), request.form.get('protocol'), request.form.get('local_port'), request.form.get('target_ip'), request.form.get('target_port')
    
    # 清理备注中的引号防止 iptables 语法报错
    remark = request.form.get('remark', '').replace('"', '').replace("'", "").strip()

    if not l_port.isdigit() or not t_port.isdigit(): return redirect(url_for('index', msg=t['err_port'], status="danger"))
    try: ipaddress.ip_address(t_ip)
    except ValueError: return redirect(url_for('index', msg=t['err_ip'], status="danger"))
    
    protos = ['tcp', 'udp'] if p == 'all' else [p]
    try:
        for proto in protos:
            cmd_pre = ['sudo', 'iptables', '-t', 'nat', '-A', 'PREROUTING', '-p', proto, '--dport', l_port]
            if remark: cmd_pre.extend(['-m', 'comment', '--comment', remark])
            cmd_pre.extend(['-j', 'DNAT', '--to-destination', f'{t_ip}:{t_port}'])
            subprocess.run(cmd_pre, check=True)
            
            subprocess.run(['sudo', 'iptables', '-t', 'nat', '-A', 'POSTROUTING', '-p', proto, '-d', t_ip, '--dport', t_port, '-j', 'MASQUERADE'], check=True)
        return redirect(url_for('index', msg="Success!", status="success"))
    except Exception as e: return redirect(url_for('index', msg=f"Failed: {e}", status="danger"))

@app.route('/delete', methods=['POST'])
def delete_rule():
    if not session.get('logged_in'): return redirect(url_for('login'))
    p, l_port, t_ip, t_port, remark = request.form.get('protocol'), request.form.get('local_port'), request.form.get('target_ip'), request.form.get('target_port'), request.form.get('remark', '')
    try:
        cmd_pre = ['sudo', 'iptables', '-t', 'nat', '-D', 'PREROUTING', '-p', p, '--dport', l_port]
        if remark: cmd_pre.extend(['-m', 'comment', '--comment', remark])
        cmd_pre.extend(['-j', 'DNAT', '--to-destination', f'{t_ip}:{t_port}'])
        subprocess.run(cmd_pre, check=True)
        
        subprocess.run(['sudo', 'iptables', '-t', 'nat', '-D', 'POSTROUTING', '-p', p, '-d', t_ip, '--dport', t_port, '-j', 'MASQUERADE'], check=True)
        return redirect(url_for('index', msg="Deleted", status="warning"))
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
echo "✅ 安装成功！面板已在后台运行并设置开机自启。"
echo "🌐 访问地址: http://你的服务器IP:$PANEL_PORT"
echo "👤 登录账号: $PANEL_USER"
echo "🔑 登录密码: $PANEL_PASS"
echo "====================================================="
