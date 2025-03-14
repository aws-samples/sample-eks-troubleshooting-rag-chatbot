data "aws_caller_identity" "current" {}

################################################################################
# OpenSearch Serverless Collection
################################################################################

resource "aws_opensearchserverless_security_policy" "encryption_policy" {
  name = "${var.collection_name}-encryption-pol"
  type = "encryption"
  description = "Encryption policy for ${var.collection_name}"
  policy = jsonencode({
    Rules = [
      {
        Resource = [
          "collection/${var.collection_name}"
        ],
        ResourceType = "collection"
      }
    ],
    AWSOwnedKey = true
  })
}

resource "aws_opensearchserverless_security_policy" "network_policy" {
  name = "${var.collection_name}-network-pol"
  type = "network"
  description = "Network policy for ${var.collection_name}"
  policy = jsonencode([
    {
      Rules = [
        {
          Resource = [
            "collection/${var.collection_name}"
          ],
          ResourceType = "collection"
        }
      ],
      AllowFromPublic = true
    }
  ])
}

resource "aws_opensearchserverless_collection" "vector_db" {
  name        = var.collection_name
  type        = "VECTORSEARCH"
  description = "Vector search collection for embeddings"

  depends_on = [
    aws_opensearchserverless_security_policy.encryption_policy,
    aws_opensearchserverless_security_policy.network_policy
  ]
}

resource "aws_opensearchserverless_access_policy" "access_policy" {
  name = "${var.collection_name}-access-policy"
  type = "data"
  policy = jsonencode([
    {
      Description = "Access policy for ${var.collection_name}",
      Rules = [
        {
          ResourceType = "collection",
          Resource = ["collection/${var.collection_name}"],
          Permission = [
            "aoss:CreateCollectionItems",
            "aoss:DeleteCollectionItems",
            "aoss:UpdateCollectionItems",
            "aoss:DescribeCollectionItems"
          ]
        },
        {
          ResourceType = "index",
          Resource = ["index/${var.collection_name}/*"],
          Permission = [
            "aoss:CreateIndex",
            "aoss:DeleteIndex",
            "aoss:UpdateIndex",
            "aoss:DescribeIndex",
            "aoss:ReadDocument",
            "aoss:WriteDocument"
          ]
        }
      ],
      Principal = [
         aws_iam_role.lambda_role.arn
      ]
    }
  ])

  depends_on = [aws_opensearchserverless_collection.vector_db]
}

################################################################################
# Kinesis Data Streams
################################################################################

# Create the Kinesis Data Stream
resource "aws_kinesis_stream" "log_stream" {
  name             = "${var.name}-eks-logs"
  stream_mode_details {
    stream_mode = "ON_DEMAND"
  }
}

# Lambda Permission to allow Kinesis to invoke the function
resource "aws_lambda_permission" "kinesis_lambda" {
  statement_id  = "AllowKinesisInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.processor.function_name
  principal     = "kinesis.amazonaws.com"
  source_arn    = aws_kinesis_stream.log_stream.arn
}

# Create Event Source Mapping to trigger Lambda from Kinesis
resource "aws_lambda_event_source_mapping" "stream_lambda" {
  event_source_arn  = aws_kinesis_stream.log_stream.arn
  function_name     = aws_lambda_function.processor.arn
  starting_position = "LATEST"

  batch_size                         = 100
  maximum_batching_window_in_seconds = 60
}

################################################################################
# Kinesis Consumer - Lambda Function
################################################################################

# IAM role for Lambda
resource "aws_iam_role" "lambda_role" {
  name = "${var.name}-stream-processor-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

# IAM policy for the Lambda role to read from Kinesis
resource "aws_iam_role_policy" "lambda_kinesis_policy" {
  name = "${var.name}-stream-processor-policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "kinesis:GetShardIterator",
          "kinesis:GetRecords",
          "kinesis:DescribeStream",
          "kinesis:ListShards"
        ]
        Resource = aws_kinesis_stream.log_stream.arn
      },
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel"
        ]
        Resource = ["arn:aws:bedrock:${var.region}::foundation-model/amazon.titan-embed-text-v2:0"]
      }
    ]
  })
}

# Permission to write on OpenSearch
resource "aws_iam_role_policy" "lambda_opensearch_policy" {
  name = "${var.name}-opensearch-policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "aoss:APIAccessAll"
        ]
        Resource = [
          "${aws_opensearchserverless_collection.vector_db.arn}",
          "${aws_opensearchserverless_collection.vector_db.arn}/*"
        ]
      }
    ]
  })
}

# Basic Lambda execution policy
resource "aws_iam_role_policy_attachment" "lambda_basic" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  role       = aws_iam_role.lambda_role.name
}

# Add CloudWatch Logs policy for Lambda
resource "aws_iam_role_policy_attachment" "lambda_logs" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaKinesisExecutionRole"
  role       = aws_iam_role.lambda_role.name
}

# ECR Repository
resource "aws_ecr_repository" "lambda_repo" {
  name                 = "ingestion-pipeline-lambda"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = false
  }
}

# ECR Repository Policy
resource "aws_ecr_repository_policy" "lambda_repo_policy" {
  repository = aws_ecr_repository.lambda_repo.name
  policy     = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "LambdaECRImageRetrievalPolicy"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = [
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer"
        ]
      }
    ]
  })
}

# Add ECR permissions to Lambda role
resource "aws_iam_role_policy_attachment" "lambda_ecr" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  role       = aws_iam_role.lambda_role.name
}

# Trigger new Build & Push if code is changed
resource "null_resource" "docker_push" {
  triggers = {
    docker_file = filemd5("${path.module}/lambda/Dockerfile")
    source_code = filemd5("${path.module}/lambda/processor.py")
    source_requirements = filemd5("${path.module}/lambda/requirements.txt")
  }

  provisioner "local-exec" {
    working_dir = "${path.module}/lambda"
    command = <<EOF
      aws ecr get-login-password --region ${var.region} | ${var.container_builder} login --username AWS --password-stdin ${aws_ecr_repository.lambda_repo.repository_url}
      ${var.container_builder} build --platform=linux/amd64 -t ${aws_ecr_repository.lambda_repo.repository_url}:latest .
      ${var.container_builder} push ${aws_ecr_repository.lambda_repo.repository_url}:latest
    EOF
  }

  depends_on = [aws_ecr_repository.lambda_repo]
}

# Lambda Function
resource "aws_lambda_function" "processor" {
  function_name    = "${var.name}-processor"
  role             = aws_iam_role.lambda_role.arn
  package_type     = "Image"
  image_uri        = "${aws_ecr_repository.lambda_repo.repository_url}:latest"
  timeout          = 300

  environment {
    variables = {
      LOG_LEVEL = "INFO"
      OPENSEARCH_ENDPOINT = aws_opensearchserverless_collection.vector_db.collection_endpoint
      EMBEDDING_MODEL = "amazon.titan-embed-text-v2:0"
    }
  }

  depends_on = [null_resource.docker_push]
}
