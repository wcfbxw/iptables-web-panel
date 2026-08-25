#!/usr/bin/env bash
set -Eeuo pipefail

umask 077

PROJECT="wcfbxw/iptables-web-panel"
LITE_VERSION="${LITE_VERSION:-0.1.0}"
INSTALL_DIR="/opt/iptables-panel"
PANEL_BINARY="$INSTALL_DIR/panel"
CONFIG_DIR="/etc/iptables-panel"
CONFIG_FILE="$CONFIG_DIR/panel.env"
SERVICE_FILE="/etc/systemd/system/iptables-panel.service"
SYSCTL_FILE="/etc/sysctl.d/99-iptables-panel.conf"
TEMP_DIR=""
ROLLBACK_READY=0
PREVIOUS_SERVICE_ACTIVE=0
PREVIOUS_SERVICE_ENABLED=0

info() {
  printf '%s\n' "$*"
}

warn() {
  printf 'WARNING: %s\n' "$*" >&2
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

ensure_temp_dir() {
  if [ -z "$TEMP_DIR" ]; then
    TEMP_DIR=$(mktemp -d /tmp/iptables-panel-lite.XXXXXX)
  fi
}

rollback_install() {
  warn "安装未完成，正在恢复原面板程序和服务。"
  systemctl stop iptables-panel >/dev/null 2>&1 || true
  systemctl disable iptables-panel >/dev/null 2>&1 || true

  if [ -f "$TEMP_DIR/backup/panel" ]; then
    install -m 0755 "$TEMP_DIR/backup/panel" "$PANEL_BINARY"
  else
    rm -f "$PANEL_BINARY"
  fi
  if [ -f "$TEMP_DIR/backup/panel.env" ]; then
    install -d -m 0700 "$CONFIG_DIR"
    install -m 0600 "$TEMP_DIR/backup/panel.env" "$CONFIG_FILE"
  else
    rm -f "$CONFIG_FILE"
  fi
  if [ -f "$TEMP_DIR/backup/iptables-panel.service" ]; then
    install -m 0644 "$TEMP_DIR/backup/iptables-panel.service" "$SERVICE_FILE"
  else
    rm -f "$SERVICE_FILE"
  fi

  systemctl daemon-reload >/dev/null 2>&1 || true
  if [ "$PREVIOUS_SERVICE_ENABLED" = "1" ]; then
    systemctl enable iptables-panel >/dev/null 2>&1 || true
  fi
  if [ "$PREVIOUS_SERVICE_ACTIVE" = "1" ]; then
    systemctl start iptables-panel >/dev/null 2>&1 || true
  fi
}

cleanup() {
  local status=$?
  trap - EXIT
  if [ "$status" -ne 0 ] && [ "$ROLLBACK_READY" = "1" ] && [ -n "$TEMP_DIR" ]; then
    rollback_install
  fi
  if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
    rm -rf "$TEMP_DIR"
  fi
  exit "$status"
}
trap cleanup EXIT

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  die "请使用 root 权限运行，例如 sudo bash install.sh"
fi

command -v systemctl >/dev/null 2>&1 || die "Lite 版当前需要 systemd。"
[ -d /run/systemd/system ] || die "当前系统未使用 systemd 作为服务管理器。"
command -v install >/dev/null 2>&1 || die "缺少 coreutils install 命令。"
command -v sha256sum >/dev/null 2>&1 || die "缺少 sha256sum，无法校验下载文件。"

fetch() {
  local url=$1
  local output=$2
  if command -v curl >/dev/null 2>&1; then
    curl -fL --connect-timeout 10 --retry 3 --retry-delay 2 -o "$output" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -q --timeout=20 --tries=3 -O "$output" "$url"
  else
    die "需要系统预装 curl 或 wget；Lite 安装器不会运行 apt 安装依赖。"
  fi
}

config_value() {
  [ -f "$CONFIG_FILE" ] || return 0
  sed -n "s/^$1=//p" "$CONFIG_FILE" | tail -n 1
}

hex_encode() {
  printf '%s' "$1" | od -An -tx1 | tr -d ' \n'
}

hex_decode() {
  local escaped
  [ -n "$1" ] || return 0
  escaped=$(printf '%s' "$1" | sed 's/../\\x&/g')
  printf '%b' "$escaped"
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
    [ -n "$EXISTING_PORT" ] || EXISTING_PORT="5000"
    local user_hex password_hex
    user_hex=$(config_value PANEL_USER_HEX)
    password_hex=$(config_value PANEL_PASSWORD_HEX)
    [ -n "$user_hex" ] && EXISTING_USER=$(hex_decode "$user_hex")
    [ -n "$password_hex" ] && EXISTING_PASSWORD=$(hex_decode "$password_hex")
  fi

  if [ -f "$SERVICE_FILE" ]; then
    local current_exec
    current_exec=$(sed -n 's/^ExecStart=//p' "$SERVICE_FILE" | head -n 1)
    if [ -z "$EXISTING_RUNTIME" ]; then
      if printf '%s' "$current_exec" | grep -q 'python'; then
        EXISTING_RUNTIME="python"
      else
        EXISTING_RUNTIME="rust"
      fi
    fi
    if [ -z "$EXISTING_BACKEND" ]; then
      if printf '%s' "$current_exec" | grep -q -- '--backend nftables'; then
        EXISTING_BACKEND="nftables"
      else
        EXISTING_BACKEND="iptables"
      fi
    fi
    if [ "$EXISTING_PORT" = "5000" ]; then
      local service_port
      service_port=$(printf '%s\n' "$current_exec" | sed -n 's/.*--port \([^ ]*\).*/\1/p')
      [ -n "$service_port" ] && EXISTING_PORT="$service_port"
    fi
  fi
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) PANEL_ARCH="amd64" ;;
    aarch64|arm64) PANEL_ARCH="arm64" ;;
    armv7l|armv7) PANEL_ARCH="armv7" ;;
    *) die "暂不支持当前架构: $(uname -m)" ;;
  esac
}

