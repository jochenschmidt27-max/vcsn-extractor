variable "aws_region" {
  type    = string
  default = "ap-southeast-2"
}

variable "project_name" {
  type    = string
  default = "s3extractor"
}

variable "data_bucket_name" {
  description = "Existing S3 bucket containing the ID_csv.zip files."
  type        = string
}

variable "data_prefix" {
  description = "Key prefix (folder) inside the data bucket, e.g. 'timeseries/'. Leave empty for root."
  type        = string
  default     = ""
}

variable "filename_suffix" {
  description = "Suffix appended to each ID to form the S3 key, e.g. '_csv.zip' → 10013_csv.zip."
  type        = string
  default     = "_csv.zip"
}

variable "date_column" {
  description = "Name of the date column in the CSV files."
  type        = string
  default     = "Date"
}

variable "results_retention_days" {
  description = "Days before output zips are auto-deleted."
  type        = number
  default     = 2
}

variable "presigned_url_ttl_seconds" {
  description = "How long the download link stays valid (seconds)."
  type        = number
  default     = 86400  # 24 hours — longer than Lambda version since jobs take time
}

# Fargate task sizing
# 1 vCPU / 2GB is comfortable for sequential S3 reads + CSV processing.
# Increase to 2048/4096 if you want faster processing of all 1820 stations.
variable "worker_cpu" {
  description = "Fargate task CPU units (256=0.25vCPU, 1024=1vCPU, 2048=2vCPU)."
  type        = number
  default     = 1024
}

variable "worker_memory" {
  description = "Fargate task memory in MB."
  type        = number
  default     = 2048
}
