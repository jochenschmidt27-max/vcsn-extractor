output "ui_url" {
  value = "https://${aws_cloudfront_distribution.ui.domain_name}"
}

output "api_endpoint" {
  value = aws_apigatewayv2_api.main.api_endpoint
}

output "ecr_repository_url" {
  description = "Push your worker Docker image here."
  value       = aws_ecr_repository.worker.repository_url
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.main.name
}

output "results_bucket" {
  value = aws_s3_bucket.results.id
}

output "cloudfront_distribution_id" {
  value = aws_cloudfront_distribution.ui.id
}