download_binary() {
  if [ -n "${DOWNLOADED_BINARY:-}" ] && [ -x "$DOWNLOADED_BINARY" ]; then
    return
  fi

  ensure_temp_dir
  detect_arch
  local asset="iptables-panel-linux-$PANEL_ARCH"
  local binary="$TEMP_DIR/$asset"

  if [ -n "${PANEL_LITE_BINARY_FILE:-}" ]; then
    install -m 0755 "$PANEL_LITE_BINARY_FILE" "$binary"
  else
    local base="${PANEL_LITE_RELEASE_BASE:-https://github.com/$PROJECT/releases/download/lite-v$LITE_VERSION}"
    info "正在下载 Lite v$LITE_VERSION ($PANEL_ARCH)..."
    fetch "$base/$asset" "$binary"
    fetch "$base/$asset.sha256" "$binary.sha256"
    local expected actual
    expected=$(awk 'NR == 1 {print $1}' "$binary.sha256")
    actual=$(sha256sum "$binary" | awk '{print $1}')
    [ -n "$expected" ] && [ "$expected" = "$actual" ] || die "Rust 二进制 SHA-256 校验失败。"
    chmod 0755 "$binary"
  fi

  local version_output
  version_output=$("$binary" --version 2>/dev/null) || die "下载的程序无法在当前系统运行。"
  printf '%s' "$version_output" | grep -q "iptables-panel-lite $LITE_VERSION" \
    || die "下载的程序版本不匹配: $version_output"
  DOWNLOADED_BINARY="$binary"
}

report_memory() {
  local total_kb available_kb
  total_kb=$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || printf '0')
  available_kb=$(awk '/MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || printf '0')
  info "内存: 总计 $((total_kb / 1024)) MB，可用 $((available_kb / 1024)) MB"
  if [ "$available_kb" -gt 0 ] && [ "$available_kb" -lt 32768 ]; then
    warn "当前可用内存不足 32 MB，安装可以继续，但系统运行稳定性无法保证。"
  fi
}

