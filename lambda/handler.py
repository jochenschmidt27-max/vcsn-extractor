"""
Two Lambda handlers:

  POST /jobs          -> submit_job()   — validates input, stores IDs in S3,
                                          creates DynamoDB job record, launches Fargate task
  GET  /jobs/{job_id} -> get_job()      — returns current job status from DynamoDB
"""

import base64
import boto3
import json
import logging
import os
import sys
import uuid
from datetime import datetime

log = logging.getLogger()
log.setLevel(logging.INFO)

AWS_REGION        = os.environ.get("AWS_DEFAULT_REGION", "eu-west-1")
RESULTS_BUCKET    = os.environ["RESULTS_BUCKET"]
JOBS_TABLE        = os.environ["JOBS_TABLE"]
ECS_CLUSTER       = os.environ["ECS_CLUSTER"]
ECS_TASK_DEF      = os.environ["ECS_TASK_DEF"]
WORKER_SUBNET_IDS = os.environ["WORKER_SUBNET_IDS"].split(",")
WORKER_SG_ID      = os.environ["WORKER_SG_ID"]
DATA_BUCKET       = os.environ["DATA_BUCKET"]
DATA_PREFIX       = os.environ.get("DATA_PREFIX", "")
FILENAME_SUFFIX   = os.environ.get("FILENAME_SUFFIX", "_csv.zip")
DATE_COLUMN       = os.environ.get("DATE_COLUMN", "Date")
CONTAINER_NAME    = os.environ["CONTAINER_NAME"]

s3     = boto3.client("s3",       region_name=AWS_REGION)
dynamo = boto3.resource("dynamodb", region_name=AWS_REGION)
ecs    = boto3.client("ecs",      region_name=AWS_REGION)
table  = dynamo.Table(JOBS_TABLE)


# ---------------------------------------------------------------------------
# Router
# ---------------------------------------------------------------------------

def handler(event, context):
    method    = event.get("requestContext", {}).get("http", {}).get("method", "")
    raw_path  = event.get("rawPath", "")

    if method == "POST" and raw_path.rstrip("/") == "/jobs":
        return submit_job(event)

    if method == "GET" and raw_path.startswith("/jobs/"):
        job_id = raw_path.split("/jobs/")[-1].strip("/")
        return get_job(job_id)

    return _error(404, "Not found")


# ---------------------------------------------------------------------------
# POST /jobs
# ---------------------------------------------------------------------------

def submit_job(event):
    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _error(400, "Request body must be valid JSON.")

    ids_csv_b64 = body.get("ids_csv")
    start_str   = body.get("start_date")
    end_str     = body.get("end_date")
    date_col    = body.get("date_column", DATE_COLUMN)

    if not ids_csv_b64:
        return _error(400, "Missing 'ids_csv' (base64-encoded CSV).")
    if not start_str or not end_str:
        return _error(400, "Missing 'start_date' or 'end_date'.")
    if start_str > end_str:
        return _error(400, f"start_date ({start_str}) must be <= end_date ({end_str}).")

    try:
        ids_csv_bytes = base64.b64decode(ids_csv_b64)
    except Exception:
        return _error(400, "'ids_csv' is not valid base64.")

    # Count IDs for quick validation (read first column, skip header)
    import csv, io
    reader = csv.reader(io.StringIO(ids_csv_bytes.decode("utf-8", errors="replace")))
    ids = []
    for i, row in enumerate(reader):
        if not row: continue
        v = row[0].strip()
        if i == 0 and not v.replace("-","").replace("_","").isalnum(): continue
        if v: ids.append(v)

    if not ids:
        return _error(400, "No IDs found in the uploaded CSV.")

    job_id   = str(uuid.uuid4())
    ids_key  = f"inputs/{job_id}/ids.csv"

    # Store IDs CSV in S3 so the worker can read it
    s3.put_object(Bucket=RESULTS_BUCKET, Key=ids_key, Body=ids_csv_bytes)

    # Create DynamoDB job record
    now = datetime.utcnow().isoformat()
    table.put_item(Item={
        "job_id":     job_id,
        "status":     "pending",
        "created_at": now,
        "updated_at": now,
        "start_date": start_str,
        "end_date":   end_str,
        "date_column": date_col,
        "total_ids":  len(ids),
    })

    # Launch Fargate task
    ecs.run_task(
        cluster        = ECS_CLUSTER,
        taskDefinition = ECS_TASK_DEF,
        launchType     = "FARGATE",
        networkConfiguration={
            "awsvpcConfiguration": {
                "subnets":        WORKER_SUBNET_IDS,
                "securityGroups": [WORKER_SG_ID],
                "assignPublicIp": "ENABLED",
            }
        },
        overrides={
            "containerOverrides": [{
                "name": CONTAINER_NAME,
                "environment": [
                    {"name": "JOB_ID",       "value": job_id},
                    {"name": "IDS_S3_KEY",   "value": ids_key},
                    {"name": "START_DATE",   "value": start_str},
                    {"name": "END_DATE",     "value": end_str},
                    {"name": "DATE_COLUMN",  "value": date_col},
                ],
            }]
        },
    )

    log.info("Launched Fargate task for job %s (%d IDs)", job_id, len(ids))

    return _ok({
        "job_id":     job_id,
        "status":     "pending",
        "total_ids":  len(ids),
        "start_date": start_str,
        "end_date":   end_str,
    }, status=202)


# ---------------------------------------------------------------------------
# GET /jobs/{job_id}
# ---------------------------------------------------------------------------

def get_job(job_id: str):
    if not job_id:
        return _error(400, "Missing job_id.")

    try:
        resp = table.get_item(Key={"job_id": job_id})
    except Exception as exc:
        log.error("DynamoDB error: %s", exc)
        return _error(500, "Failed to retrieve job.")

    item = resp.get("Item")
    if not item:
        return _error(404, f"Job '{job_id}' not found.")

    # Convert Decimal types (DynamoDB numbers) to int/float for JSON
    item = _clean(item)
    return _ok(item)


def _clean(obj):
    from decimal import Decimal
    if isinstance(obj, dict):
        return {k: _clean(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_clean(v) for v in obj]
    if isinstance(obj, Decimal):
        return int(obj) if obj % 1 == 0 else float(obj)
    return obj


# ---------------------------------------------------------------------------
# Response helpers
# ---------------------------------------------------------------------------

def _ok(body: dict, status: int = 200) -> dict:
    return {
        "statusCode": status,
        "headers":    _cors_headers(),
        "body":       json.dumps(body),
    }


def _error(status: int, message: str) -> dict:
    return {
        "statusCode": status,
        "headers":    _cors_headers(),
        "body":       json.dumps({"error": message}),
    }


def _cors_headers() -> dict:
    return {
        "Content-Type":                 "application/json",
        "Access-Control-Allow-Origin":  "*",
        "Access-Control-Allow-Headers": "Content-Type",
        "Access-Control-Allow-Methods": "GET,POST,OPTIONS",
    }
