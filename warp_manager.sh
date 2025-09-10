#!/bin/bash
# Cloudflare WARP 管理工具（修正版）
# 功能：安装/配置 WARP IPv6（支持 WARP+）、卸载接口、卸载脚本、检测状态、自动检测并重启、流媒体解锁检测

set -u
SCRIPT_PATH="/usr/local/bin/warp"
SERVICE_NAME="warp-monitor.service"
STREAM_SERVICE_NAME="warp-stream-monitor.service"

# 检测 WARP 状态
check_warp_status() {
    local status ipv4 ipv6
    if ip link show warp >/dev/null 2>&1; then
        status="运行中 ✅"
        ipv4=$(curl -4 -s --max-time 5 https://ip.gs || echo "不可用")
        ipv6=$(curl -6 -s --max-time 5 https://ip.gs || echo "不可用")
    else
        status="未运行 ❌"
        ipv4="无"
        ipv6="无"
    fi
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
    sudo apt update
    sudo apt install -y curl wget net-tools wireguard-tools ca-certificates

    echo "=== 检测 CPU 架构 ==="
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)   WGCF_ARCH="amd64" ;;
        aarch64|arm64) WGCF_ARCH="arm64" ;;
        armv7l|armv6l) WGCF_ARCH="armv7" ;;
        i386|i686) WGCF_ARCH="386" ;;
        *) echo "不支持的架构: $ARCH"; read -p "按回车返回菜单..."; return ;;
    esac
    echo "检测到架构: $ARCH -> 使用 wgcf_${WGCF_ARCH}"

    echo "=== 获取 wgcf 最新版本并下载 ==="
    WGCF_VER=$(curl -s https://api.github.com/repos/ViRb3/wgcf/releases/latest | awk -F'"' '/tag_name/{print $4; exit}')
    if [ -z "$WGCF_VER" ]; then
        echo "无法获取 wgcf 版本信息，取消安装"
        read -p "按回车返回菜单..."
        return
    fi
    TMPDIR=$(mktemp -d)
    pushd "$TMPDIR" >/dev/null
    ARCHIVE="wgcf_${WGCF_VER#v}_linux_${WGCF_ARCH}.tar.gz"
    URL="https://github.com/ViRb3/wgcf/releases/download/${WGCF_VER}/${ARCHIVE}"
    echo "下载 $URL"
    if ! wget -q --show-progress "$URL" -O wgcf.tar.gz; then
        echo "下载失败，请检查网络或手动下载 $URL"
        popd >/dev/null
        rm -rf "$TMPDIR"
        read -p "按回车返回菜单..."
        return
    fi
    tar -xzf wgcf.tar.gz
    # 找到二进制并安装
    if [ -f ./wgcf ]; then
        chmod +x ./wgcf
        sudo mv ./wgcf /usr/local/bin/wgcf
    else
        # 在归档中可能存在子目录
        BIN_PATH=$(find . -type f -name wgcf -perm -111 | head -n1 || true)
        if [ -n "$BIN_PATH" ]; then
            chmod +x "$BIN_PATH"
            sudo mv "$BIN_PATH" /usr/local/bin/wgcf
        else
            echo "归档内未找到 wgcf 可执行文件，安装失败"
            popd >/dev/null
            rm -rf "$TMPDIR"
            read -p "按回车返回菜单..."
            return
        fi
    fi
    popd >/dev/null
    rm -rf "$TMPDIR"

    echo "=== 注册 WARP 账户（如需交互请按提示） ==="
    # 在当前用户目录下创建 wgcf 文件，若需 root 可改用 sudo -E
    if [ ! -f wgcf-account.toml ]; then
        wgcf register --accept-tos || { echo "wgcf register 失败"; read -p "按回车返回菜单..."; return; }
    fi

    read -p "是否输入 WARP+ License Key? (y/N): " use_warp_plus
    if [[ "$use_warp_plus" =~ ^[Yy]$ ]]; then
        read -p "请输入你的 WARP+ License Key: " warp_plus_key
        # 如果文件中已有 license_key，替换；否则追加
        if grep -q '^license_key' wgcf-account.toml 2>/dev/null; then
            sed -i "s/^license_key.*/license_key = \"$warp_plus_key\"/" wgcf-account.toml
        else
            echo "license_key = \"$warp_plus_key\"" >> wgcf-account.toml
        fi
        echo "已写入 WARP+ 授权密钥（wgcf-account.toml）"
    fi

    echo "=== 生成 WireGuard 配置文件 ==="
    wgcf generate || { echo "wgcf generate 失败"; read -p "按回车返回菜单..."; return; }

    # 确保 /etc/wireguard 存在
    sudo mkdir -p /etc/wireguard
    # 提取生成配置中的 IPv4 地址（形如 192.0.2.2/32）
    if [ -f wgcf-profile.conf ]; then
        # 查找首个 IPv4 地址（Address 行中可能包含多个）
        WARP_IPV4=$(awk -F' ' '/^Address/{for(i=2;i<=NF;i++){ if($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/){print $i; exit}}}' wgcf-profile.conf || true)
        if [ -z "$WARP_IPV4" ]; then
            echo "未能从 wgcf-profile.conf 提取到 IPv4 地址，保留默认路由设置"
            sudo mv wgcf-profile.conf /etc/wireguard/warp.conf
        else
            # 将 0.0.0.0/0 替换为仅 IPv4 地址（谨慎替换）
            sed "s/0\.0\.0\.0\/0/${WARP_IPV4}/g" wgcf-profile.conf | sudo tee /etc/wireguard/warp.conf >/dev/null
        fi
        sudo chmod 600 /etc/wireguard/warp.conf
    else
        echo "找不到 wgcf-profile.conf，安装终止"
        read -p "按回车返回菜单..."
        return
    fi

    echo "=== 启用 WireGuard 接口 warp ==="
    sudo wg-quick up warp || echo "wg-quick up warp 返回非 0（可能已在运行）"

    echo "=== 设置 warp 接口开机自启 ==="
    sudo systemctl enable wg-quick@warp || true

    check_warp_status
    read -p "按回车返回菜单..."
}

