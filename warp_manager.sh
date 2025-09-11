#!/bin/bash
# Cloudflare WARP 管理工具（修正版）
# 功能：安装/配置 WARP IPv6（支持 WARP+）、卸载接口、卸载脚本、检测状态、自动检测异常重启、流媒体解锁检测
# 接口名 warp，保留本地 IPv4，自动检测架构，支持开机自启，安装后自动注册 02 命令

# --- 全局变量与常量 ---
SERVICE_NAME="warp-monitor.service"
STREAM_SERVICE_NAME="warp-stream-monitor.service"
NETFLIX_SG_ID="81215567"

# --- 辅助函数 ---
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

check_warp_status() {
    local status ipv4 ipv6

    if ip link show warp >/dev/null 2>&1; then
        status="$(color_echo green "运行中 ✅")"
    else
        status="$(color_echo red "未运行 ❌")"
    fi

    ipv4=$(curl -4 -s --max-time 5 https://ip.gs || echo "不可用")
    ipv6=$(curl -6 -s --max-time 5 https://ip.gs || echo "不可用")

    echo "=== WARP 状态: $status ==="
    echo "出口 IPv4: $ipv4"
    echo "出口 IPv6: $ipv6"
    echo "=============================="
}

# --- 菜单功能函数 ---
show_menu() {
    clear
    check_warp_status
    echo "    Cloudflare WARP 管理菜单"
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

install_warp() {
    color_echo green "=== 更新系统并安装依赖 ==="
    sudo apt update && sudo apt install -y curl wget net-tools wireguard-tools python3

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
    WGCF_VER=$(curl -s https://api.github.com/repos/ViRb3/wgcf/releases/latest | grep '"tag_name"' | head -n1 | cut -d '"' -f4)
    if [[ -z "$WGCF_VER" ]]; then
        color_echo red "无法从 GitHub 获取 wgcf 版本信息，跳过下载。"
    else
        FILE="wgcf_${WGCF_VER#v}_linux_${WGCF_ARCH}"
        URL="https://github.com/ViRb3/wgcf/releases/download/${WGCF_VER}/${FILE}"
        echo "正在下载 $URL"
        if ! wget -O wgcf "$URL"; then
            color_echo red "wgcf 下载失败，尝试使用系统包或手动安装。"
        else
            chmod +x wgcf
            sudo mv wgcf /usr/local/bin/
        fi
    fi

    color_echo green "=== 注册 WARP 账户 ==="
    if [ ! -f wgcf-account.toml ]; then
        if command -v wgcf >/dev/null 2>&1; then
            wgcf register --accept-tos || true
        else
            color_echo yellow "未安装 wgcf，跳过注册步骤。"
        fi
    fi

    read -p "是否输入 WARP+ License Key? (y/N): " use_warp_plus
    if [[ "$use_warp_plus" =~ ^[Yy]$ ]]; then
        read -p "请输入你的 WARP+ License Key: " warp_plus_key
        if [ -f wgcf-account.toml ]; then
            sed -i "s/license_key = .*/license_key = \"$warp_plus_key\"/" wgcf-account.toml
            color_echo green "已写入 WARP+ 授权密钥"
        else
            color_echo red "找不到 wgcf-account.toml，无法写入密钥"
        fi
    fi

    color_echo green "=== 生成 WireGuard 配置文件 ==="
    if command -v wgcf >/dev/null 2>&1 && [ -f wgcf-account.toml ]; then
        wgcf generate || true
    else
        color_echo yellow "wgcf 未就绪，跳过 generate 步骤。"
    fi

    if [ -f wgcf-profile.conf ]; then
        color_echo green "=== 修改配置文件：IPv6 全局走 WARP，IPv4 保留本地出口 ==="
        WARP_IPV4=$(grep '^Address' wgcf-profile.conf | grep -oP '\d+\.\d+\.\d+\.\d+/\d+' || true)
        if [[ -n "$WARP_IPV4" ]]; then
            sed -i "s#0\.0\.0\.0/0#${WARP_IPV4}#g" wgcf-profile.conf
        fi
        sudo mv -f wgcf-profile.conf /etc/wireguard/warp.conf
    else
        color_echo yellow "wgcf-profile.conf 不存在，跳过配置移动步骤。"
    fi

    color_echo green "=== 启用 WireGuard 接口 warp ==="
    sudo wg-quick up warp 2>/dev/null || true

    color_echo green "=== 设置 warp 接口开机自启 ==="
    sudo systemctl enable wg-quick@warp 2>/dev/null || true

    check_warp_status
    read -p "按回车返回菜单..."
}

uninstall_warp_interface() {
    color_echo yellow "=== 停止并删除 WARP 接口 ==="
    sudo wg-quick down warp 2>/dev/null || true
    sudo systemctl disable wg-quick@warp 2>/dev/null || true
    sudo rm -f /etc/wireguard/warp.conf
    sudo rm -f wgcf-account.toml wgcf-profile.conf
    color_echo green "WARP 接口已卸载"
    read -p "按回车返回菜单..."
}

uninstall_script() {
    color_echo red "=== 卸载脚本和快捷命令 ==="
    sudo rm -f /usr/local/bin/02
    color_echo green "已删除 02 快捷命令"
    echo "请手动删除此脚本文件（如果存在）。"
    read -p "按回车返回菜单..."
}

enable_auto_restart() {
    read -p "请输入检测间隔（秒，建议 60~300）: " interval
    if ! [[ "$interval" =~ ^[0-9]+$ ]] || [ "$interval" -lt 10 ]; then
        color_echo red "检测间隔必须是 >=10 的数字"
        read -p "按回车返回菜单..."
        return
    fi

    color_echo green "=== 开启 WARP 接口异常检测并自动重启（间隔 ${interval} 秒） ==="
    sudo bash -c "cat > /usr/local/bin/warp-monitor.sh" <<'EOF'
#!/bin/bash
while true; do
    if ! ip link show warp >/dev/null 2>&1 || ! curl -6 -s --max-time 5 https://ip.gs >/dev/null; then
        echo "$(date) 检测到 WARP 异常，正在重启接口..."
        wg-quick down warp 2>/dev/null || true
        wg-quick up warp 2>/dev/null || true
    fi
    sleep ${INTERVAL_PLACEHOLDER}
done
EOF
    # 替换占位符为实际间隔（使用 sudo sed 编辑文件）
    sudo sed -i "s/\${INTERVAL_PLACEHOLDER}/$interval/g" /usr/local/bin/warp-monitor.sh
    sudo chmod +x /usr/local/bin/warp-monitor.sh

    sudo bash -c "cat > /etc/systemd/system/$SERVICE_NAME" <<EOF
[Unit]
Description=WARP 接口监控与自动重启
After=network.target

[Service]
Environment=PATH=/usr/bin:/usr/local/bin
ExecStart=/usr/local/bin/warp-monitor.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable --now $SERVICE_NAME
    color_echo green "自动检测功能已开启，每 ${interval} 秒检测一次 WARP 状态"
    read -p "按回车返回菜单..."
}

disable_auto_restart() {
    color_echo yellow "=== 停止 WARP 接口异常检测 ==="
    sudo systemctl disable --now $SERVICE_NAME 2>/dev/null || true
    sudo rm -f /etc/systemd/system/$SERVICE_NAME
    sudo rm -f /usr/local/bin/warp-monitor.sh
    sudo systemctl daemon-reload
    color_echo green "自动检测功能已停止"
    read -p "按回车返回菜单..."
}

enable_stream_monitor() {
    color_echo green "=== 开启流媒体解锁检测（仅 IPv6） ==="

    sudo bash -c "cat > /usr/local/bin/warp-stream-monitor.sh" <<'EOF'
#!/bin/bash
# WARP 流媒体解锁检测脚本（通过指定接口发出 IPv6 请求）
IFACE="warp"
UA_Browser="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
NIC="--interface $IFACE"
RETRY_COOLDOWN=10
MAX_CONSEC_FAILS=10
PAUSE_ON_MANY_FAILS=1800
SLEEP_WHEN_UNLOCKED=1800
LOG_PREFIX="[WARP-STREAM]"

log() { echo "$(date '+%F %T') ${LOG_PREFIX} $*"; }

get_ipv6() { curl -6 $NIC -A "$UA_Browser" -fsL --max-time 8 https://ip.gs || echo "不可用"; }

check_warp_ipv6() {
    local ip
    ip=$(get_ipv6)
    if [[ "$ip" == "不可用" || -z "$ip" ]]; then
        log "⚠️ WARP IPv6 不可用，尝试重启接口..."
        wg-quick down $IFACE >/dev/null 2>&1 || true
        wg-quick up $IFACE >/dev/null 2>&1 || true
        sleep $RETRY_COOLDOWN
        ip=$(get_ipv6)
        if [[ "$ip" == "不可用" || -z "$ip" ]]; then
            log "❌ WARP IPv6 仍不可用，等待 ${PAUSE_ON_MANY_FAILS} 秒后重试..."
            sleep $PAUSE_ON_MANY_FAILS
            return 1
        fi
    fi
    return 0
}

check_netflix() {
    local sg_id="81215567"
    local original_id="80018499"
    local region_id="$sg_id"
    local code_sg code_orig region

    code_sg=$(curl -6 $NIC -A "$UA_Browser" -fsL --max-time 10 --write-out "%{http_code}" --output /dev/null "https://www.netflix.com/title/${sg_id}" || echo "000")
    if [ "$code_sg" = "200" ]; then
        region=$(curl -6 $NIC -A "$UA_Browser" -fsL --max-time 10 --write-out "%{redirect_url}" --output /dev/null "https://www.netflix.com/title/${region_id}" 2>/dev/null | sed 's/.*com\/\([^\/-]\{2\}\).*/\1/' | tr '[:lower:]' '[:upper:]' || echo "US")
        region=${region:-"US"}
        echo "√(完整, $region)"
        return 0
    fi

    code_orig=$(curl -6 $NIC -A "$UA_Browser" -fsL --max-time 10 --write-out "%{http_code}" --output /dev/null "https://www.netflix.com/title/${original_id}" || echo "000")
    if [ "$code_orig" = "200" ]; then
        region=$(curl -6 $NIC -A "$UA_Browser" -fsL --max-time 10 --write-out "%{redirect_url}" --output /dev/null "https://www.netflix.com/title/${original_id}" 2>/dev/null | sed 's/.*com\/\([^\/-]\{2\}\).*/\1/' | tr '[:lower:]' '[:upper:]' || echo "US")
        region=${region:-"US"}
        echo "×(仅自制剧, $region)"
        return 1
    fi

    echo "×"
    return 1
}

check_disney() {
    # 该函数尽量保持与原逻辑一致，但做了容错，若流程任一步失败则返回 ×
    local pre_assertion assertion pre_cookie disney_cookie token_content is_banned is_403 refresh_token tmp_result region in_supported
    pre_assertion=$(curl -6 $NIC -A "$UA_Browser" -fsL --max-time 10 -X POST "https://disney.api.edge.bamgrid.com/devices" -H "authorization: Bearer ZGlzbmV5JmJyb3dzZXImMS4wLjA.Cu56AgSfBTDag5NiRA81oLHkDZfu5L3CKadnefEAY84" -H "content-type: application/json; charset=UTF-8" -d '{"deviceFamily":"browser","applicationRuntime":"chrome","deviceProfile":"windows","attributes":{}}' || echo "")
    assertion=$(echo "$pre_assertion" | python3 -m json.tool 2>/dev/null | grep assertion | cut -f4 -d'"' || echo "")
    if [ -z "$assertion" ]; then
        echo "×"
        return 1
    fi

    pre_cookie=$(curl -6 $NIC -fsL --max-time 10 "https://raw.githubusercontent.com/lmc999/RegionRestrictionCheck/main/cookies" | sed -n '1p' || echo "")
    disney_cookie=$(echo "$pre_cookie" | sed "s/DISNEYASSERTION/${assertion}/g")

    token_content=$(curl -6 $NIC -A "$UA_Browser" -fsL --max-time 10 -X POST "https://disney.api.edge.bamgrid.com/token" -H "authorization: Bearer ZGlzbmV5JmJyb3dzZXImMS4wLjA.Cu56AgSfBTDag5NiRA81oLHkDZfu5L3CKadnefEAY84" -d "$disney_cookie" || echo "")
    is_banned=$(echo "$token_content" | python3 -m json.tool 2>/dev/null | grep 'forbidden-location' || true)
    is_403=$(echo "$token_content" | grep '403 ERROR' || true)
    if [ -n "$is_banned$is_403" ]; then
        echo "×"
        return 1
    fi

    refresh_token=$(echo "$token_content" | python3 -m json.tool 2>/dev/null | grep 'refresh_token' | awk '{print $2}' | cut -f2 -d'"' || echo "")
    if [ -z "$refresh_token" ]; then
        echo "×"
        return 1
    fi

    fake_content=$(curl -6 $NIC -fsL --max-time 10 "https://raw.githubusercontent.com/lmc999/RegionRestrictionCheck/main/cookies" | sed -n '8p' || echo "")
    disney_content=$(echo "$fake_content" | sed "s/ILOVEDISNEY/${refresh_token}/g")

    tmp_result=$(curl -6 $NIC -A "$UA_Browser" -fsL --max-time 10 -X POST "https://disney.api.edge.bamgrid.com/graph/v1/device/graphql" -H "authorization: ZGlzbmV5JmJyb3dzZXImMS4wLjA.Cu56AgSfBTDag5NiRA81oLHkDZfu5L3CKadnefEAY84" -d "$disney_content" || echo "")
    region=$(echo "$tmp_result" | python3 -m json.tool 2>/dev/null | grep 'countryCode' | cut -f4 -d'"' || echo "")
    in_supported=$(echo "$tmp_result" | python3 -m json.tool 2>/dev/null | grep 'inSupportedLocation' | awk '{print $2}' | cut -f1 -d',' || echo "false")

    if [[ -n "$region" && "$in_supported" == "true" ]]; then
        echo "√($region)"
        return 0
    else
        echo "×"
        return 1
    fi
}

fail_count=0
while true; do
    if ! check_warp_ipv6; then
        continue
    fi

    ipv6=$(get_ipv6)
    nf_status=$(check_netflix)
    dx_status=$(check_disney)

    log "IPv6: ${ipv6} | Netflix: ${nf_status} | Disney: ${dx_status}"

    if [[ "$nf_status" == √* || "$dx_status" == √* ]]; then
        log "检测到解锁（至少一个服务），等待 ${SLEEP_WHEN_UNLOCKED} 秒后继续检测..."
        fail_count=0
        sleep $SLEEP_WHEN_UNLOCKED
        continue
    else
        ((fail_count++))
        log "未检测到解锁，连续失败次数: $fail_count"
        if [ "$fail_count" -ge $MAX_CONSEC_FAILS ]; then
            log "达到连续失败阈值 ($MAX_CONSEC_FAILS)，重启接口并暂停 ${PAUSE_ON_MANY_FAILS} 秒..."
            wg-quick down $IFACE >/dev/null 2>&1 || true
            wg-quick up $IFACE >/dev/null 2>&1 || true
            fail_count=0
            sleep $PAUSE_ON_MANY_FAILS
            continue
        fi
    fi

    sleep $RETRY_COOLDOWN
done
EOF

    sudo chmod +x /usr/local/bin/warp-stream-monitor.sh

    # 创建 systemd 服务单元并启用
    sudo bash -c "cat > /etc/systemd/system/$STREAM_SERVICE_NAME" <<EOF
[Unit]
Description=WARP 流媒体解锁监控 (IPv6)
After=network.target

[Service]
Environment=PATH=/usr/bin:/usr/local/bin
ExecStart=/usr/local/bin/warp-stream-monitor.sh
Restart=on-failure
RestartSec=15

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable --now $STREAM_SERVICE_NAME
    color_echo green "流媒体解锁检测已开启并由 systemd 管理（服务名: $STREAM_SERVICE_NAME）"
    read -p "按回车返回菜单..."
}

disable_stream_monitor() {
    color_echo yellow "=== 停止流媒体解锁检测 ==="
    sudo systemctl disable --now $STREAM_SERVICE_NAME 2>/dev/null || true
    sudo rm -f /etc/systemd/system/$STREAM_SERVICE_NAME
    sudo rm -f /usr/local/bin/warp-stream-monitor.sh
    sudo systemctl daemon-reload
    color_echo green "流媒体解锁功能已停止"
    read -p "按回车返回菜单..."
}

# --- 主逻辑 ---
if [ ! -f /usr/local/bin/02 ]; then
    color_echo yellow "正在创建快捷命令 '02'..."
    sudo bash -c "echo 'bash <(curl -fsSL https://raw.githubusercontent.com/Geniusmmc/Warp-unlock/main/warp_manager.sh)' > /usr/local/bin/02"
    sudo chmod +x /usr/local/bin/02
    color_echo green "快捷命令已创建，之后可直接输入 02 打开 WARP 管理菜单"
fi

if systemctl list-units --type=service | grep -q "$STREAM_SERVICE_NAME"; then
    color_echo yellow "检测到 $STREAM_SERVICE_NAME 服务，正在重新加载并重启..."
    sudo systemctl daemon-reload
    sudo systemctl restart "$STREAM_SERVICE_NAME"
fi

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
        8) disable_stream_monitor ;;
        0) exit 0 ;;
        *) color_echo red "无效选项"; read -p "按回车返回菜单..." ;;
    esac
done
