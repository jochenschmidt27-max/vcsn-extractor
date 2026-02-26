FROM python:3.12-slim

WORKDIR /app

# boto3 is the only runtime dependency
RUN pip install --no-cache-dir boto3

COPY worker.py .

CMD ["python", "worker.py"]
