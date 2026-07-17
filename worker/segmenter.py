import json
import re

import anthropic

from config import config
from quality import NO_SPEECH_PROB_THRESHOLD, is_laughter

_CODE_FENCE = re.compile(r"^```(?:json)?\s*\n?(.*?)\n?```$", re.DOTALL)

_client = anthropic.Anthropic(api_key=config.anthropic_api_key)

_PROMPT = """あなたは音声クローン学習用データセットの区間選定を行うアシスタントです。
以下は音声の文字起こし結果です（各行はタイムスタンプ付きセグメント）。
[NOISE]は無音/雑音の可能性が高い区間、[LAUGH]は笑い声の可能性がある区間を示す注記です。
この会話から、音声クローン学習に適した区間を選んでください。

条件:
- 各区間は30秒〜3分程度
- 文の途中で区切らない（セグメント境界で区切る）
- 話題として自然にまとまる単位にする
- [NOISE][LAUGH]の注記がある区間はできるだけ避け、区間の開始・終了の境界にも含めない

出力は次のJSON配列のみを返してください（説明文やコードブロック記法は不要）:
[
  {{
    "start": 開始秒(数値),
    "end": 終了秒(数値),
    "topic": "話題の要約",
    "label": "ファイル名用の短いラベル(日本語可、記号・スペースなし、10文字程度以内、例: 衣装制作)",
    "reason": "採用理由"
  }}
]

文字起こし:
{transcript}
"""


def _annotate(seg):
    tags = []
    if seg["no_speech_prob"] > NO_SPEECH_PROB_THRESHOLD:
        tags.append("NOISE")
    if is_laughter(seg["text"]):
        tags.append("LAUGH")
    prefix = f"[{'/'.join(tags)}] " if tags else ""
    return f"[{seg['start']:.1f}-{seg['end']:.1f}] {prefix}{seg['text']}"


def segment(transcript_segments):
    lines = "\n".join(_annotate(seg) for seg in transcript_segments)

    message = _client.messages.create(
        model=config.claude_model,
        max_tokens=16000,
        thinking={"type": "disabled"},
        messages=[{"role": "user", "content": _PROMPT.format(transcript=lines)}],
    )

    text = "".join(block.text for block in message.content if block.type == "text").strip()

    fence_match = _CODE_FENCE.match(text)
    if fence_match:
        text = fence_match.group(1).strip()

    try:
        return json.loads(text)
    except json.JSONDecodeError as e:
        raise RuntimeError(
            f"Claudeの応答をJSONとして解析できませんでした(応答が途中で切れたか、"
            f"想定外の形式だった可能性があります): {e}\n応答冒頭: {text[:200]!r}"
        ) from e
