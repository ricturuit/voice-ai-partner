import subprocess

from config import config


def cut(input_path, output_path, start, end):
    subprocess.run(
        [
            config.ffmpeg_path,
            "-y",
            "-i", input_path,
            "-ss", str(start),
            "-to", str(end),
            "-ar", "44100",
            "-ac", "1",
            output_path,
        ],
        check=True,
        capture_output=True,
    )
