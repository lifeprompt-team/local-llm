#!/usr/bin/env bash
# mlx-lm の OpenAI 互換サーバーを起動する。
# 使い方: ./serve.sh [PORT]   (省略時は 8088)
set -euo pipefail

cd "$(dirname "$0")"

PORT="${1:-8088}"
MODEL="wcamon/Agents-A1-4B-MLX-4bit"
# 大きめで精度重視に振るなら:
# MODEL="LiquidAI/LFM2.5-8B-A1B-MLX-8bit"

echo "starting mlx_lm.server  model=$MODEL  port=$PORT"
exec uv run mlx_lm.server --model "$MODEL" --port "$PORT"
