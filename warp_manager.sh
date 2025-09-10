#!/bin/bash
# Cloudflare WARP 管理工具
# 功能：安装/配置 WARP IPv6（支持 WARP+）、卸载接口、卸载脚本、检测状态、自动检测异常重启、流媒体解锁检测
# 接口名 warp，保留本地 IPv4，自动检测架构，支持开机自启，安装后自动注册 warp 命令

SCRIPT_PATH="/usr/local/bin/warp"
SERVICE_NAME="warp-monitor.service"
STREAM_SERVICE_NAME="warp-stream-monitor.service"

# 检测 WARP 状态
check_warp_status() {
    local status ipv4 ipv6

    if ip link show warp >/dev/null 2>&1; then
        status="运行中 ✅"
    else
        status="未运行 ❌"
    fi

    # 不管 warp 是否运行，都检测本机出口
    ipv4=$(curl -4 -s --max-time 5 https://ip.gs || echo "不可用")
    ipv6=$(curl -6 -s --max-time 5 https://ip.gs || echo "不可用")

    echo "=== WARP 状态: $status ==="
    echo "出口 IPv4: $ipv4"
    echo "出口 IPv6: $ipv6"
    echo "=============================="
}

# 菜单
show_menu() {
    clear
    check_warp_status
    echo "   Cloudflare WARP 管理菜单"
    echo "=============================="
    echo "1) 安装/配置 WARP IPv6"
    echo "2) 卸载 WARP 接口"
    echo "3) 卸载脚本和快捷命令"
    echo "4) 检测 WARP 状态"
    echo "5) 开启检测接口异常并自动重启"
    echo "6) 停止自动检测功能"
    echo "7) 开启流媒体解锁检测（Netflix & Disney+）"
    echo "8) 停止流媒体解锁检测"
    echo "0) 退出"
    echo "=============================="
}

# 安装/配置 WARP
install_warp() {
    echo "=== 更新系统并安装依赖 ==="
    sudo apt update && sudo apt install -y curl wget net-tools wireguard-tools

    echo "=== 检测 CPU 架构 ==="
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)   WGCF_ARCH="amd64" ;;
        aarch64|arm64) WGCF_ARCH="arm64" ;;
        armv7l|armv6l) WGCF_ARCH="armv7" ;;
        i386|i686) WGCF_ARCH="386" ;;
        *) echo "不支持的架构: $ARCH"; read -p "按回车返回菜单..."; return ;;
    esac
    echo "检测到架构: $ARCH -> 下载 wgcf_${WGCF_ARCH}"

    echo "=== 获取 wgcf 最新版本并下载 ==="
    WGCF_VER=$(curl -s https://api.github.com/repos/ViRb3/wgcf/releases/latest | grep tag_name | cut -d '"' -f4)
    FILE="wgcf_${WGCF_VER#v}_linux_${WGCF_ARCH}"
    URL="https://github.com/ViRb3/wgcf/releases/download/${WGCF_VER}/${FILE}"
    echo "下载 $URL"
    wget -O wgcf "$URL" || { echo "下载失败，请手动下载 $URL 并放置到 /usr/local/bin/wgcf"; read -p "按回车返回菜单..."; return; }
    chmod +x wgcf
    sudo mv wgcf /usr/local/bin/

    echo "=== 注册 WARP 账户 ==="
    if [ ! -f wgcf-account.toml ]; then
        wgcf register --accept-tos
    fi

    read -p "是否输入 WARP+ License Key? (y/N): " use_warp_plus
    if [[ "$use_warp_plus" =~ ^[Yy]$ ]]; then
        read -p "请输入你的 WARP+ License Key: " warp_plus_key
        sed -i "s/license_key = .*/license_key = \"$warp_plus_key\"/" wgcf-account.toml
        echo "已写入 WARP+ 授权密钥"
    fi

    echo "=== 生成 WireGuard 配置文件 ==="
    wgcf generate

    echo "=== 修改配置文件：IPv6 全局走 WARP，IPv4 保留本地出口 ==="
    WARP_IPV4=$(grep '^Address' wgcf-profile.conf | grep -oP '\d+\.\d+\.\d+\.\d+/\d+')
    sed -i "s#0\.0\.0\.0/0#${WARP_IPV4}#g" wgcf-profile.conf
    sudo mv wgcf-profile.conf /etc/wireguard/warp.conf

    echo "=== 启用 WireGuard 接口 warp ==="
    sudo wg-quick up warp

    echo "=== 设置 warp 接口开机自启 ==="
    sudo systemctl enable wg-quick@warp

    check_warp_status
    read -p "按回车返回菜单..."
}

# 卸载 WARP 接口
uninstall_warp_interface() {
    echo "=== 停止并删除 WARP 接口 ==="
    sudo wg-quick down warp 2>/dev/null || true
    sudo systemctl disable wg-quick@warp 2>/dev/null || true
    sudo rm -f /etc/wireguard/warp.conf
    sudo rm -f wgcf-account.toml wgcf-profile.conf
    echo "WARP 接口已卸载"
    read -p "按回车返回菜单..."
}

# 卸载脚本
uninstall_script() {
    echo "=== 卸载脚本和快捷命令 ==="
    sudo rm -f "$SCRIPT_PATH"
    echo "已删除 warp 快捷命令"
    exit 0
}

