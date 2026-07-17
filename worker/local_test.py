"""AWS(S3/SQS)を使わず、ローカルの音声ファイルだけでWhisper→Claude→ffmpegの
一連の処理を試すためのスクリプト。AWSインフラをデプロイする前の疎通確認用。

使い方:
    python local_test.py path/to/sample.m4a ./local_test_output
"""

import argparse
import logging
from pathlib import Path

import cutter
import quality
import report
import segmenter
import transcribe

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("local_test")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("audio_path", help="入力音声ファイル (m4a/aac/wav等)")
    parser.add_argument("output_dir", help="出力先ディレクトリ")
    args = parser.parse_args()

    audio_path = Path(args.audio_path)
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    ok, reason = quality.check_source_quality(str(audio_path))
    if not ok:
        log.error("音質チェックで却下されました: %s", reason)
        return

    log.info("文字起こし中...")
    segments = transcribe.transcribe(str(audio_path))
    log.info("文字起こし完了: %d セグメント", len(segments))

    log.info("Claudeへ区間分割を依頼中...")
    clip_specs = segmenter.segment(segments)
    log.info("候補区間: %d件", len(clip_specs))

    clips = []
    excluded = []
    clip_index = 0
    for spec in clip_specs:
        ok, reason = quality.evaluate_clip(spec, segments)
        if not ok:
            excluded.append({**spec, "reason": reason})
            log.info("除外: %.1f-%.1f (%s)", spec["start"], spec["end"], reason)
            continue

        clip_index += 1
        clip_filename = f"{clip_index:03d}.wav"
        clip_path = output_dir / clip_filename
        cutter.cut(str(audio_path), str(clip_path), spec["start"], spec["end"])

        clips.append({
            "file": clip_filename,
            "start": spec["start"],
            "end": spec["end"],
            "topic": spec["topic"],
            "reason": spec["reason"],
        })
        log.info("生成: %s (%.1fs - %.1fs, 話題: %s)", clip_filename, spec["start"], spec["end"], spec["topic"])

    report.write_clips_csv(output_dir, clips)
    report.write_report_md(output_dir, audio_path.name, clips, excluded)

    log.info("完了: %s に %d件のクリップを出力しました (除外 %d件)", output_dir, len(clips), len(excluded))


if __name__ == "__main__":
    main()