backend_available() {
  if [ "$1" = "nftables" ]; then
    command -v nft >/dev/null 2>&1
  else
    command -v iptables >/dev/null 2>&1 && command -v iptables-save >/dev/null 2>&1
  fi
}

select_backend() {
  local has_iptables=0
  local has_nftables=0
  backend_available iptables && has_iptables=1
  backend_available nftables && has_nftables=1

  if [ -n "${PANEL_LITE_BACKEND:-}" ]; then
    FIREWALL_BACKEND="$PANEL_LITE_BACKEND"
  elif [ "$has_iptables" = "1" ] && [ "$has_nftables" = "1" ]; then
    local default_choice=1 choice
    [ "$EXISTING_BACKEND" = "nftables" ] && default_choice=2
    info "1) iptables"
    info "2) nftables"
    read -r -p "请选择防火墙后端 [默认: $default_choice]: " choice
    choice=${choice:-$default_choice}
    if [ "$choice" = "2" ]; then FIREWALL_BACKEND="nftables"; else FIREWALL_BACKEND="iptables"; fi
  elif [ "$has_iptables" = "1" ]; then
    FIREWALL_BACKEND="iptables"
  elif [ "$has_nftables" = "1" ]; then
    FIREWALL_BACKEND="nftables"
  else
    die "未找到 iptables 或 nftables。请先在系统镜像中安装防火墙工具；Lite 安装器不会执行 apt update。"
  fi

  [ "$FIREWALL_BACKEND" = "iptables" ] || [ "$FIREWALL_BACKEND" = "nftables" ] \
    || die "无效防火墙后端: $FIREWALL_BACKEND"
  backend_available "$FIREWALL_BACKEND" || die "系统未安装 $FIREWALL_BACKEND 所需命令。"

  if [ -n "$EXISTING_BACKEND" ] && [ "$EXISTING_BACKEND" != "$FIREWALL_BACKEND" ]; then
    warn "将从 $EXISTING_BACKEND 切换到 $FIREWALL_BACKEND。旧后端规则会保留，但不会显示在新面板。"
    if [ "${PANEL_LITE_CONFIRM_SWITCH:-0}" != "1" ]; then
      local confirm
      read -r -p "输入 SWITCH 确认切换后端: " confirm
      [ "$confirm" = "SWITCH" ] || die "已取消安装。"
    fi
  fi
}

check_firewall_access() {
  if [ "$FIREWALL_BACKEND" = "nftables" ]; then
    nft list ruleset >/dev/null 2>&1 || die "当前 NAT 容器没有操作 nftables 的权限。"
  else
    iptables -t nat -S >/dev/null 2>&1 || die "当前 NAT 容器没有操作 iptables NAT 表的权限。"
  fi
}

enable_forwarding() {
  local current
  current=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || printf '0')
  if [ "$current" != "1" ]; then
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 \
      || die "无法开启 net.ipv4.ip_forward，服务商可能禁止内核转发。"
  fi
  if ! printf 'net.ipv4.ip_forward=1\n' > "$SYSCTL_FILE" 2>/dev/null; then
    warn "无法写入 $SYSCTL_FILE；当前转发已开启，但重启后可能失效。"
  fi
}

health_check() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time 2 "http://127.0.0.1:$PANEL_PORT/login" >/dev/null
  else
    wget -q --timeout=2 -O /dev/null "http://127.0.0.1:$PANEL_PORT/login"
  fi
}

