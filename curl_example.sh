#!/usr/bin/env bash
# 起動中の mlx-lm サーバーに OpenAI 互換 API で問い合わせる。
# 使い方: ./curl_example.sh [PORT] ["プロンプト"]
set -euo pipefail

PORT="${1:-8088}"
PROMPT="${2:-こんにちは、自己紹介して}"

PAYLOAD="$(python3 - "${PROMPT}" <<'PY'
import json
import sys

print(json.dumps({
    "model": "wcamon/Agents-A1-4B-MLX-4bit",
    "messages": [{"role": "user", "content": sys.argv[1]}],
    "temperature": 0.7,
    "max_tokens": 512,
}, ensure_ascii=False))
PY
)"

curl -s "http://localhost:${PORT}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  --data-binary "${PAYLOAD}"
echo
