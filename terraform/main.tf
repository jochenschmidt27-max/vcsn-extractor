terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
    archive = { source = "hashicorp/archive", version = "~> 2.0" }
  }

  # backend "s3" {
  #   bucket = "my-terraform-state"
  #   key    = "s3extractor/terraform.tfstate"
  #   region = "eu-west-1"
  # }
}

provider "aws" { region = var.aws_default_region }

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ---------------------------------------------------------------------------
# Networking — use default VPC and its subnets for simplicity
# ---------------------------------------------------------------------------

data "aws_vpc" "default" { default = true }

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# ---------------------------------------------------------------------------
# S3 — results bucket (stores IDs inputs + output zips)
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "results" {
  bucket        = "${var.project_name}-results-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags          = local.tags
}

resource "aws_s3_bucket_public_access_block" "results" {
  bucket                  = aws_s3_bucket.results.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "results" {
  bucket = aws_s3_bucket.results.id
  rule {
    id     = "expire"
    status = "Enabled"
    expiration { days = var.results_retention_days }
  }
}

# ---------------------------------------------------------------------------
# DynamoDB — job tracking
# ---------------------------------------------------------------------------

resource "aws_dynamodb_table" "jobs" {
  name         = "${var.project_name}-jobs"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "job_id"

  attribute {
    name = "job_id"
    type = "S"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  tags = local.tags
}

# ---------------------------------------------------------------------------
# ECR — container registry for the worker image
# ---------------------------------------------------------------------------

resource "aws_ecr_repository" "worker" {
  name                 = "${var.project_name}-worker"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration { scan_on_push = true }

  tags = local.tags
}

resource "aws_ecr_lifecycle_policy" "worker" {
  repository = aws_ecr_repository.worker.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 5 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = { type = "expire" }
    }]
  })
}

# ---------------------------------------------------------------------------
# ECS Cluster
# ---------------------------------------------------------------------------

resource "aws_ecs_cluster" "main" {
  name = "${var.project_name}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = local.tags
}

# ---------------------------------------------------------------------------
# IAM — Fargate task roles
# ---------------------------------------------------------------------------

resource "aws_iam_role" "task_execution" {
  name = "${var.project_name}-task-execution-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ecs-tasks.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "task_execution" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "task" {
  name = "${var.project_name}-task-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ecs-tasks.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy" "task" {
  name = "${var.project_name}-task-policy"
  role = aws_iam_role.task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadDataBucket"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:ListBucket"]
        Resource = [
          "arn:aws:s3:::${var.data_bucket_name}",
          "arn:aws:s3:::${var.data_bucket_name}/${var.data_prefix}*",
        ]
      },
      {
        Sid      = "ReadWriteResultsBucket"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject"]
        Resource = "${aws_s3_bucket.results.arn}/*"
      },
      {
        Sid      = "UpdateJobsTable"
        Effect   = "Allow"
        Action   = ["dynamodb:UpdateItem", "dynamodb:GetItem"]
        Resource = aws_dynamodb_table.jobs.arn
      },
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "*"
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# IAM — Lambda role
# ---------------------------------------------------------------------------

resource "aws_iam_role" "lambda" {
  name = "${var.project_name}-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy" "lambda" {
  name = "${var.project_name}-lambda-policy"
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "S3Inputs"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject"]
        Resource = "${aws_s3_bucket.results.arn}/inputs/*"
      },
      {
        Sid      = "DynamoDB"
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:UpdateItem"]
        Resource = aws_dynamodb_table.jobs.arn
      },
      {
        Sid    = "ECSRunTask"
        Effect = "Allow"
        Action = ["ecs:RunTask"]
        Resource = [
          aws_ecs_task_definition.worker.arn,
          # Allow any revision
          replace(aws_ecs_task_definition.worker.arn, "/:\\d+$/", ":*"),
        ]
      },
      {
        Sid      = "PassTaskRoles"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = [aws_iam_role.task.arn, aws_iam_role.task_execution.arn]
      },
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "*"
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# Security Group — Fargate tasks (egress only, for S3/DynamoDB/ECR access)
# ---------------------------------------------------------------------------

resource "aws_security_group" "worker" {
  name        = "${var.project_name}-worker-sg"
  description = "Fargate worker — outbound only"
  vpc_id      = data.aws_vpc.default.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.tags
}

# ---------------------------------------------------------------------------
# CloudWatch log groups
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "worker" {
  name              = "/ecs/${var.project_name}-worker"
  retention_in_days = 14
  tags              = local.tags
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.project_name}-api"
  retention_in_days = 14
  tags              = local.tags
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/aws/apigateway/${var.project_name}"
  retention_in_days = 14
  tags              = local.tags
}

