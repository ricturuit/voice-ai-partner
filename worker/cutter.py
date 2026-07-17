import subprocess

from config import config

# I=-16 LUFS / TP=-1.5dBTP はEBU R128準拠のポッドキャスト向け目安値。
# クリップごとに音量を揃え、音声クローン学習時の音量ばらつきを抑える。
_LOUDNORM_FILTER = "loudnorm=I=-16:TP=-1.5:LRA=11"


def cut(input_path, output_path, start, end):
    duration = end - start
    subprocess.run(
        [
            config.ffmpeg_path,
            "-y",
            "-ss", str(start),
            "-i", input_path,
            "-t", str(duration),
            "-af", _LOUDNORM_FILTER,
            "-ar", "44100",
            "-ac", "1",
            output_path,
        ],
        check=True,
        capture_output=True,
    )
