import json
import re
import subprocess

from config import config

NO_SPEECH_PROB_THRESHOLD = 0.5
LAUGHTER_RATIO_THRESHOLD = 0.3

_LAUGHTER_PATTERN = re.compile(
    r"(?:笑|ｗ{2,}|w{3,}|(?:あは){2,}|(?:はは){2,}|(?:へへ){2,}|(?:うふ){2,}|haha|hahaha|lol|lmao)",
    re.IGNORECASE,
)


def is_laughter(text):
    return bool(_LAUGHTER_PATTERN.search(text))


def _probe(path):
    result = subprocess.run(
        [
            config.ffprobe_path, "-v", "quiet", "-print_format", "json",
            "-show_format", "-show_streams", path,
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout)


def check_source_quality(path):
    info = _probe(path)
    audio_streams = [s for s in info.get("streams", []) if s.get("codec_type") == "audio"]
    if not audio_streams:
        return False, "音声ストリームが見つかりません"

    stream = audio_streams[0]
    sample_rate = int(stream.get("sample_rate", 0) or 0)
    bit_rate = stream.get("bit_rate") or info.get("format", {}).get("bit_rate")
    bit_rate_kbps = int(bit_rate) / 1000 if bit_rate else 0

    if sample_rate and sample_rate < config.min_sample_rate_hz:
        return False, f"サンプルレートが低すぎます ({sample_rate}Hz < {config.min_sample_rate_hz}Hz)"
    if bit_rate_kbps and bit_rate_kbps < config.min_bitrate_kbps:
        return False, f"ビットレートが低すぎます ({bit_rate_kbps:.0f}kbps < {config.min_bitrate_kbps}kbps)"

    return True, ""


def _overlapping(start, end, whisper_segments):
    return [s for s in whisper_segments if s["end"] > start and s["start"] < end]


def evaluate_clip(spec, whisper_segments):
    segs = _overlapping(spec["start"], spec["end"], whisper_segments)
    total = sum(s["end"] - s["start"] for s in segs)
    if not segs or total <= 0:
        return False, "対応する文字起こしセグメントが見つかりません"

    weighted_no_speech = sum(s["no_speech_prob"] * (s["end"] - s["start"]) for s in segs) / total
    if weighted_no_speech > NO_SPEECH_PROB_THRESHOLD:
        return False, f"無音/雑音主体の可能性が高いため除外 (no_speech_prob={weighted_no_speech:.2f})"

    laughter_duration = sum(s["end"] - s["start"] for s in segs if is_laughter(s["text"]))
    laughter_ratio = laughter_duration / total
    if laughter_ratio > LAUGHTER_RATIO_THRESHOLD:
        return False, f"笑い声主体の可能性が高いため除外 (笑い比率={laughter_ratio:.0%})"

    return True, ""
