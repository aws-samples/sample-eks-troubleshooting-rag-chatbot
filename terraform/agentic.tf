# Agentic AI Troubleshooting Agent Deployment

################################################################################
# IAM Policy for EKS MCP Server
################################################################################

resource "aws_iam_policy" "eks_mcp_policy" {
  name        = "${local.name}-eks-mcp-policy"
  description = "IAM policy for EKS MCP server access"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster",
          "eks:ListClusters",
          "eks:DescribeNodegroup",
          "eks:ListNodegroups",
          "eks:DescribeAddon",
          "eks:ListAddons",
          "eks:AccessKubernetesApi"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "eks-mcp:InvokeMcp",
          "eks-mcp:CallReadOnlyTool",
          "eks-mcp:CallPrivilegedTool"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams",
          "logs:GetLogEvents",
          "logs:StartQuery",
          "logs:StopQuery",
          "logs:GetQueryResults"
        ]
        Resource = [
          "arn:aws:logs:*:${data.aws_caller_identity.current.account_id}:*",
          "arn:aws:logs:*:${data.aws_caller_identity.current.account_id}:log-group:/aws/containerinsights/${local.name}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:GetMetricData",
          "cloudwatch:ListMetrics"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream"
        ]
        Resource = [
          "arn:aws:bedrock:*::foundation-model/*",
          "arn:aws:bedrock:*:${data.aws_caller_identity.current.account_id}:inference-profile/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "s3vectors:PutVectors",
          "s3vectors:QueryVectors",
          "s3vectors:GetVectors",
          "s3vectors:DeleteVectors"
        ]
        Resource = var.vector_bucket_name != "" ? [
          "arn:aws:s3vectors:*:${data.aws_caller_identity.current.account_id}:bucket/${var.vector_bucket_name}/*",
          "arn:aws:s3vectors:*:${data.aws_caller_identity.current.account_id}:bucket/${var.vector_bucket_name}/index/${var.vector_index_name}"
        ] : []
      }
    ]
  })

  tags = local.tags
}

################################################################################
# IAM Role for Agentic Troubleshooting Agent
################################################################################

resource "aws_iam_role" "agentic_agent_role" {
  name = "${local.name}-agentic-agent-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "pods.eks.amazonaws.com"
        }
        Action = [
          "sts:AssumeRole",
          "sts:TagSession"
        ]
      }
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "agentic_agent_eks_mcp" {
  role       = aws_iam_role.agentic_agent_role.name
  policy_arn = aws_iam_policy.eks_mcp_policy.arn
}

################################################################################
# EKS Pod Identity Association
################################################################################

resource "aws_eks_pod_identity_association" "agentic_agent" {
  cluster_name    = module.eks.cluster_name
  namespace       = "default"
  service_account = "k8s-troubleshooting-agent"
  role_arn        = aws_iam_role.agentic_agent_role.arn

  tags = local.tags
}

################################################################################
# EKS Access Entry and Policy
################################################################################

resource "aws_eks_access_entry" "agentic_agent" {
  cluster_name      = module.eks.cluster_name
  principal_arn     = aws_iam_role.agentic_agent_role.arn
  kubernetes_groups = []
  type              = "STANDARD"

  tags = local.tags
}

resource "aws_eks_access_policy_association" "agentic_agent_admin" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.agentic_agent_role.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.agentic_agent]
}

################################################################################
# Kubernetes Secret for Slack Credentials
################################################################################

resource "kubernetes_secret" "slack_credentials" {
  metadata {
    name      = "slack-credentials"
    namespace = "default"
  }

  data = {
    bot-token      = var.slack_bot_token
    app-token      = var.slack_app_token
    signing-secret = var.slack_signing_secret
  }

  type = "Opaque"
}

################################################################################
# Helm Release for Agentic Troubleshooting Agent
################################################################################

resource "helm_release" "agentic_agent" {
  count = var.agentic_image_repository != "" ? 1 : 0

  name             = "k8s-troubleshooting-agent"
  chart            = "${path.module}/../apps/agentic-troubleshooting/helm/k8s-troubleshooting-agent"
  namespace        = "default"
  create_namespace = false
  wait             = true
  timeout          = 300

  values = [
    yamlencode({
      image = {
        repository = var.agentic_image_repository
        tag        = var.agentic_image_tag
        pullPolicy = "Always"
      }

      serviceAccount = {
        create = true
        name   = "k8s-troubleshooting-agent"
      }

      config = {
        clusterName              = module.eks.cluster_name
        awsRegion                = local.region
        bedrockModelId           = var.bedrock_model_id
        classificationModelId    = var.bedrock_classification_model_id
        logLevel                 = "INFO"

        # Vector Storage Configuration
        vectorBucket = var.vector_bucket_name
        indexName    = var.vector_index_name

        # Memory Agent Configuration
        memoryAgentServerUrl = "http://localhost:9000"

        eksMcp = {
          enabled    = true
          allowWrite = true
        }

        slack = {
          botToken      = var.slack_bot_token
          appToken      = var.slack_app_token
          signingSecret = var.slack_signing_secret
        }
      }

      secrets = {
        slack = {
          botToken      = var.slack_bot_token
          appToken      = var.slack_app_token
          signingSecret = var.slack_signing_secret
        }
      }

      resources = {
        limits = {
          cpu    = "500m"
          memory = "512Mi"
        }
        requests = {
          cpu    = "100m"
          memory = "256Mi"
        }
      }

      rbac = {
        create = true
        rules = [
          {
            apiGroups = [""]
            resources = ["pods", "services", "events"]
            verbs     = ["get", "list", "watch"]
          },
          {
            apiGroups = ["apps"]
            resources = ["deployments", "replicasets"]
            verbs     = ["get", "list", "watch"]
          },
          {
            apiGroups = [""]
            resources = ["pods/log"]
            verbs     = ["get"]
          }
        ]
      }
    })
  ]

  depends_on = [
    aws_eks_pod_identity_association.agentic_agent,
    kubernetes_secret.slack_credentials
  ]
}
