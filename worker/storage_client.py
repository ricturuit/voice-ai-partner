import boto3

from config import config

_s3 = boto3.client("s3", region_name=config.aws_region)


def download(key, local_path):
    _s3.download_file(config.s3_bucket, key, local_path)


def upload(local_path, key):
    _s3.upload_file(local_path, config.s3_bucket, key)


def move(src_key, dst_key):
    _s3.copy_object(
        Bucket=config.s3_bucket,
        CopySource={"Bucket": config.s3_bucket, "Key": src_key},
        Key=dst_key,
    )
    _s3.delete_object(Bucket=config.s3_bucket, Key=src_key)
