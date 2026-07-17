import json

import anthropic

from config import config

_client = anthropic.Anthropic(api_key=config.anthropic_api_key)

_PROMPT = """あなたは音声クローン学習用データセットの区間選定を行うアシスタントです。
以下は音声の文字起こし結果です（各行はタイムスタンプ付きセグメント）。
この会話から、音声クローン学習に適した区間を選んでください。

条件:
- 各区間は30秒〜3分程度
- 文の途中で区切らない（セグメント境界で区切る）
- 話題として自然にまとまる単位にする

出力は次のJSON配列のみを返してください（説明文やコードブロック記法は不要）:
[
  {{"start": 開始秒(数値), "end": 終了秒(数値), "topic": "話題の要約", "reason": "採用理由"}}
]

文字起こし:
{transcript}
"""


def segment(transcript_segments):
    lines = "\n".join(
        f"[{seg['start']:.1f}-{seg['end']:.1f}] {seg['text']}"
        for seg in transcript_segments
    )

    message = _client.messages.create(
        model=config.claude_model,
        max_tokens=4096,
        messages=[{"role": "user", "content": _PROMPT.format(transcript=lines)}],
    )

    text = message.content[0].text.strip()
    return json.loads(text)
