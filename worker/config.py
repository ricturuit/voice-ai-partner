import os
from dataclasses import dataclass, field

from dotenv import load_dotenv

load_dotenv()


@dataclass(frozen=True)
class Config:
    aws_region: str = field(default_factory=lambda: os.environ["AWS_REGION"])
    sqs_queue_url: str = field(default_factory=lambda: os.environ["SQS_QUEUE_URL"])
    s3_bucket: str = field(default_factory=lambda: os.environ["S3_BUCKET"])
    anthropic_api_key: str = field(default_factory=lambda: os.environ["ANTHROPIC_API_KEY"])
    claude_model: str = field(default_factory=lambda: os.environ.get("CLAUDE_MODEL", "claude-sonnet-5"))
    whisper_model: str = field(default_factory=lambda: os.environ.get("WHISPER_MODEL", "small"))
    ffmpeg_path: str = field(default_factory=lambda: os.environ.get("FFMPEG_PATH", "ffmpeg"))
    work_dir: str = field(default_factory=lambda: os.environ.get("WORK_DIR", "./work"))


config = Config()
