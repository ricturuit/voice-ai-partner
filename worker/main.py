import logging
import shutil
from pathlib import Path

import cutter
import queue_client
import report
import segmenter
import storage_client
import transcribe
from config import config

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("worker")


def process(job):
    job_id = job["job_id"]
    src_key = job["key"]
    source_filename = Path(src_key).name

    job_dir = Path(config.work_dir) / job_id
    job_dir.mkdir(parents=True, exist_ok=True)
    local_source = job_dir / source_filename

    storage_client.download(src_key, str(local_source))

    segments = transcribe.transcribe(str(local_source))
    clip_specs = segmenter.segment(segments)

    clips = []
    for i, spec in enumerate(clip_specs, start=1):
        clip_filename = f"{i:03d}.wav"
        clip_path = job_dir / clip_filename
        cutter.cut(str(local_source), str(clip_path), spec["start"], spec["end"])

        clips.append({
            "file": clip_filename,
            "start": spec["start"],
            "end": spec["end"],
            "topic": spec["topic"],
            "reason": spec["reason"],
        })
        storage_client.upload(str(clip_path), f"output/{job_id}/{clip_filename}")

    csv_path = report.write_clips_csv(job_dir, clips)
    storage_client.upload(str(csv_path), f"output/{job_id}/clips.csv")

    report_path = report.write_report_md(job_dir, source_filename, clips)
    storage_client.upload(str(report_path), f"output/{job_id}/report.md")

    storage_client.move(src_key, f"archive/{source_filename}")

    shutil.rmtree(job_dir, ignore_errors=True)


def main():
    log.info("voice-dataset worker started, polling %s", config.sqs_queue_url)
    while True:
        job, receipt_handle = queue_client.receive_job()
        if job is None:
            continue

        log.info("received job %s (%s)", job["job_id"], job["key"])
        try:
            process(job)
            queue_client.delete_job(receipt_handle)
            log.info("job %s completed", job["job_id"])
        except Exception:
            log.exception("job %s failed, moving source to error/", job["job_id"])
            try:
                storage_client.move(job["key"], f"error/{Path(job['key']).name}")
            except Exception:
                log.exception("failed to move source to error/ for job %s", job["job_id"])
            queue_client.delete_job(receipt_handle)


if __name__ == "__main__":
    main()