# ---------------------------------------------------------------------------
# ECS Task Definition
# ---------------------------------------------------------------------------

resource "aws_ecs_task_definition" "worker" {
  family                   = "${var.project_name}-worker"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.worker_cpu
  memory                   = var.worker_memory
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([{
    name      = "worker"
    image     = "${aws_ecr_repository.worker.repository_url}:latest"
    essential = true

    environment = [
      { name = "DATA_BUCKET",       value = var.data_bucket_name },
      { name = "DATA_PREFIX",       value = var.data_prefix },
      { name = "FILENAME_SUFFIX",   value = var.filename_suffix },
      { name = "RESULTS_BUCKET",    value = aws_s3_bucket.results.bucket },
      { name = "RESULTS_PREFIX",    value = "results/" },
      { name = "JOBS_TABLE",        value = aws_dynamodb_table.jobs.name },
      { name = "PRESIGNED_URL_TTL", value = tostring(var.presigned_url_ttl_seconds) },
      { name = "DATE_COLUMN",       value = var.date_column },
      { name = "AWS_DEFAULT_REGION", value = var.aws_region },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.worker.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "worker"
      }
    }
  }])

  tags = local.tags
}

# ---------------------------------------------------------------------------
# Lambda — API handler
# ---------------------------------------------------------------------------

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda"
  output_path = "${path.module}/.build/lambda.zip"
}

resource "aws_lambda_function" "api" {
  function_name    = "${var.project_name}-api"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  timeout          = 30  # just for job submission + status — fast
  memory_size      = 256

  environment {
    variables = {
      RESULTS_BUCKET    = aws_s3_bucket.results.bucket
      JOBS_TABLE        = aws_dynamodb_table.jobs.name
      ECS_CLUSTER       = aws_ecs_cluster.main.name
      ECS_TASK_DEF      = aws_ecs_task_definition.worker.family
      WORKER_SUBNET_IDS = join(",", data.aws_subnets.default.ids)
      WORKER_SG_ID      = aws_security_group.worker.id
      DATA_BUCKET       = var.data_bucket_name
      DATA_PREFIX       = var.data_prefix
      FILENAME_SUFFIX   = var.filename_suffix
      DATE_COLUMN       = var.date_column
      CONTAINER_NAME    = "worker"
      AWS_DEFAULT_REGION = var.aws_region
    }
  }

  tags = local.tags
}

# ---------------------------------------------------------------------------
# API Gateway (HTTP API)
# ---------------------------------------------------------------------------

resource "aws_apigatewayv2_api" "main" {
  name          = "${var.project_name}-api"
  protocol_type = "HTTP"
  description   = "S3 timeseries extractor API"

  cors_configuration {
    allow_origins = ["https://${aws_cloudfront_distribution.ui.domain_name}"]
    allow_methods = ["GET", "POST", "OPTIONS"]
    allow_headers = ["Content-Type"]
    max_age       = 300
  }

  tags = local.tags
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.main.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.api.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "post_jobs" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "POST /jobs"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_route" "get_job" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "GET /jobs/{job_id}"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.main.id
  name        = "$default"
  auto_deploy = true

  tags = local.tags
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}

# ---------------------------------------------------------------------------
# Static UI — S3 + CloudFront
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "ui" {
  bucket        = "${var.project_name}-ui-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags          = local.tags
}

resource "aws_s3_bucket_public_access_block" "ui" {
  bucket                  = aws_s3_bucket.ui.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_cloudfront_origin_access_control" "ui" {
  name                              = "${var.project_name}-ui-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "ui" {
  enabled             = true
  default_root_object = "index.html"
  comment             = "${var.project_name} UI"
  price_class         = "PriceClass_100"

  origin {
    domain_name              = aws_s3_bucket.ui.bucket_regional_domain_name
    origin_id                = "s3-ui"
    origin_access_control_id = aws_cloudfront_origin_access_control.ui.id
  }

  default_cache_behavior {
    target_origin_id       = "s3-ui"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }
    min_ttl     = 0
    default_ttl = 300
    max_ttl     = 3600
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = local.tags
}

resource "aws_s3_bucket_policy" "ui" {
  bucket = aws_s3_bucket.ui.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.ui.arn}/*"
      Condition = { StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.ui.arn } }
    }]
  })
}

resource "aws_s3_object" "ui_index" {
  bucket       = aws_s3_bucket.ui.id
  key          = "index.html"
  source       = "${path.module}/../ui/index.html"
  content_type = "text/html"
  etag         = filemd5("${path.module}/../ui/index.html")
}

# ---------------------------------------------------------------------------
# Locals
# ---------------------------------------------------------------------------

locals {
  tags = {
    Project   = var.project_name
    ManagedBy = "Terraform"
  }
}
