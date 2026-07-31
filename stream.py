"""起動中の mlx-lm サーバーに OpenAI 互換 API でストリーミング問い合わせするクライアント。

依存は標準ライブラリのみ（uv run 不要、python3 だけで動く）。

使い方:
    python stream.py "自己紹介して"
    python stream.py "2+3は？" --reasoning          # 思考パートも表示
    python stream.py "翻訳して: hello" --system "あなたは翻訳家です"
    python stream.py "質問" --port 9000 --max-tokens 1024
"""

import argparse
import json
import urllib.request

DEFAULT_SYSTEM = "あなたは日本語で回答するアシスタントです。常に日本語で考え、日本語で答えてください。"
MODEL = "wcamon/Agents-A1-4B-MLX-4bit"


def main() -> None:
    parser = argparse.ArgumentParser(description="mlx-lm サーバーへのストリーミングクライアント")
    parser.add_argument("prompt", help="ユーザープロンプト")
    parser.add_argument("--system", default=DEFAULT_SYSTEM, help="system メッセージ")
    parser.add_argument("--port", type=int, default=8088, help="サーバーのポート (既定: 8088)")
    parser.add_argument("--max-tokens", type=int, default=512)
    parser.add_argument("--temperature", type=float, default=0.7)
    parser.add_argument("-r", "--reasoning", action="store_true", help="思考パートも表示する")
    args = parser.parse_args()

    payload = {
        "model": MODEL,
        "messages": [
            {"role": "system", "content": args.system},
            {"role": "user", "content": args.prompt},
        ],
        "temperature": args.temperature,
        "max_tokens": args.max_tokens,
        "stream": True,
    }

    req = urllib.request.Request(
        f"http://localhost:{args.port}/v1/chat/completions",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    mode = None
    with urllib.request.urlopen(req) as resp:
        for raw in resp:
            line = raw.decode("utf-8").strip()
            if not line.startswith("data: "):
                continue
            data = line[len("data: ") :]
            if data == "[DONE]":
                break
            delta = json.loads(data)["choices"][0].get("delta", {})

            reasoning = delta.get("reasoning")
            if reasoning and args.reasoning:
                if mode != "r":
                    print("\n===== reasoning =====", flush=True)
                    mode = "r"
                print(reasoning, end="", flush=True)

            content = delta.get("content")
            if content:
                if mode != "c":
                    header = "\n\n===== answer =====" if args.reasoning else ""
                    if header:
                        print(header, flush=True)
                    mode = "c"
                print(content, end="", flush=True)
    print()


if __name__ == "__main__":
    main()
