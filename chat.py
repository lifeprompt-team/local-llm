"""mlx-lm でローカルLLMを叩く最小サンプル。

使い方:
    python chat.py                      # デフォルトのプロンプトで実行
    python chat.py "好きな質問をどうぞ"   # 引数でプロンプト指定

モデルを変えたいときは MODEL を書き換える（4bit/8bitの切り替えなど）。
"""

import sys

from mlx_lm import generate, load

# M3 Pro / 36GB なら精度重視で 8bit。メモリや速度を最優先したいなら 4bit に変える。
MODEL = "wcamon/Agents-A1-4B-MLX-4bit"


def main() -> None:
    prompt = sys.argv[1] if len(sys.argv) > 1 else "こんにちは、自己紹介してください。"

    model, tokenizer = load(MODEL)

    # チャット用テンプレートを適用してから生成する。
    messages = [{"role": "user", "content": prompt}]
    formatted = tokenizer.apply_chat_template(
        messages, add_generation_prompt=True
    )

    generate(
        model,
        tokenizer,
        prompt=formatted,
        max_tokens=512,
        verbose=True,  # 生成トークンと tok/s を表示
    )


if __name__ == "__main__":
    main()
