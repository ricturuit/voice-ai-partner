import json

import boto3

from config import config

_sqs = boto3.client("sqs", region_name=config.aws_region)


def receive_job():
    response = _sqs.receive_message(
        QueueUrl=config.sqs_queue_url,
        MaxNumberOfMessages=1,
        WaitTimeSeconds=20,
    )
    messages = response.get("Messages", [])
    if not messages:
        return None, None

    message = messages[0]
    job = json.loads(message["Body"])
    return job, message["ReceiptHandle"]


def delete_job(receipt_handle):
    _sqs.delete_message(QueueUrl=config.sqs_queue_url, ReceiptHandle=receipt_handle)
