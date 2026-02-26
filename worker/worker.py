"""
Fargate worker — runs as a container task, reads env vars injected by ECS,
processes all IDs, writes output zip to S3, updates DynamoDB job record.
"""

import csv
import io
import json
import logging
import os
import sys
import zipfile
from datetime import date, datetime

import boto3
from botocore.exceptions import ClientError

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger()

# ---------------------------------------------------------------------------
# Config from environment (injected by ECS task definition / Terraform)
# ---------------------------------------------------------------------------
DATA_BUCKET       = os.environ["DATA_BUCKET"]
DATA_PREFIX       = os.environ.get("DATA_PREFIX", "")
FILENAME_SUFFIX   = os.environ.get("FILENAME_SUFFIX", "_csv.zip")
RESULTS_BUCKET    = os.environ["RESULTS_BUCKET"]
RESULTS_PREFIX    = os.environ.get("RESULTS_PREFIX", "results/")
JOBS_TABLE        = os.environ["JOBS_TABLE"]
PRESIGNED_URL_TTL = int(os.environ.get("PRESIGNED_URL_TTL", "86400"))  # 24 hours
AWS_REGION        = os.environ.get("AWS_DEFAULT_REGION", "eu-west-1")

# Job params injected per-task
JOB_ID      = os.environ["JOB_ID"]
IDS_S3_KEY  = os.environ["IDS_S3_KEY"]       # where the IDs CSV was uploaded
START_DATE  = os.environ["START_DATE"]        # YYYY-MM-DD
END_DATE    = os.environ["END_DATE"]          # YYYY-MM-DD
DATE_COLUMN = os.environ.get("DATE_COLUMN", "Date")

s3      = boto3.client("s3", region_name=AWS_REGION)
dynamo  = boto3.resource("dynamodb", region_name=AWS_REGION)
table   = dynamo.Table(JOBS_TABLE)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def parse_date(value: str) -> date:
    for fmt in ("%Y-%m-%d", "%Y/%m/%d", "%d-%m-%Y", "%d/%m/%Y"):
        try:
            return datetime.strptime(value, fmt).date()
        except ValueError:
            pass
    raise ValueError(f"Unrecognised date format: {value!r}")


def detect_date_column(headers: list[str], hint: str) -> str:
    if hint in headers:
        return hint
    hint_lower = hint.lower()
    for name in headers:
        if name.lower() == hint_lower:
            return name
    for name in headers:
        if name.lower() in ("date", "datum", "datetime", "timestamp", "time", "day"):
            log.info("Auto-detected date column: %r", name)
            return name
    raise ValueError(f"Cannot find date column in {headers}")


def read_ids_from_text(text: str) -> list[str]:
    ids = []
    reader = csv.reader(io.StringIO(text))
    for i, row in enumerate(reader):
        if not row:
            continue
        value = row[0].strip()
        if i == 0 and not value.replace("-", "").replace("_", "").isalnum():
            continue  # skip header
        if value:
            ids.append(value)
    return ids


def filter_csv_bytes(raw_bytes: bytes, date_col: str, start: date, end: date) -> tuple[bytes | None, int]:
    text = raw_bytes.decode("utf-8-sig")
    reader = csv.DictReader(io.StringIO(text))
    if not reader.fieldnames:
        return None, 0

    col = detect_date_column(list(reader.fieldnames), date_col)
    out_buf = io.StringIO()
    writer = csv.DictWriter(out_buf, fieldnames=reader.fieldnames, lineterminator="\n")
    writer.writeheader()

    kept = 0
    for row in reader:
        raw_val = row.get(col, "").strip()
        if not raw_val:
            continue
        try:
            row_date = parse_date(raw_val[:10])
        except ValueError:
            continue
        if start <= row_date <= end:
            writer.writerow(row)
            kept += 1

    return (out_buf.getvalue().encode("utf-8") if kept > 0 else None), kept