uninstall_panel() {
  local remove_rules=$1
  local backend=${EXISTING_BACKEND:-iptables}

  if [ "$remove_rules" = "yes" ]; then
    local confirm
    warn "此操作会删除 $backend 后端中面板可识别的转发和流量追踪规则。"
    read -r -p "输入 DELETE 确认同时删除规则: " confirm
    [ "$confirm" = "DELETE" ] || die "已取消卸载。"
    FIREWALL_BACKEND="$backend"
    backend_available "$backend" || die "无法找到 $backend 命令，不能安全删除规则。"
    if [ "$EXISTING_CHANNEL" = "lite" ] && [ -x "$PANEL_BINARY" ]; then
      CLEANUP_BINARY="$PANEL_BINARY"
    else
      download_binary
      CLEANUP_BINARY="$DOWNLOADED_BINARY"
    fi
  fi

  systemctl stop iptables-panel >/dev/null 2>&1 || true
  if [ "$remove_rules" = "yes" ]; then
    if ! "$CLEANUP_BINARY" --backend "$backend" --cleanup-rules; then
      systemctl start iptables-panel >/dev/null 2>&1 || true
      die "规则清理失败，面板文件尚未卸载。"
    fi
  fi

  systemctl disable iptables-panel >/dev/null 2>&1 || true
  rm -f "$SERVICE_FILE"
  systemctl daemon-reload >/dev/null 2>&1 || true
  rm -rf "$INSTALL_DIR" "$CONFIG_DIR"
  rm -f "$SYSCTL_FILE"

  if [ "$remove_rules" = "yes" ]; then
    info "面板已卸载，并已清理当前后端中的可识别规则。"
  else
    info "面板已卸载，内核转发规则已保留。配额、到期和域名刷新不再执行。"
  fi
}

backup_current_install() {
  ensure_temp_dir
  mkdir -p "$TEMP_DIR/backup"
  [ -f "$PANEL_BINARY" ] && cp -p "$PANEL_BINARY" "$TEMP_DIR/backup/panel"
  [ -f "$CONFIG_FILE" ] && cp -p "$CONFIG_FILE" "$TEMP_DIR/backup/panel.env"
  [ -f "$SERVICE_FILE" ] && cp -p "$SERVICE_FILE" "$TEMP_DIR/backup/iptables-panel.service"
  if systemctl is-active --quiet iptables-panel; then
    PREVIOUS_SERVICE_ACTIVE=1
  fi
  if systemctl is-enabled --quiet iptables-panel; then
    PREVIOUS_SERVICE_ENABLED=1
  fi
  ROLLBACK_READY=1
}

write_config() {
  local user_hex password_hex
  user_hex=$(hex_encode "$PANEL_USER")
  password_hex=$(hex_encode "$PANEL_PASS")
  cat > "$TEMP_DIR/panel.env" <<EOF
PANEL_CHANNEL=lite
PANEL_RUNTIME=rust
PANEL_BACKEND=$FIREWALL_BACKEND
PANEL_THEME=glass
PANEL_PORT=$PANEL_PORT
PANEL_USER_HEX=$user_hex
PANEL_PASSWORD_HEX=$password_hex
PANEL_WATCH_INTERVAL=60
PANEL_LITE_VERSION=$LITE_VERSION
EOF
  install -d -m 0700 "$CONFIG_DIR"
  install -m 0600 "$TEMP_DIR/panel.env" "$CONFIG_FILE"
}

write_service() {
  cat > "$TEMP_DIR/iptables-panel.service" <<EOF
[Unit]
Description=Low-memory Traffic Forwarding Web Panel
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=$CONFIG_FILE
ExecStart=$PANEL_BINARY
Restart=on-failure
RestartSec=3
UMask=0077
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=$INSTALL_DIR
MemoryAccounting=true
TasksMax=8
LimitNOFILE=128

[Install]
WantedBy=multi-user.target
EOF
  install -m 0644 "$TEMP_DIR/iptables-panel.service" "$SERVICE_FILE"
}

load_existing_settings
report_memory

info "====================================================="
info "  流量中转管理面板 Lite v$LITE_VERSION"
info "  预编译 Rust / 极低内存模式"
info "====================================================="

