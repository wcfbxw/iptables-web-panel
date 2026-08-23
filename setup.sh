#!/bin/bash
set -euo pipefail

SERVICE_FILE="/etc/systemd/system/iptables-panel.service"
CONFIG_FILE="/etc/iptables-panel/panel.env"
REPOSITORY_RAW_URL="${PANEL_INSTALL_BASE_URL:-https://raw.githubusercontent.com/wcfbxw/iptables-web-panel/main}"
INSTALL_CHANNEL=""
TEMP_DIR=""

cleanup() {
  case "$TEMP_DIR" in
    /tmp/iptables-panel-installer.*)
      [ -d "$TEMP_DIR" ] && rm -rf -- "$TEMP_DIR"
      ;;
  esac
}
trap cleanup EXIT

usage() {
  cat << 'EOF'
用法: sudo bash setup.sh [选项]

选项:
  --stable        直接进入稳定版安装器
  --experimental  直接进入实验版安装器
  -h, --help      显示帮助

不带参数运行时会显示版本选择菜单。
EOF
}

detect_installed_panel() {
  INSTALLED_CHANNEL=""
  INSTALLED_RUNTIME=""
  INSTALLED_BACKEND=""

  if [ -f "$SERVICE_FILE" ] && [ -f "$CONFIG_FILE" ]; then
    INSTALLED_CHANNEL=$(sed -n 's/^PANEL_CHANNEL=//p' "$CONFIG_FILE" | tail -n 1)
    INSTALLED_RUNTIME=$(sed -n 's/^PANEL_RUNTIME=//p' "$CONFIG_FILE" | tail -n 1)
    INSTALLED_BACKEND=$(sed -n 's/^PANEL_BACKEND=//p' "$CONFIG_FILE" | tail -n 1)
    case "$INSTALLED_RUNTIME" in
      python) INSTALLED_RUNTIME="Python" ;;
      rust) INSTALLED_RUNTIME="Rust" ;;
    esac
    if [ -n "$INSTALLED_CHANNEL" ] && [ -n "$INSTALLED_RUNTIME" ] && [ -n "$INSTALLED_BACKEND" ]; then
      return
    fi
  fi

  if [ ! -f "$SERVICE_FILE" ]; then
    return
  fi

  local exec_start
  exec_start=$(sed -n 's/^ExecStart=//p' "$SERVICE_FILE" | head -n 1)
  if [ -z "$exec_start" ]; then
    return
  fi

  if printf '%s' "$exec_start" | grep -q -- '--backend'; then
    INSTALLED_CHANNEL="experimental"
  else
    INSTALLED_CHANNEL="stable"
  fi

  if printf '%s' "$exec_start" | grep -q '/panel.py'; then
    INSTALLED_RUNTIME="Python"
  else
    INSTALLED_RUNTIME="Rust"
  fi

  if printf '%s' "$exec_start" | grep -q -- '--backend nftables'; then
    INSTALLED_BACKEND="nftables"
  else
    INSTALLED_BACKEND="iptables"
  fi
}

channel_name() {
  if [ "$1" = "experimental" ]; then
    printf '实验版'
  else
    printf '稳定版'
  fi
}

download_installer() {
  local url="$1"
  local output="$2"

  if command -v curl > /dev/null 2>&1; then
    curl -fsSL "$url" -o "$output"
    return
  fi

  if command -v wget > /dev/null 2>&1; then
    wget -qO "$output" "$url"
    return
  fi

  echo "未找到 curl 或 wget，正在安装 curl..."
  apt-get update -y > /dev/null 2>&1
  apt-get install -y curl ca-certificates > /dev/null 2>&1
  curl -fsSL "$url" -o "$output"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --stable)
      if [ -n "$INSTALL_CHANNEL" ] && [ "$INSTALL_CHANNEL" != "stable" ]; then
        echo "不能同时指定 --stable 和 --experimental。"
        exit 1
      fi
      INSTALL_CHANNEL="stable"
      ;;
    --experimental)
      if [ -n "$INSTALL_CHANNEL" ] && [ "$INSTALL_CHANNEL" != "experimental" ]; then
        echo "不能同时指定 --stable 和 --experimental。"
        exit 1
      fi
      INSTALL_CHANNEL="experimental"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "未知参数: $1"
      usage
      exit 1
      ;;
  esac
  shift
done

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "请使用 root 权限运行此脚本，例如: sudo bash setup.sh"
  exit 1
fi

if [ -z "$INSTALL_CHANNEL" ]; then
  echo "====================================================="
  echo "          流量中转管理面板统一安装器"
  echo "====================================================="
  echo "1) 稳定版（推荐）  Python + iptables"
  echo "2) 实验版（高级）  Python/Rust + iptables/nftables"
  echo "3) 退出"
  echo ""
  read -r -p "请选择版本 [默认: 1]: " CHANNEL_CHOICE
  CHANNEL_CHOICE=${CHANNEL_CHOICE:-1}

  case "$CHANNEL_CHOICE" in
    2) INSTALL_CHANNEL="experimental" ;;
    3) echo "已退出。"; exit 0 ;;
    *) INSTALL_CHANNEL="stable" ;;
  esac
fi

detect_installed_panel

if [ -n "$INSTALLED_CHANNEL" ]; then
  echo ""
  echo "检测到已安装: $(channel_name "$INSTALLED_CHANNEL") / $INSTALLED_RUNTIME + $INSTALLED_BACKEND"

  if [ "$INSTALLED_CHANNEL" != "$INSTALL_CHANNEL" ]; then
    echo ""
    echo "注意: 你正在从 $(channel_name "$INSTALLED_CHANNEL") 切换到 $(channel_name "$INSTALL_CHANNEL")。"
    echo "现有内核转发规则不会被自动删除，也不会在不同防火墙后端之间自动迁移。"
    echo "流量配额和到期时间等面板元数据也不会自动跨版本迁移。"
    read -r -p "确认继续请输入 SWITCH: " SWITCH_CONFIRM
    if [ "$SWITCH_CONFIRM" != "SWITCH" ]; then
      echo "已取消版本切换。"
      exit 0
    fi
  else
    echo "将进入同一版本的升级/维护流程，默认保留现有转发规则。"
  fi
fi

if [ "$INSTALL_CHANNEL" = "experimental" ]; then
  INSTALLER_FILE="install-v2.sh"
else
  INSTALLER_FILE="install.sh"
fi

TEMP_DIR=$(mktemp -d /tmp/iptables-panel-installer.XXXXXX)
INSTALLER_PATH="$TEMP_DIR/$INSTALLER_FILE"

echo ""
echo "正在获取$(channel_name "$INSTALL_CHANNEL")安装器..."
download_installer "$REPOSITORY_RAW_URL/$INSTALLER_FILE" "$INSTALLER_PATH"

echo "正在启动$(channel_name "$INSTALL_CHANNEL")安装器。"
PANEL_CHANNEL_SWITCH_CONFIRMED=1 bash "$INSTALLER_PATH"