# 开启自动检测并重启（接口异常）
enable_auto_restart() {
    read -p "请输入检测间隔（秒，建议 60~300）: " interval
    if ! [[ "$interval" =~ ^[0-9]+$ ]] || [ "$interval" -lt 10 ]; then
        echo "检测间隔必须是 >=10 的数字"
        read -p "按回车返回菜单..."
        return
    fi

    echo "=== 开启 WARP 接口异常检测并自动重启（间隔 ${interval} 秒） ==="
    sudo bash -c "cat > /usr/local/bin/warp-monitor.sh" <<EOF
#!/bin/bash
while true; do
    if ! ip link show warp >/dev/null 2>&1 || ! curl -6 -s --max-time 5 https://ip.gs >/dev/null; then
        echo "\$(date) 检测到 WARP 异常，正在重启接口..."
        wg-quick down warp 2>/dev/null
        wg-quick up warp
    fi
    sleep ${interval}
done
EOF
    sudo chmod +x /usr/local/bin/warp-monitor.sh

    sudo bash -c "cat > /etc/systemd/system/$SERVICE_NAME" <<EOF
[Unit]
Description=WARP 接口监控与自动重启
After=network.target

[Service]
ExecStart=/usr/local/bin/warp-monitor.sh
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable --now $SERVICE_NAME
    echo "自动检测功能已开启，每 ${interval} 秒检测一次 WARP 状态"
    read -p "按回车返回菜单..."
}

# 停止自动检测
disable_auto_restart() {
    echo "=== 停止 WARP 接口异常检测 ==="
    sudo systemctl disable --now $SERVICE_NAME 2>/dev/null || true
    sudo rm -f /etc/systemd/system/$SERVICE_NAME
    sudo rm -f /usr/local/bin/warp-monitor.sh
    sudo systemctl daemon-reload
    echo "自动检测功能已停止"
    read -p "按回车返回菜单..."
}

enable_stream_monitor() {
    echo "=== 开启流媒体解锁检测（未解锁立即换 IP，解锁后 30 分钟检测一次） ==="

    # 先立即检测一次（只检测 IPv6）
    ipv6=$(curl -6 -s --max-time 5 https://ip.gs || echo "不可用")
    nf=$(curl -6 -s --max-time 10 https://www.netflix.com/title/80018499 -o /dev/null -w "%{http_code}")
    ds=$(curl -6 -s --max-time 10 https://www.disneyplus.com -o /dev/null -w "%{http_code}")
    echo "当前出口 IPv6: $ipv6"
    echo "Netflix 检测结果: $nf"
    echo "Disney+ 检测结果: $ds"
    echo "======================================"

    # 写入后台检测脚本
    sudo bash -c "cat > /usr/local/bin/warp-stream-monitor.sh" <<'EOF'
#!/bin/bash
# 只检测 IPv6 出口和流媒体解锁情况
MAX_FAILS=5
PAUSE_TIME=300
fail_count=0

while true; do
    # 获取当前出口 IPv6
    ipv6=$(curl -6 -s --max-time 5 https://ip.gs || echo "不可用")

    # 用 IPv6 检测 Netflix 和 Disney+
    nf=$(curl -6 -s --max-time 10 https://www.netflix.com/title/80018499 -o /dev/null -w "%{http_code}")
    ds=$(curl -6 -s --max-time 10 https://www.disneyplus.com -o /dev/null -w "%{http_code}")

    if [ "$nf" != "200" ] || [ "$ds" != "200" ]; then
        ((fail_count++))
        echo "$(date) [IPv6: $ipv6] ❌ 未解锁（Netflix: $nf, Disney+: $ds），连续失败 ${fail_count} 次 → 更换 WARP IP..."
        wg-quick down warp 2>/dev/null
        wg-quick up warp
        echo "$(date) 已更换 WARP IP，等待 10 秒后继续检测..."
        sleep 10
        if [ "$fail_count" -ge "$MAX_FAILS" ]; then
            echo "$(date) ⚠️ 连续失败 ${MAX_FAILS} 次，暂停 ${PAUSE_TIME} 秒..."
            sleep $PAUSE_TIME
            fail_count=0
        fi
    else
        echo "$(date) [IPv6: $ipv6] ✅ 已解锁（Netflix: $nf, Disney+: $ds），30 分钟后检测"
        fail_count=0
        sleep 1800
    fi
done
EOF

    sudo chmod +x /usr/local/bin/warp-stream-monitor.sh

    sudo bash -c "cat > /etc/systemd/system/$STREAM_SERVICE_NAME" <<EOF
[Unit]
Description=WARP 流媒体解锁检测（IPv6）
After=network.target

[Service]
ExecStart=/usr/local/bin/warp-stream-monitor.sh
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable --now $STREAM_SERVICE_NAME
    echo "流媒体解锁检测已开启（IPv6 模式）"
    echo "=== 正在实时显示检测结果（按 Ctrl+C 退出查看，但服务会继续后台运行） ==="
    sudo journalctl -u $STREAM_SERVICE_NAME -f -n 0
}



# 主循环
while true; do
    show_menu
    read -p "请选择操作 [0-8]: " choice
    case $choice in
        1) install_warp ;;
        2) uninstall_warp_interface ;;
        3) uninstall_script ;;
        4) check_warp_status; read -p "按回车返回菜单..." ;;
        5) enable_auto_restart ;;
        6) disable_auto_restart ;;
        7) enable_stream_monitor ;;
        8) sudo systemctl disable --now $STREAM_SERVICE_NAME 2>/dev/null || true
           sudo rm -f /etc/systemd/system/$STREAM_SERVICE_NAME
           sudo rm -f /usr/local/bin/warp-stream-monitor.sh
           sudo systemctl daemon-reload
           echo "流媒体解锁检测已停止"
           read -p "按回车返回菜单..." ;;
        0) exit 0 ;;
        *) echo "无效选项"; read -p "按回车返回菜单..." ;;
    esac
done
