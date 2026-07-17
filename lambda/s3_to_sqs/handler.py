import json
import os
import time
import urllib.parse
import uuid

import boto3

sqs = boto3.client("sqs")
QUEUE_URL = os.environ["JOB_QUEUE_URL"]


def lambda_handler(event, context):
    for record in event.get("Records", []):
        bucket = record["s3"]["bucket"]["name"]
        key = urllib.parse.unquote_plus(record["s3"]["object"]["key"])

        message = {
            "job_id": str(uuid.uuid4()),
            "bucket": bucket,
            "key": key,
            "uploaded_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }

        sqs.send_message(
            QueueUrl=QUEUE_URL,
            MessageBody=json.dumps(message, ensure_ascii=False),
        )

    return {"statusCode": 200}
