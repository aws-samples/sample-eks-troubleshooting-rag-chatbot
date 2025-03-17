locals {
  name   = var.name
  region = "us-east-1"
  container_builder = "docker"

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
    # This requires the awscli to be installed locally where Terraform is executed
    args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      # This requires the awscli to be installed locally where Terraform is executed
      args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
  registry {
    url = "oci://public.ecr.aws"
    username = "AWS"
    password = data.aws_ecrpublic_authorization_token.token.password
  }
}

data "aws_ecrpublic_authorization_token" "token" {
  provider = aws.ecr
}

data "aws_availability_zones" "available" {
  # Do not include local zones
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
  cluster_version                = "1.31"
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
module "iam_eks_role" {
  source    = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version   = "~> 5.33.0"
  role_name = "${local.name}-fluentbit-role"

  role_policy_arns = {
    policy = "arn:aws:iam::aws:policy/AdministratorAccess"
  }

  oidc_providers = {
    one = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["logging:fluentbit-sa"]
    }
  }
}


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
    # Use static name so that it matches what is defined in `karpenter.yaml` example manifest
    iam_role_use_name_prefix = false
  }

  helm_releases = {
    fluentbit = {
      name             = "fluentbit"
      description      = "Fluentbit log collector"
      repository       = "https://fluent.github.io/helm-charts"
      chart            = "fluent-bit"
      create_namespace = true
      namespace        = "logging"
      values = [
        <<-EOT
          serviceAccount:
            create: true
            name: "fluentbit-sa"
            annotations:
                eks.amazonaws.com/role-arn: "${module.iam_eks_role.iam_role_arn}"

          rbac:
            create: true
            nodeAccess: true
            eventsAccess: true

          config:
            inputs: |
                [INPUT]
                    Name              tail
                    Tag               kube.*
                    Path              /var/log/containers/*.log
                    Parser            docker
                    DB                /var/log/flb_kube.db
                    Mem_Buf_Limit     10MB
                    Skip_Long_Lines   On
                    Refresh_Interval  20
                [INPUT]
                    name            kubernetes_events
                    tag             k8s_events
                    kube_url        https://kubernetes.default.svc
                [INPUT]
                    Name systemd
                    Tag host.*
                    Systemd_Filter _SYSTEMD_UNIT=kubelet.service
                    Read_From_Tail On
            filters: |
                [FILTER]
                    Name                kubernetes
                    Match               kube.*
                    Kube_URL            https://kubernetes.default.svc.cluster.local:443
                    Merge_Log           On
                    Merge_Log_Key       data
                    Keep_Log            On
                    K8S-Logging.Parser  On
                    K8S-Logging.Exclude On
                [FILTER]
                    Name                grep
                    Match               kube.*
                    Exclude             $kubernetes['labels']['application'] agentic-chatbot
            outputs: |
                [OUTPUT]
                    Name            kinesis_streams
                    Match           *
                    region          ${local.region}
                    stream ${local.name}-eks-logs
                    time_key        time
                    time_key_format %Y-%m-%dT%H:%M:%S
            customParsers: |
                [PARSER]
                    Name   apache
                    Format regex
                    Regex  ^(?<host>[^ ]*) [^ ]* (?<user>[^ ]*) \[(?<time>[^\]]*)\] "(?<method>\S+)(?: +(?<path>[^\"]*?)(?: +\S*)?)?" (?<code>[^ ]*) (?<size>[^ ]*)(?: "(?<referer>[^\"]*)" "(?<agent>[^\"]*)")?$
                    Time_Key time
                    Time_Format %d/%b/%Y:%H:%M:%S %z

                [PARSER]
                    Name   apache2
                    Format regex
                    Regex  ^(?<host>[^ ]*) [^ ]* (?<user>[^ ]*) \[(?<time>[^\]]*)\] "(?<method>\S+)(?: +(?<path>[^ ]*) +\S*)?" (?<code>[^ ]*) (?<size>[^ ]*)(?: "(?<referer>[^\"]*)" "(?<agent>.*)")?$
                    Time_Key time
                    Time_Format %d/%b/%Y:%H:%M:%S %z

                [PARSER]
                    Name   apache_error
                    Format regex
                    Regex  ^\[[^ ]* (?<time>[^\]]*)\] \[(?<level>[^\]]*)\](?: \[pid (?<pid>[^\]]*)\])?( \[client (?<client>[^\]]*)\])? (?<message>.*)$

                [PARSER]
                    Name   nginx
                    Format regex
                    Regex ^(?<remote>[^ ]*) (?<host>[^ ]*) (?<user>[^ ]*) \[(?<time>[^\]]*)\] "(?<method>\S+)(?: +(?<path>[^\"]*?)(?: +\S*)?)?" (?<code>[^ ]*) (?<size>[^ ]*)(?: "(?<referer>[^\"]*)" "(?<agent>[^\"]*)")
                    Time_Key time
                    Time_Format %d/%b/%Y:%H:%M:%S %z

                [PARSER]
                    # https://rubular.com/r/IhIbCAIs7ImOkc
                    Name        k8s-nginx-ingress
                    Format      regex
                    Regex       ^(?<host>[^ ]*) - (?<user>[^ ]*) \[(?<time>[^\]]*)\] "(?<method>\S+)(?: +(?<path>[^\"]*?)(?: +\S*)?)?" (?<code>[^ ]*) (?<size>[^ ]*) "(?<referer>[^\"]*)" "(?<agent>[^\"]*)" (?<request_length>[^ ]*) (?<request_time>[^ ]*) \[(?<proxy_upstream_name>[^ ]*)\] (\[(?<proxy_alternative_upstream_name>[^ ]*)\] )?(?<upstream_addr>[^ ]*) (?<upstream_response_length>[^ ]*) (?<upstream_response_time>[^ ]*) (?<upstream_status>[^ ]*) (?<reg_id>[^ ]*).*$
                    Time_Key    time
                    Time_Format %d/%b/%Y:%H:%M:%S %z

                [PARSER]
                    Name   json
                    Format json
                    Time_Key time
                    Time_Format %d/%b/%Y:%H:%M:%S %z

                [PARSER]
                    Name   logfmt
                    Format logfmt

                [PARSER]
                    Name         docker
                    Format       json
                    Time_Key     time
                    Time_Format  %Y-%m-%dT%H:%M:%S.%L
                    Time_Keep    On
                    # --
                    # Since Fluent Bit v1.2, if you are parsing Docker logs and using
                    # the Kubernetes filter, it's not longer required to decode the
                    # 'log' key.
                    #
                    # Command      |  Decoder | Field | Optional Action
                    # =============|==================|=================
                    #Decode_Field_As    json     log

                [PARSER]
                    Name        docker-daemon
                    Format      regex
                    Regex       time="(?<time>[^ ]*)" level=(?<level>[^ ]*) msg="(?<msg>[^ ].*)"
                    Time_Key    time
                    Time_Format %Y-%m-%dT%H:%M:%S.%L
                    Time_Keep   On

                [PARSER]
                    Name        syslog-rfc5424
                    Format      regex
                    Regex       ^\<(?<pri>[0-9]{1,5})\>1 (?<time>[^ ]+) (?<host>[^ ]+) (?<ident>[^ ]+) (?<pid>[-0-9]+) (?<msgid>[^ ]+) (?<extradata>(\[(.*?)\]|-)) (?<message>.+)$
                    Time_Key    time
                    Time_Format %Y-%m-%dT%H:%M:%S.%L%z
                    Time_Keep   On

                [PARSER]
                    Name        syslog-rfc3164-local
                    Format      regex
                    Regex       ^\<(?<pri>[0-9]+)\>(?<time>[^ ]* {1,2}[^ ]* [^ ]*) (?<ident>[a-zA-Z0-9_\/\.\-]*)(?:\[(?<pid>[0-9]+)\])?(?:[^\:]*\:)? *(?<message>.*)$
                    Time_Key    time
                    Time_Format %b %d %H:%M:%S
                    Time_Keep   On

                [PARSER]
                    Name        syslog-rfc3164
                    Format      regex
                    Regex       /^\<(?<pri>[0-9]+)\>(?<time>[^ ]* {1,2}[^ ]* [^ ]*) (?<host>[^ ]*) (?<ident>[a-zA-Z0-9_\/\.\-]*)(?:\[(?<pid>[0-9]+)\])?(?:[^\:]*\:)? *(?<message>.*)$/
                    Time_Key    time
                    Time_Format %b %d %H:%M:%S
                    Time_Keep   On

                [PARSER]
                    Name    mongodb
                    Format  regex
                    Regex   ^(?<time>[^ ]*)\s+(?<severity>\w)\s+(?<component>[^ ]+)\s+\[(?<context>[^\]]+)]\s+(?<message>.*?) *(?<ms>(\d+))?(:?ms)?$
                    Time_Format %Y-%m-%dT%H:%M:%S.%L
                    Time_Keep   On
                    Time_Key time

                [PARSER]
                    # https://rubular.com/r/0VZmcYcLWMGAp1
                    Name    envoy
                    Format  regex
                    Regex ^\[(?<start_time>[^\]]*)\] "(?<method>\S+)(?: +(?<path>[^\"]*?)(?: +\S*)?)? (?<protocol>\S+)" (?<code>[^ ]*) (?<response_flags>[^ ]*) (?<bytes_received>[^ ]*) (?<bytes_sent>[^ ]*) (?<duration>[^ ]*) (?<x_envoy_upstream_service_time>[^ ]*) "(?<x_forwarded_for>[^ ]*)" "(?<user_agent>[^\"]*)" "(?<request_id>[^\"]*)" "(?<authority>[^ ]*)" "(?<upstream_host>[^ ]*)"
                    Time_Format %Y-%m-%dT%H:%M:%S.%L%z
                    Time_Keep   On
                    Time_Key start_time

                [PARSER]
                    # https://rubular.com/r/17KGEdDClwiuDG
                    Name    istio-envoy-proxy
                    Format  regex
                    Regex ^\[(?<start_time>[^\]]*)\] "(?<method>\S+)(?: +(?<path>[^\"]*?)(?: +\S*)?)? (?<protocol>\S+)" (?<response_code>[^ ]*) (?<response_flags>[^ ]*) (?<response_code_details>[^ ]*) (?<connection_termination_details>[^ ]*) (?<upstream_transport_failure_reason>[^ ]*) (?<bytes_received>[^ ]*) (?<bytes_sent>[^ ]*) (?<duration>[^ ]*) (?<x_envoy_upstream_service_time>[^ ]*) "(?<x_forwarded_for>[^ ]*)" "(?<user_agent>[^\"]*)" "(?<x_request_id>[^\"]*)" (?<authority>[^ ]*)" "(?<upstream_host>[^ ]*)" (?<upstream_cluster>[^ ]*) (?<upstream_local_address>[^ ]*) (?<downstream_local_address>[^ ]*) (?<downstream_remote_address>[^ ]*) (?<requested_server_name>[^ ]*) (?<route_name>[^  ]*)
                    Time_Format %Y-%m-%dT%H:%M:%S.%L%z
                    Time_Keep   On
                    Time_Key start_time

                [PARSER]
                    # http://rubular.com/r/tjUt3Awgg4
                    Name cri
                    Format regex
                    Regex ^(?<time>[^ ]+) (?<stream>stdout|stderr) (?<logtag>[^ ]*) (?<message>.*)$
                    Time_Key    time
                    Time_Format %Y-%m-%dT%H:%M:%S.%L%z
                    Time_Keep   On

                [PARSER]
                    Name    kube-custom
                    Format  regex
                    Regex   (?<tag>[^.]+)?\.?(?<pod_name>[a-z0-9](?:[-a-z0-9]*[a-z0-9])?(?:\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*)_(?<namespace_name>[^_]+)_(?<container_name>.+)-(?<docker_id>[a-z0-9]{64})\.log$

                [PARSER]
                    # Examples: TCP: https://rubular.com/r/Q8YY6fHqlqwGI0  UDP: https://rubular.com/r/B0ID69H9FvN0tp
                    Name    kmsg-netfilter-log
                    Format  regex
                    Regex   ^\<(?<pri>[0-9]{1,5})\>1 (?<time>[^ ]+) (?<host>[^ ]+) kernel - - - \[[0-9\.]*\] (?<logprefix>[^ ]*)\s?IN=(?<in>[^ ]*) OUT=(?<out>[^ ]*) MAC=(?<macsrc>[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}):(?<macdst>[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}):(?<ethtype>[0-9a-f]{2}:[0-9a-f]{2}) SRC=(?<saddr>[^ ]*) DST=(?<daddr>[^ ]*) LEN=(?<len>[^ ]*) TOS=(?<tos>[^ ]*) PREC=(?<prec>[^ ]*) TTL=(?<ttl>[^ ]*) ID=(?<id>[^ ]*) (D*F*)\s*PROTO=(?<proto>[^ ]*)\s?((SPT=)?(?<sport>[0-9]*))\s?((DPT=)?(?<dport>[0-9]*))\s?((LEN=)?(?<protolen>[0-9]*))\s?((WINDOW=)?(?<window>[0-9]*))\s?((RES=)?(?<res>0?x?[0-9]*))\s?(?<flag>[^ ]*)\s?((URGP=)?(?<urgp>[0-9]*))
                    Time_Key  time
                    Time_Format  %Y-%m-%dT%H:%M:%S.%L%z
        EOT
      ]
    }
  }
  tags = local.tags
}

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.24"

  cluster_name          = module.eks.cluster_name
  enable_v1_permissions = true
  namespace             = "kube-system"

  # Name needs to match role name passed to the EC2NodeClass
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

resource "kubernetes_manifest" "prometheus_rule" {
  manifest = yamldecode(data.local_file.prometheus_rule.content)
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
    # Tags subnets for Karpenter auto-discovery
    "karpenter.sh/discovery" = local.name
  }

  tags = local.tags
}

################################################################################
# Logs Ingestion Pipeline
################################################################################

module "ingestion_pipeline" {
  source = "./modules/ingestion-pipeline"
  name = var.name
  collection_name = var.opensearch_collection_name
  region = local.region
  container_builder = local.container_builder
}

################################################################################
# Agentic ChatBot
################################################################################

module "agentic_chatbot" {
  source = "./modules/agentic-chatbot"
  name = var.name
  collection_name = var.opensearch_collection_name
  collection_arn = module.ingestion_pipeline.collection_arn
  region = local.region
  eks_cluster_oidc_arn = module.eks.oidc_provider_arn
  container_builder = local.container_builder
  depends_on = [module.ingestion_pipeline]
}

resource "helm_release" "agentic-chatbot" {
  name             = "agentic-chatbot"
  chart            = "./manifests/chatbot-chart"
  create_namespace = true
  wait             = true
  replace          = true
  namespace        = "agentic-chatbot"

  values = [
    <<-EOT
    logLevel: INFO
    image:
      repository: ${module.agentic_chatbot.chatbot_ecr_repo}
      pullPolicy: Always
      tag: "latest"
    serviceAccount:
      create: true
      annotations:
        eks.amazonaws.com/role-arn: ${module.agentic_chatbot.chatbot_role_arn}
    aws:
      region: ${local.region}
      role: ${module.agentic_chatbot.chatbot_role_arn}
      opensearch_endpoint: ${replace(module.ingestion_pipeline.collection_endpoint,"/(^https://)|(/$)/","")}
    resources:
      limits:
        cpu: "1000m"
        memory: 2Gi
      requests:
        cpu: "500m"
        memory: 1Gi
    service:
      type: ClusterIP
      port: 7860
    securityContext:
      runAsNonRoot: true
      runAsUser: 1000
    fullnameOverride: agentic-chatbot
    EOT
  ]
  depends_on = [module.eks, helm_release.karpenter, module.ingestion_pipeline, module.agentic_chatbot]
}

################################################################################
# Karpenter NodePool and NodeClass
################################################################################

# Deploy default Karpenter resources using Helm

resource "helm_release" "karpenter_default" {
  name       = "karpenter-default"
  chart      = "${path.module}/manifests/karpenter-chart"
  namespace  = "default"
  wait       = false
  depends_on = [module.eks, module.karpenter, helm_release.karpenter]
  # Set the cluster name for all resources
  set {
    name  = "clusterName"
    value = local.name
  }
}
# Deploy GPU Karpenter resources using Helm
resource "helm_release" "karpenter_gpu" {
  name       = "karpenter-gpu"
  chart      = "${path.module}/manifests/karpenter-chart"
  namespace  = "default"
  wait       = false
  values     = [file("${path.module}/manifests/karpenter-chart/values-gpu.yaml")]
  depends_on = [module.eks, module.karpenter, helm_release.karpenter]
  # Set the cluster name for all resources
  set {
    name  = "clusterName"
    value = local.name
  }
}


################################################################################
# DeepSeek Deployment using vLLM
################################################################################

resource "helm_release" "deepseek_gpu" {
  name             = "deepseek-gpu"
  chart            = "./manifests/vllm-chart"
  create_namespace = true
  wait             = false
  replace          = true
  namespace        = "deepseek"

  values = [
    <<-EOT
    nodeSelector:
      owner: "data-engineer"
    tolerations:
      - key: "nvidia.com/gpu"
        operator: "Exists"
        effect: "NoSchedule"
    resources:
      limits:
        cpu: "32"
        memory: 100G
        nvidia.com/gpu: "1"
      requests:
        cpu: "16"
        memory: 30G
        nvidia.com/gpu: "1"
    command: "vllm serve deepseek-ai/DeepSeek-R1-Distill-Llama-8B --max-model-len 4096"
    EOT
  ]
  depends_on = [module.eks, helm_release.karpenter_gpu, helm_release.karpenter]
}

resource "helm_release" "nvidia_device_plugin" {
  name             = "nvidia-device-plugin"
  repository       = "https://nvidia.github.io/k8s-device-plugin"
  chart            = "nvidia-device-plugin"
  version          = "0.17.0"
  namespace        = "nvidia-device-plugin"
  create_namespace = true
  wait             = true

  depends_on = [module.eks, helm_release.karpenter]
}