if [ -d "$INSTALL_DIR" ] || [ -f "$SERVICE_FILE" ]; then
  info "检测到现有面板: ${EXISTING_CHANNEL:-unknown} / ${EXISTING_RUNTIME:-unknown} + ${EXISTING_BACKEND:-unknown}"
  info "1) 升级或切换到 Lite，保留转发规则（推荐）"
  info "2) 卸载面板，保留转发规则"
  info "3) 卸载面板，并删除可识别的转发规则"
  read -r -p "请选择操作 [默认: 1]: " EXISTING_ACTION
  EXISTING_ACTION=${EXISTING_ACTION:-1}
  case "$EXISTING_ACTION" in
    2) uninstall_panel no; exit 0 ;;
    3) uninstall_panel yes; exit 0 ;;
    *) info "升级仅替换面板程序和服务，现有内核规则与 limits.tsv 会保留。" ;;
  esac
fi

select_backend
check_firewall_access

read -r -p "请设置面板端口 [默认: $EXISTING_PORT]: " PANEL_PORT
PANEL_PORT=${PANEL_PORT:-$EXISTING_PORT}
case "$PANEL_PORT" in
  ''|*[!0-9]*) die "面板端口必须是 1-65535 的数字。" ;;
esac
[ "$PANEL_PORT" -ge 1 ] && [ "$PANEL_PORT" -le 65535 ] || die "面板端口必须是 1-65535。"

read -r -p "请设置管理员用户名 [默认: $EXISTING_USER]: " PANEL_USER
PANEL_USER=${PANEL_USER:-$EXISTING_USER}
[ -n "$PANEL_USER" ] || die "管理员用户名不能为空。"

if [ -n "$EXISTING_PASSWORD" ]; then
  read -r -s -p "请设置管理员密码 [回车保留原密码]: " PANEL_PASS
  printf '\n'
  PANEL_PASS=${PANEL_PASS:-$EXISTING_PASSWORD}
else
  GENERATED_PASSWORD=$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')
  read -r -s -p "请设置管理员密码 [回车使用随机密码]: " PANEL_PASS
  printf '\n'
  PANEL_PASS=${PANEL_PASS:-$GENERATED_PASSWORD}
fi
[ -n "$PANEL_PASS" ] || die "管理员密码不能为空。"

download_binary
enable_forwarding
backup_current_install
systemctl stop iptables-panel >/dev/null 2>&1 || true

install -d -m 0755 "$INSTALL_DIR"
install -m 0755 "$DOWNLOADED_BINARY" "$INSTALL_DIR/panel.new"
mv -f "$INSTALL_DIR/panel.new" "$PANEL_BINARY"
write_config
write_service

systemctl daemon-reload
systemctl enable iptables-panel >/dev/null 2>&1
systemctl restart iptables-panel

PANEL_HEALTHY=0
for _attempt in 1 2 3 4 5 6 7 8 9 10; do
  if systemctl is-active --quiet iptables-panel && health_check; then
    PANEL_HEALTHY=1
    break
  fi
  sleep 1
done

if [ "$PANEL_HEALTHY" != "1" ]; then
  journalctl -u iptables-panel -n 20 --no-pager >&2 || true
  die "面板服务启动失败。"
fi

ROLLBACK_READY=0
rm -f "$INSTALL_DIR/panel.py" "$INSTALL_DIR/panel.rs" || warn "无法删除旧运行时源码。"
rm -rf "$INSTALL_DIR/__pycache__" || warn "无法删除旧 Python 缓存。"
MEMORY_CURRENT=$(systemctl show iptables-panel -p MemoryCurrent --value 2>/dev/null || true)
if [ -n "$MEMORY_CURRENT" ] && [ "$MEMORY_CURRENT" != "[not set]" ] && [ "$MEMORY_CURRENT" -gt 0 ] 2>/dev/null; then
  MEMORY_TEXT="$((MEMORY_CURRENT / 1024 / 1024)) MB"
else
  MEMORY_TEXT="请使用 systemctl status iptables-panel 查看"
fi

info "====================================================="
info "安装或升级成功"
info "版本: Lite v$LITE_VERSION / Rust + $FIREWALL_BACKEND"
info "地址: http://你的服务器IP:$PANEL_PORT"
info "账号: $PANEL_USER"
info "密码: $PANEL_PASS"
info "当前服务内存: $MEMORY_TEXT"
info "====================================================="