# 卸载 WARP 接口
uninstall_warp_interface() {
    echo "=== 停止并删除 WARP 接口 ==="
    sudo wg-quick down warp 2>/dev/null || true
    sudo systemctl disable wg-quick@warp 2>/dev/null || true
    sudo rm -f /etc/wireguard/warp.conf
    rm -f wgcf-account.toml wgcf-profile.conf 2>/dev/null || true
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
    # 使用未展开的 $(date)（写入脚本时需转义），但让 ${interval} 被当前 shell 展开
    sudo bash -c "cat > /usr/local/bin/warp-monitor.sh" <<EOF
#!/bin/bash
while true; do
    if ! ip link show warp >/dev/null 2>&1 || ! curl -6 -s --max-time 5 https://ip.gs >/dev/null; then
        echo "\$(date) 检测到 WARP 异常，正在重启接口..."
        wg-quick down warp 2>/dev/null || true
        wg-quick up warp
    fi
    sleep ${interval}
done
EOF

    sudo chmod +x /usr/local/bin/warp-monitor.sh

    sudo bash -c "cat > /etc/systemd/system/$SERVICE_NAME" <<'UNIT'
[Unit]
Description=WARP 接口监控与自动重启
After=network.target

[Service]
ExecStart=/usr/local/bin/warp-monitor.sh
Restart=always

[Install]
WantedBy=multi-user.target
UNIT

    sudo systemctl daemon-reload
    sudo systemctl enable --now "$SERVICE_NAME"
    echo "自动检测功能已开启，每 ${interval} 秒检测一次 WARP 状态"
    read -p "按回车返回菜单..."
}

# 停止自动检测
disable_auto_restart() {
    echo "=== 停止 WARP 接口异常检测 ==="
    sudo systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
    sudo rm -f /etc/systemd/system/"$SERVICE_NAME"
    sudo rm -f /usr/local/bin/warp-monitor.sh
    sudo systemctl daemon-reload
    echo "自动检测功能已停止"
    read -p "按回车返回菜单..."
}

# 开启流媒体解锁检测（Netflix & Disney+）
enable_stream_monitor() {
    echo "=== 开启流媒体解锁检测（每 30 分钟检测一次） ==="
    sudo bash -c "cat > /usr/local/bin/warp-stream-monitor.sh" <<'EOF'
#!/bin/bash
while true; do
    nf=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" https://www.netflix.com/title/80018499)
    ds=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" https://www.disneyplus.com)
    if [ "$nf" != "200" ] || [ "$ds" != "200" ]; then
        echo "$(date) 检测到流媒体未解锁，正在更换 WARP IP..."
        wg-quick down warp 2>/dev/null || true
        wg-quick up warp
    else
        echo "$(date) 流媒体检测正常（Netflix: $nf, Disney+: $ds）"
    fi
    sleep 1800   # 30 分钟检测一次
done
EOF
    sudo chmod +x /usr/local/bin/warp-stream-monitor.sh

    sudo bash -c "cat > /etc/systemd/system/$STREAM_SERVICE_NAME" <<'UNIT'
[Unit]
Description=WARP 流媒体解锁检测
After=network.target

[Service]
ExecStart=/usr/local/bin/warp-stream-monitor.sh
Restart=always

[Install]
WantedBy=multi-user.target
UNIT

    sudo systemctl daemon-reload
    sudo systemctl enable --now "$STREAM_SERVICE_NAME"
    echo "流媒体解锁检测已开启，每 30 分钟检测一次"
    read -p "按回车返回菜单..."
}

# 停止流媒体检测
disable_stream_monitor() {
    echo "=== 停止流媒体解锁检测 ==="
    sudo systemctl disable --now "$STREAM_SERVICE_NAME" 2>/dev/null || true
    sudo rm -f /etc/systemd/system/"$STREAM_SERVICE_NAME"
    sudo rm -f /usr/local/bin/warp-stream-monitor.sh
    sudo systemctl daemon-reload
    echo "流媒体检测已停止"
    read -p "按回车返回菜单..."
}

# 主循环
while true; do
    show_menu
    read -rp "请选择 (0-8): " choice
    case "$choice" in
        1) install_warp ;;
        2) uninstall_warp_interface ;;
        3) uninstall_script ;;
        4) check_warp_status; read -p "按回车返回菜单..." ;;
        5) enable_auto_restart ;;
        6) disable_auto_restart ;;
        7) enable_stream_monitor ;;
        8) disable_stream_monitor ;;
        0) echo "退出"; exit 0 ;;
        *) echo "无效选项"; sleep 1 ;;
    esac
done
