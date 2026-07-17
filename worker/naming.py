import re
from datetime import datetime
from pathlib import Path

import pykakasi

_kakasi = pykakasi.kakasi()
_UNSAFE_CHARS = re.compile(r'[\\/:*?"<>|\s、。・,]+')


def romanize(text):
    """日本語（かな/漢字）をヘボン式ローマ字に変換する。英数字はそのまま。"""
    return "".join(item["hepburn"] for item in _kakasi.convert(text))


def sanitize(text):
    """ファイル名として安全な形に整える（記号・空白类をアンダースコアに置換）。"""
    return _UNSAFE_CHARS.sub("_", text).strip("_")


def build_clip_filename(source_filename, uploaded_at, label, used_names):
    """`{YYYYMMDD}_{元ファイル名(ローマ字)}_{話題ラベル}.wav` 形式のファイル名を作る。
    同名が既にある場合は連番を付けて重複を避ける。"""
    date_str = datetime.fromisoformat(uploaded_at.replace("Z", "+00:00")).strftime("%Y%m%d")
    stem = sanitize(romanize(Path(source_filename).stem))
    label_part = sanitize(label)
    base = f"{date_str}_{stem}_{label_part}"

    name = f"{base}.wav"
    n = 2
    while name in used_names:
        name = f"{base}_{n}.wav"
        n += 1
    used_names.add(name)
    return name
