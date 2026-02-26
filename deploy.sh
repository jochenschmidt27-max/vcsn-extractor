#!/usr/bin/env bash
# deploy.sh
# Builds and pushes the Docker image, then uploads the UI with the live API endpoint.
# Run once after `terraform apply`, and again whenever worker.py or index.html changes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$SCRIPT_DIR/terraform"
WORKER_DIR="$SCRIPT_DIR/worker"
UI_SRC="$SCRIPT_DIR/ui/index.html"

echo "==> Reading Terraform outputs…"
ECR_URL=$(terraform -chdir="$TF_DIR" output -raw ecr_repository_url)
API_ENDPOINT=$(terraform -chdir="$TF_DIR" output -raw api_endpoint)
CF_DIST_ID=$(terraform -chdir="$TF_DIR" output -raw cloudfront_distribution_id)
UI_BUCKET_DOMAIN=$(terraform -chdir="$TF_DIR" output -raw ui_url | sed 's|https://||')
AWS_REGION=$(terraform -chdir="$TF_DIR" output -raw ecr_repository_url | cut -d. -f4)
ACCOUNT_ID=$(terraform -chdir="$TF_DIR" output -raw ecr_repository_url | cut -d. -f1)

echo "    ECR: $ECR_URL"
echo "    API: $API_ENDPOINT"
echo "    CF:  $CF_DIST_ID"

# ---------------------------------------------------------------------------
# Build and push Docker image
# ---------------------------------------------------------------------------
echo ""
echo "==> Authenticating Docker with ECR…"
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

echo "==> Building Docker image…"
docker build --platform linux/amd64 -t s3extractor-worker "$WORKER_DIR"

echo "==> Tagging and pushing image…"
docker tag s3extractor-worker:latest "$ECR_URL:latest"
docker push "$ECR_URL:latest"

# ---------------------------------------------------------------------------
# Upload UI with API endpoint injected
# ---------------------------------------------------------------------------
echo ""
echo "==> Uploading UI…"
TMP_HTML=$(mktemp /tmp/index_XXXXXX.html)
sed "s|%%API_BASE%%|$API_ENDPOINT|g" "$UI_SRC" > "$TMP_HTML"

aws s3 cp "$TMP_HTML" "s3://${UI_BUCKET_DOMAIN/https:\/\//}/index.html" \
  --content-type "text/html" \
  --cache-control "no-cache" 2>/dev/null || \
aws s3 cp "$TMP_HTML" "s3://$(terraform -chdir="$TF_DIR" output -json | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['results_bucket']['value'])" | sed 's/results/ui/' 2>/dev/null || echo 'BUCKET_ERROR')/index.html" \
  --content-type "text/html" --cache-control "no-cache" 2>/dev/null || true

# Simpler approach using the UI bucket name directly
UI_BUCKET_NAME=$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?Id=='$CF_DIST_ID'].Origins.Items[0].DomainName" \
  --output text | sed 's/.s3.*//' | head -1)

aws s3 cp "$TMP_HTML" "s3://${UI_BUCKET_NAME}/index.html" \
  --content-type "text/html" \
  --cache-control "no-cache"

rm "$TMP_HTML"

echo "==> Invalidating CloudFront cache…"
aws cloudfront create-invalidation \
  --distribution-id "$CF_DIST_ID" \
  --paths "/index.html" \
  --query "Invalidation.Id" --output text

echo ""
echo "✅  Deployment complete!"
echo "    UI URL: https://${UI_BUCKET_DOMAIN}"
