#!/bin/bash
# Cloudflare WARP 管理工具
# 功能：安装/配置 WARP IPv6（支持 WARP+）、卸载接口、卸载脚本、检测状态、自动检测异常重启、流媒体解锁检测
# 接口名 warp，保留本地 IPv4，自动检测架构，支持开机自启，安装后自动注册 02 命令

# --- 全局变量与常量 ---
# 标准 WARP 监控服务名
SERVICE_NAME="warp-monitor.service"
# 流媒体解锁监控服务名
STREAM_SERVICE_NAME="warp-stream-monitor.service"
# 统一设置 Netflix 新加坡独占影片 ID
NETFLIX_SG_ID="81215567"

# --- 辅助函数 ---

# 输出带颜色的文本
color_echo() {
    local color_map
    declare -A color_map=(
        ["red"]="31"
        ["green"]="32"
        ["yellow"]="33"
        ["blue"]="34"
        ["purple"]="35"
        ["cyan"]="36"
    )
    if [[ -n "${color_map[$1]}" ]]; then
        echo -e "\033[${color_map[$1]}m$2\033[0m"
    else
        echo "$2"
    fi
}

# 检查 WARP 接口状态和公网 IP
check_warp_status() {
    local status ipv4 ipv6

    if ip link show warp >/dev/null 2>&1; then
        status="$(color_echo green "运行中 ✅")"
    else
        status="$(color_echo red "未运行 ❌")"
    fi

    ipv4=$(curl -4 -s --max-time 5 https://ip.gs || echo "不可用")
    ipv6=$(curl -6 -s --max-time 5 https://ip.gs || echo "不可用")

    echo "--- WARP 状态 ---"
    echo "状态: $status"
    echo "出口 IPv4: $ipv4"
    echo "出口 IPv6: $ipv6"
    echo "-------------------"
}

# --- 菜单功能函数 ---

# 显示菜单
show_menu() {
    clear
    check_warp_status
    echo "    Cloudflare WARP 管理菜单"
    echo "==============================="
    echo "1) 安装/配置 WARP IPv6"
    echo "2) 卸载 WARP 接口"
    echo "3) 卸载脚本和快捷命令"
    echo "4) 检测 WARP 状态"
    echo "5) 开启检测接口异常并自动重启"
    echo "6) 停止自动检测功能"
    echo "7) 开启流媒体解锁检测（Netflix & Disney+）"
    echo "8) 停止流媒体解锁检测"
    echo "0) 退出"
    echo "==============================="
}

# 安装/配置 WARP
install_warp() {
    color_echo green "=== 更新系统并安装依赖 ==="
    sudo apt update && sudo apt install -y curl wget net-tools wireguard-tools

    color_echo green "=== 检测 CPU 架构 ==="
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)      WGCF_ARCH="amd64" ;;
        aarch64|arm64) WGCF_ARCH="arm64" ;;
        armv7l|armv6l) WGCF_ARCH="armv7" ;;
        i386|i686)   WGCF_ARCH="386" ;;
        *) color_echo red "不支持的架构: $ARCH"; read -p "按回车返回菜单..."; return ;;
    esac
    echo "检测到架构: $ARCH -> 下载 wgcf_${WGCF_ARCH}"

    color_echo green "=== 获取 wgcf 最新版本并下载 ==="
    WGCF_VER=$(curl -s https://api.github.com/repos/ViRb3/wgcf/releases/latest | grep tag_name | cut -d '"' -f4)
    FILE="wgcf_${WGCF_VER#v}_linux_${WGCF_ARCH}"
    URL="https://github.com/ViRb3/wgcf/releases/download/${WGCF_VER}/${FILE}"
    echo "正在下载 $URL"
    if ! wget -O wgcf "$URL"; then
        color_echo red "下载失败，请检查网络或稍后重试。"
        read -p "按回车返回菜单..."
        return
    fi
    chmod +x wgcf
    sudo mv wgcf /usr/local/bin/

    color_echo green "=== 注册 WARP 账户 ==="
    if [ ! -f wgcf-account.toml ]; then
        wgcf register --accept-tos
    fi

    read -p "是否输入 WARP+ License Key? (y/N): " use_warp_plus
    if [[ "$use_warp_plus" =~ ^[Yy]$ ]]; then
        read -p "请输入你的 WARP+ License Key: " warp_plus_key
        sed -i "s/license_key = .*/license_key = \"$warp_plus_key\"/" wgcf-account.toml
        color_echo green "已写入 WARP+ 授权密钥"
    fi

    color_echo green "=== 生成 WireGuard 配置文件 ==="
    wgcf generate

    color_echo green "=== 修改配置文件：IPv6 全局走 WARP，IPv4 保留本地出口 ==="
    WARP_IPV4=$(grep '^Address' wgcf-profile.conf | grep -oP '\d+\.\d+\.\d+\.\d+/\d+')
    sed -i "s#0\.0\.0\.0/0#${WARP_IPV4}#g" wgcf-profile.conf
    sudo mv wgcf-profile.conf /etc/wireguard/warp.conf

    color_echo green "
