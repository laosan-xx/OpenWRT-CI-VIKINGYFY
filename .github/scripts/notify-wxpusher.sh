#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY
# 通用 WxPusher 推送脚本
#   用法: notify-wxpusher.sh "<正文>" ["<摘要>"]
#   环境变量:
#     WXPUSHER_APP_TOKEN   应用 Token（AT_ 开头），必填，缺失则自动跳过
#     WXPUSHER_UIDS        订阅用户 UID，多个用逗号/空格分隔，可选
#     WXPUSHER_TOPIC_IDS   主题 ID，多个用逗号/空格分隔，可选
#     WXPUSHER_URL         点击消息跳转的链接，可选
# 注意: 任何异常都不返回非零退出码，避免影响 CI 结果

set -uo pipefail

CONTENT="${1:-${WXPUSHER_CONTENT:-}}"
SUMMARY="${2:-${WXPUSHER_SUMMARY:-OpenWrt CI 通知}}"
LINK="${WXPUSHER_URL:-${GITHUB_RUN_URL:-}}"
API='https://wxpusher.zjiecode.com/api/send/message'

if [ -z "${WXPUSHER_APP_TOKEN:-}" ]; then
	echo "::warning::未配置 WXPUSHER_APP_TOKEN，跳过 WxPusher 推送"
	exit 0
fi

if [ -z "$CONTENT" ]; then
	echo "::warning::推送内容为空，跳过 WxPusher 推送"
	exit 0
fi

# 支持逗号(含中文逗号)/分号/空白分隔的列表，交给 jq 处理避免 locale 问题
split_list() {
	jq -R -s -c 'gsub("[,，;；\\s]+"; "\n") | split("\n") | map(select(length > 0))' <<< "$1"
}

UIDS_JSON='[]'
if [ -n "${WXPUSHER_UIDS:-}" ]; then
	UIDS_JSON=$(split_list "$WXPUSHER_UIDS") || UIDS_JSON='[]'
fi

TOPIC_JSON='[]'
if [ -n "${WXPUSHER_TOPIC_IDS:-}" ]; then
	TOPIC_JSON=$(split_list "$WXPUSHER_TOPIC_IDS" | jq -c 'map(tonumber? // empty)') || TOPIC_JSON='[]'
fi

if [ "$UIDS_JSON" = '[]' ] && [ "$TOPIC_JSON" = '[]' ]; then
	echo "::warning::未配置 WXPUSHER_UIDS 或 WXPUSHER_TOPIC_IDS，跳过 WxPusher 推送"
	exit 0
fi

PAYLOAD=$(jq -n \
	--arg appToken "$WXPUSHER_APP_TOKEN" \
	--arg content "$CONTENT" \
	--arg summary "$SUMMARY" \
	--arg url "$LINK" \
	--argjson uids "$UIDS_JSON" \
	--argjson topicIds "$TOPIC_JSON" \
	'{appToken:$appToken, contentType:3, content:$content, summary:$summary, uids:$uids, topicIds:$topicIds}
	| if $url == "" then . else . + {url:$url} end')

echo "推送到 WxPusher: uids=$UIDS_JSON topicIds=$TOPIC_JSON"

RESP=$(curl -sS --max-time 20 -X POST "$API" -H 'Content-Type: application/json' -d "$PAYLOAD" 2>&1) || {
	echo "::warning::WxPusher 请求异常（网络问题或接口不可达），已忽略"
	exit 0
}

echo "$RESP"

if echo "$RESP" | jq -e '(.code // 0) == 1000' > /dev/null 2>&1; then
	echo "::notice::WxPusher 推送成功"
else
	echo "::warning::WxPusher 推送失败，请检查 Token / UID / 主题配置"
fi

exit 0
