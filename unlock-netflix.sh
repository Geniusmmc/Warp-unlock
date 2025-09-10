#!/usr/bin/env bash

# 要测试的 Netflix 剧集
# 原创剧（全区域可看），第三方授权剧（受区域限制）
# Netflix 测试：第三方授权剧在 SG 可看
NETFLIX_TESTS=(
  "80057281:stranger-things"      # 原创
  "70143836:modern-family"        # 在新加坡开放的授权剧（示例 ID）
)

# Disney+ 测试：授权纪录片或剧集
DISNEY_TESTS=(
  "series/the-mandalorian:mandalorian" 
  "series/planet-earth:planet-earth"      # 授权纪录片（示例 Slug）
)

# 支持 IPv4 和 IPv6
PROTOS=( "-4" "-6" )

# 根据协议与目标生成 URL 并检测状态
test_playback() {
  local proto=$1; shift
  local service=$1;   shift
  local id_slug=$1;    shift

  if [ "$service" = "netflix" ]; then
    url="https://www.netflix.com/title/$id_slug"
  else
    url="https://www.disneyplus.com/$id_slug"
  fi

  # 发起请求，获取 HTTP 状态码
  status=$(curl -s $proto -o /dev/null -w "%{http_code}" "$url")
  if [ "$status" = "200" ]; then
    echo "    ✔ 可访问"
  else
    echo "    ✖ 无法访问 (HTTP $status)"
  fi
}

# 主循环
for p in "${PROTOS[@]}"; do
  echo "========================================"
  echo "协议检测：${p#-}"

  echo "  Netflix 解锁检测："
  for t in "${NETFLIX_TESTS[@]}"; do
    IFS=":" read -r id slug <<< "$t"
    echo "  - [$slug] ($id):"
    test_playback "$p" "netflix" "$id"
  done

  echo ""
  echo "  Disney+ 解锁检测："
  for t in "${DISNEY_TESTS[@]}"; do
    IFS=":" read -r slug name <<< "$t"
    echo "  - [$name]:"
    test_playback "$p" "disney" "$slug"
  done

  echo ""
done

echo "========================================"
