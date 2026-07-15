terraform {
  required_providers {
    kubectl = {
      source  = "alekc/kubectl"
      version = ">= 2.0.2"
    }
  }
}

locals {
  name     = var.name
  region   = "us-west-2"
  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

  tags = {
    Blueprint  = local.name
    GithubRepo = "github.com/aws-ia/terraform-aws-eks-blueprints"
  }
}

provider "aws" {
  region = local.region
}

provider "aws" {
  alias  = "ecr"
  region = "us-east-1"
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}

provider "kubectl" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

data "aws_ecrpublic_authorization_token" "token" {
  provider = aws.ecr
}

data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_caller_identity" "current" {}

################################################################################
# Cluster
################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.11"

  cluster_name                   = local.name
  cluster_version                = "1.34"
  cluster_endpoint_public_access = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  enable_cluster_creator_admin_permissions = true

  eks_managed_node_groups = {
    addons-nodegroup = {
      instance_types = ["m5.large"]
      min_size       = 3
      max_size       = 3
      desired_size   = 3
    }
  }

  node_security_group_tags = merge(local.tags, {
    "karpenter.sh/discovery" = local.name
  })

  tags = local.tags
}

################################################################################
# EKS Blueprints Addons
################################################################################

module "eks_blueprints_addons" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "~> 1.16"

  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  cluster_version   = module.eks.cluster_version
  oidc_provider_arn = module.eks.oidc_provider_arn

  eks_addons = {
    coredns                = {}
    vpc-cni                = {}
    kube-proxy             = {}
    eks-pod-identity-agent = {}
  }

  enable_metrics_server               = true
  enable_karpenter                    = false
  enable_aws_load_balancer_controller = false
  enable_kube_prometheus_stack        = true
  kube_prometheus_stack = {
    values = [
      templatefile("${path.module}/manifests/kube-prometheus-stack-values.yaml", {
        slack_webhook_url  = var.slack_webhook_url,
        slack_channel_name = var.slack_channel_name
      })
    ]
  }

  karpenter_node = {
    iam_role_use_name_prefix = false
  }

  tags = local.tags
}

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.24"

  cluster_name          = module.eks.cluster_name
  enable_v1_permissions = true
  namespace             = "kube-system"

  node_iam_role_use_name_prefix   = false
  node_iam_role_name              = local.name
  create_pod_identity_association = true
  enable_pod_identity             = true

  tags = local.tags
}

resource "helm_release" "karpenter" {
  name                = "karpenter"
  namespace           = "kube-system"
  create_namespace    = false
  repository          = "oci://public.ecr.aws/karpenter"
  repository_username = data.aws_ecrpublic_authorization_token.token.user_name
  repository_password = data.aws_ecrpublic_authorization_token.token.password
  chart               = "karpenter"
  version             = "1.0.2"
  wait                = false

  values = [
    <<-EOT
    settings:
      clusterName: ${module.eks.cluster_name}
      clusterEndpoint: ${module.eks.cluster_endpoint}
      interruptionQueue: ${module.karpenter.queue_name}
    tolerations:
      - key: CriticalAddonsOnly
        operator: Exists
      - key: karpenter.sh/controller
        operator: Exists
        effect: NoSchedule
    webhook:
      enabled: false
    EOT
  ]

  lifecycle {
    ignore_changes = [
      repository_password
    ]
  }
}

################################################################################
# Prometheus Rules
################################################################################

data "local_file" "prometheus_rule" {
  filename = "${path.module}/manifests/prometheus-rule.yaml"
}

resource "kubectl_manifest" "prometheus_rule" {
  yaml_body = data.local_file.prometheus_rule.content

  depends_on = [
    module.eks_blueprints_addons
  ]
}

################################################################################
# Supporting Resources
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = local.name
  cidr = local.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 48)]

  enable_nat_gateway = true
  single_nat_gateway = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    "karpenter.sh/discovery"          = local.name
  }

  tags = local.tags
}

################################################################################
# Karpenter NodePool and NodeClass
################################################################################

resource "helm_release" "karpenter_default" {
  name       = "karpenter-default"
  chart      = "${path.module}/manifests/karpenter-chart"
  namespace  = "default"
  wait       = false
  depends_on = [module.eks, module.karpenter, helm_release.karpenter]
  set = [
    {
      name  = "clusterName"
      value = local.name
    }
  ]
}

################################################################################
# Guidance Solution ID
################################################################################

resource "random_bytes" "this" {
  count  = 1
  length = 2
}

resource "aws_cloudformation_stack" "guidance_deployment_metrics" {
  count = 1

  name          = "tracking-stack-${random_bytes.this[0].hex}"
  on_failure    = "DO_NOTHING"
  template_body = <<STACK
    {
        "AWSTemplateFormatVersion": "2010-09-09",
        "Description": "(SO9669) This is a CFN stack for Solution Guidance Troubleshooting Amazon EKS using Agentic AI workflow on AWS",
        "Resources": {
            "EmptyResource": {
                "Type": "AWS::CloudFormation::WaitConditionHandle"
            }
        }
    }
    STACK
}
