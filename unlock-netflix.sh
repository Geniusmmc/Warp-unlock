#!/usr/bin/env bash

# ===== 新加坡 Netflix 测试剧集 =====
NF_ORIGINAL_ID="80057281"   # Stranger Things
NF_NON_ORIGINAL_ID="70153404" # Friends

# ===== 新加坡 Disney+ 测试剧集 =====
DPLUS_ORIGINAL_SLUG="series/the-mandalorian/3jLIGMDYINqD"
DPLUS_NON_ORIGINAL_SLUG="series/the-simpsons/3ZoBZ52QHb4x"

# ===== 协议列表 =====
PROTOS=("-4" "-6")

UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/115.0 Safari/537.36"

check_netflix() {
    local proto=$1
    echo "  Netflix 检测："

    for id in "$NF_ORIGINAL_ID" "$NF_NON_ORIGINAL_ID"; do
        if [ "$id" = "$NF_ORIGINAL_ID" ]; then
            name="原创剧"
        else
            name="非自制剧"
        fi

        tmpfile=$(mktemp)
        status=$(curl -sL $proto -A "$UA" -o "$tmpfile" -w "%{http_code}" "https://www.netflix.com/title/$id")

        if grep -qi "not available|不可用" "$tmpfile"; then
            echo "    ✖ $name 区域受限"
        elif [ "$status" = "200" ]; then
            echo "    ✔ $name 可访问"
        else
            echo "    ✖ $name 无法访问 (HTTP $status)"
        fi
        rm -f "$tmpfile"
    done
}

check_disney() {
    local proto=$1
    echo "  Disney+ 检测："

    for slug in "$DPLUS_ORIGINAL_SLUG" "$DPLUS_NON_ORIGINAL_SLUG"; do
        if [ "$slug" = "$DPLUS_ORIGINAL_SLUG" ]; then
            name="原创剧"
        else
            name="非自制剧"
        fi

        tmpfile=$(mktemp)
        status=$(curl -sL $proto -A "$UA" -o "$tmpfile" -w "%{http_code}" "https://www.disneyplus.com/$slug")

        if grep -qi "not available|不可用" "$tmpfile"; then
            echo "    ✖ $name 区域受限"
        elif [ "$status" = "200" ]; then
            echo "    ✔ $name 可访问"
        else
            echo "    ✖ $name 无法访问 (HTTP $status)"
        fi
        rm -f "$tmpfile"
    done
}

# ===== 主程序 =====
for p in "${PROTOS[@]}"; do
    if [ "$p" = "-4" ]; then
        echo "========================================"
        echo "协议：IPv4"
    else
        echo "========================================"
        echo "协议：IPv6"
    fi

    country=$(curl -s $p https://ipapi.co/country 2>/dev/null)
    echo "  当前出口国家代码：$country"
    if [ "$country" != "SG" ]; then
        echo "  ⚠ 警告：当前出口不在新加坡，结果可能不准确"
    fi

    check_netflix "$p"
    check_disney "$p"
done

echo "========================================"
