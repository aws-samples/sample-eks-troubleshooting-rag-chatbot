variable "name" {
  description = "Name prefix for all resources"
  type        = string
  default     = "eks-agentic-troubleshooting"
}

variable "slack_webhook_url" {
  description = "Slack webhook URL for Prometheus AlertManager notifications"
  type        = string
  default     = ""
}

variable "slack_channel_name" {
  description = "Slack channel name for Prometheus AlertManager notifications"
  type        = string
  default     = ""
}

# Agentic deployment variables
variable "agentic_image_repository" {
  description = "ECR repository for the Agentic AI troubleshooting agent image"
  type        = string
  default     = ""
}

variable "agentic_image_tag" {
  description = "Tag for the Agentic AI troubleshooting agent image"
  type        = string
  default     = "latest"
}

variable "slack_bot_token" {
  description = "Slack bot token for Agentic AI deployment"
  type        = string
  default     = ""
  sensitive   = true
}

variable "slack_app_token" {
  description = "Slack app token for Socket Mode"
  type        = string
  default     = ""
  sensitive   = true
}

variable "slack_signing_secret" {
  description = "Slack signing secret for request verification"
  type        = string
  default     = ""
  sensitive   = true
}

variable "bedrock_model_id" {
  description = "Amazon Bedrock model ID for AI agent (orchestrator)"
  type        = string
  default     = "us.anthropic.claude-sonnet-4-20250514-v1:0"
}

variable "bedrock_classification_model_id" {
  description = "Amazon Bedrock model ID for message classification (Nova)"
  type        = string
  default     = "us.amazon.nova-micro-v1:0"
}

variable "vector_bucket_name" {
  description = "S3 bucket name for vector storage (must be created manually before deployment)"
  type        = string
  default     = ""
}

variable "vector_index_name" {
  description = "S3 Vectors index name for troubleshooting knowledge base"
  type        = string
  default     = "k8s-troubleshooting"
}