def update_job(status: str, **kwargs):
    expr_parts = ["#st = :status", "#ua = :updated_at"]
    names  = {"#st": "status", "#ua": "updated_at"}
    values = {":status": status, ":updated_at": datetime.utcnow().isoformat()}

    for k, v in kwargs.items():
        placeholder = f":{k}"
        name_ph     = f"#{k}"
        expr_parts.append(f"{name_ph} = {placeholder}")
        names[name_ph]  = k
        values[placeholder] = v

    table.update_item(
        Key={"job_id": JOB_ID},
        UpdateExpression="SET " + ", ".join(expr_parts),
        ExpressionAttributeNames=names,
        ExpressionAttributeValues=values,
    )


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    log.info("Job %s starting", JOB_ID)
    update_job("running")

    try:
        # 1. Parse dates
        start = parse_date(START_DATE)
        end   = parse_date(END_DATE)

        # 2. Load IDs from S3 (uploaded by the job-creator Lambda)
        log.info("Loading IDs from s3://%s/%s", RESULTS_BUCKET, IDS_S3_KEY)
        ids_obj  = s3.get_object(Bucket=RESULTS_BUCKET, Key=IDS_S3_KEY)
        ids_text = ids_obj["Body"].read().decode("utf-8")
        ids      = read_ids_from_text(ids_text)
        log.info("Processing %d IDs from %s to %s", len(ids), start, end)
        update_job("running", total_ids=len(ids))

        prefix = DATA_PREFIX
        if prefix and not prefix.endswith("/"):
            prefix += "/"

        # 3. Stream output directly into an in-memory zip, upload when done
        out_zip_buf = io.BytesIO()
        matched = 0
        written = 0
        total_rows = 0

        with zipfile.ZipFile(out_zip_buf, "w", compression=zipfile.ZIP_DEFLATED) as zout:
            for i, id_ in enumerate(ids, 1):
                s3_key = f"{prefix}{id_}{FILENAME_SUFFIX}"

                if i % 100 == 0:
                    log.info("Progress: %d / %d IDs processed (%d written)", i, len(ids), written)
                    update_job("running", processed_ids=i, files_written=written)

                try:
                    response = s3.get_object(Bucket=DATA_BUCKET, Key=s3_key)
                except ClientError as exc:
                    code = exc.response["Error"]["Code"]
                    if code in ("NoSuchKey", "404"):
                        log.warning("Not found: %s", s3_key)
                    else:
                        log.warning("Error fetching %s: %s", s3_key, exc)
                    continue

                matched += 1
                zip_bytes = response["Body"].read()

                try:
                    with zipfile.ZipFile(io.BytesIO(zip_bytes)) as zin:
                        csv_names = [n for n in zin.namelist() if n.lower().endswith(".csv")]
                        if not csv_names:
                            log.warning("No CSV inside %s", s3_key)
                            continue
                        raw_csv = zin.read(csv_names[0])
                except zipfile.BadZipFile:
                    log.warning("Bad zip: %s", s3_key)
                    continue

                filtered, rows_kept = filter_csv_bytes(raw_csv, DATE_COLUMN, start, end)
                if filtered is None:
                    log.debug("No rows in range for %s", id_)
                    continue

                zout.writestr(f"{id_}.csv", filtered)
                written += 1
                total_rows += rows_kept

        if written == 0:
            update_job("failed", error="No data found for any ID in the given date range.")
            log.error("No data found — job marked failed")
            sys.exit(1)

        # 4. Upload result zip to S3
        result_key = f"{RESULTS_PREFIX}{JOB_ID}/extract_{start}_{end}.zip"
        log.info("Uploading result (%d CSVs, %d rows) to s3://%s/%s",
                 written, total_rows, RESULTS_BUCKET, result_key)

        out_zip_buf.seek(0)
        s3.put_object(
            Bucket=RESULTS_BUCKET,
            Key=result_key,
            Body=out_zip_buf.getvalue(),
            ContentType="application/zip",
        )

        # 5. Generate presigned download URL
        download_url = s3.generate_presigned_url(
            "get_object",
            Params={"Bucket": RESULTS_BUCKET, "Key": result_key},
            ExpiresIn=PRESIGNED_URL_TTL,
        )

        update_job(
            "complete",
            download_url=download_url,
            files_written=written,
            total_rows=total_rows,
            ids_matched=matched,
            total_ids=len(ids),
            expires_in_seconds=PRESIGNED_URL_TTL,
        )

        log.info("Job %s complete — %d files, %d rows", JOB_ID, written, total_rows)

    except Exception as exc:
        log.exception("Unhandled error in job %s", JOB_ID)
        update_job("failed", error=str(exc))
        sys.exit(1)


if __name__ == "__main__":
    main()
