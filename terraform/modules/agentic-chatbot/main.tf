# IAM role for ChatBot
module "irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.30.0"

  role_name = "${var.name}-chatbot-role"

  role_policy_arns = {
  policy = aws_iam_policy.chatbot_opensearch_policy.arn
}

  oidc_providers = {
    main = {
      provider_arn               = var.eks_cluster_oidc_arn
      namespace_service_accounts = ["agentic-chatbot:agentic-chatbot"]
    }
  }
  depends_on = [aws_iam_policy.chatbot_opensearch_policy]
}


# Permission for Bedrock Models
resource "aws_iam_role_policy" "bedrock_invoke_policy" {
  name = "${var.name}-bedrock-invoke-policy"
  role = module.irsa_role.iam_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream"
        ]
        Resource = [
          "arn:aws:bedrock:${var.region}::foundation-model/amazon.titan-embed-text-v2:0",
          "arn:aws:bedrock:${var.region}::foundation-model/anthropic.claude-3-sonnet-20240229-v1:0"
        ]
      }
    ]
  })
  depends_on = [module.irsa_role]
}

# IAM policy for ChatBot to use OpenSearch
resource "aws_iam_policy" "chatbot_opensearch_policy" {
  name        = "${var.name}-chatbot-opensearch-policy"
  description = "Policy for chatbot to access OpenSearch Serverless collection"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "aoss:APIAccessAll"
        ]
        Resource = [
          "${var.collection_arn}",
          "${var.collection_arn}/*"
        ]
      }
    ]
  })
}

resource "aws_opensearchserverless_access_policy" "access_policy" {
  name = "${var.collection_name}-chatbot-access-policy"
  type = "data"
  policy = jsonencode([
    {
      Description = "Access policy for ${var.collection_name}",
      Rules = [
        {
          ResourceType = "collection",
          Resource = ["collection/${var.collection_name}"],
          Permission = [
            "aoss:DescribeCollectionItems"
          ]
        },
        {
          ResourceType = "index",
          Resource = ["index/${var.collection_name}/*"],
          Permission = [
            "aoss:DescribeIndex",
            "aoss:ReadDocument",
          ]
        }
      ],
      Principal = [
         module.irsa_role.iam_role_arn,
      ]
    }
  ])
}

# ChatBot ECR Repo
# ECR Repository
resource "aws_ecr_repository" "chatbot_repo" {
  name                 = "agentic-chatbot"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = false
  }
}

# Trigger new Build & Push if code is changed
resource "null_resource" "docker_push" {
  triggers = {
    docker_file = filemd5("${path.module}/../../../apps/chatbot/Dockerfile")
    app = filemd5("${path.module}/../../../apps/chatbot/app.py")
    requirements = filemd5("${path.module}/../../../apps/chatbot/requirements.txt")
    bedrock_cliebt = filemd5("${path.module}/../../../apps/chatbot/bedrock_client.py")
    embedder = filemd5("${path.module}/../../../apps/chatbot/embedder.py")
    kubernetes_resource = filemd5("${path.module}/../../../apps/chatbot/kubernetes_resource.py")
    retriever = filemd5("${path.module}/../../../apps/chatbot/retriever.py")
    logger = filemd5("${path.module}/../../../apps/chatbot/logger.py")
  }

  provisioner "local-exec" {
    working_dir = "${path.module}/../../../apps/chatbot/"
    command = <<EOF
      aws ecr get-login-password --region ${var.region} | ${var.container_builder} login --username AWS --password-stdin ${aws_ecr_repository.chatbot_repo.repository_url}
      ${var.container_builder} build --platform=linux/amd64 -t ${aws_ecr_repository.chatbot_repo.repository_url}:latest .
      ${var.container_builder} push ${aws_ecr_repository.chatbot_repo.repository_url}:latest
    EOF
  }

  depends_on = [aws_ecr_repository.chatbot_repo]
}
