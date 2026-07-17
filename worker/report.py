import csv
from pathlib import Path


def write_clips_csv(output_dir, clips):
    path = Path(output_dir) / "clips.csv"
    with path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(["file", "start", "end", "duration", "topic", "reason"])
        for clip in clips:
            writer.writerow([
                clip["file"],
                clip["start"],
                clip["end"],
                round(clip["end"] - clip["start"], 2),
                clip["topic"],
                clip["reason"],
            ])
    return path


def write_report_md(output_dir, source_filename, clips):
    total_duration = sum(c["end"] - c["start"] for c in clips)
    topics = sorted({c["topic"] for c in clips})

    lines = [
        f"# {source_filename} 処理レポート",
        "",
        f"- 元ファイル名: {source_filename}",
        f"- 抽出件数: {len(clips)}",
        f"- 抽出時間合計: {total_duration:.1f} 秒",
        f"- 話題一覧: {', '.join(topics)}",
        "",
        "## 採用区間と理由",
        "",
    ]
    for clip in clips:
        lines.append(
            f"- `{clip['file']}` ({clip['start']:.1f}s - {clip['end']:.1f}s, "
            f"話題: {clip['topic']}): {clip['reason']}"
        )

    path = Path(output_dir) / "report.md"
    path.write_text("\n".join(lines), encoding="utf-8")
    return path
