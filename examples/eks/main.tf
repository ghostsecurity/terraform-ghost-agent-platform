# EKS example: a complete from-scratch deployment on Amazon EKS.
#
# Provisions a VPC, an EKS cluster with everything the platform needs
# (network policy enforcement, EKS Pod Identity, the EBS and EFS CSI
# drivers, and the AWS Load Balancer Controller), and two node groups:
# "system" for the platform's control plane and "workers", tainted, for
# the agents. Then installs the platform with the modules/eks module.
#
# Intended as a starting point and test bed. For production, copy this
# into a new directory, point the module `source` at a tagged version
# (`source = "github.com/ghostsecurity/terraform-ghost-agent-platform//modules/eks?ref=vX.Y.Z"`),
# and adapt the network and node groups, or install into an existing
# cluster that meets the module's prerequisites.
#
# Usage (the Kubernetes and Helm providers need the cluster to exist, so
# the first apply runs in two steps). The first step names every module
# the cluster needs: a target brings along only what the cluster
# references, which leaves out the VPC's NAT gateway and routes and the
# CSI drivers' IAM policies.
#   cp terraform.tfvars.example terraform.tfvars
#   # ... fill in terraform.tfvars
#   terraform init
#   terraform apply -target=module.vpc -target=module.ebs_csi_pod_identity \
#     -target=module.efs_csi_pod_identity -target=module.eks
#   terraform apply
#
# Tear down in the reverse order (see the README for the full steps):
#   terraform destroy -target=module.ghost_agent
#   terraform destroy

terraform {
  required_version = ">= 1.5.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.59"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.3"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.3"
    }
  }

  # Remote state: the module generates the encryption key and claim token,
  # so their values live in state. Keep it encrypted, not on a laptop.
  # backend "s3" {
  #   bucket       = "<state bucket>"
  #   key          = "ghost-agent/eks/terraform.tfstate"
  #   region       = "us-east-1"
  #   encrypt      = true
  #   kms_key_id   = "alias/<state key>"
  #   use_lockfile = true
  # }
}

provider "aws" {
  region = var.aws_region
}

locals {
  name = var.name

  # Two availability zones: one subnet each for nodes and EFS mount
  # targets, and one public subnet each for the load balancer.
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  # Ghost Security's registry, which serves the chart and the images.
  ghost_registry = "052783882429.dkr.ecr.us-east-1.amazonaws.com"

  system_node_labels = { "exo.ghost.security/node-role" = "system" }
  worker_node_labels = { "exo.ghost.security/node-role" = "worker" }
}

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

# ----------------------------------------------------------------------
# Network: VPC with private node subnets and public load balancer
# subnets, one NAT gateway
# ----------------------------------------------------------------------

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.7"

  name = local.name
  cidr = "10.20.0.0/16"
  azs  = local.azs

  private_subnets = ["10.20.0.0/19", "10.20.32.0/19"]
  public_subnets  = ["10.20.64.0/24", "10.20.65.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true

  # Subnet discovery for the AWS Load Balancer Controller.
  public_subnet_tags  = { "kubernetes.io/role/elb" = 1 }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1 }
}

# ----------------------------------------------------------------------
# EKS cluster
# ----------------------------------------------------------------------

# Attached only to the system node group: the platform's private file
# system accepts NFS from this group alone, so worker nodes can never
# mount it.
resource "aws_security_group" "control_plane_nodes" {
  name_prefix = "${local.name}-control-plane-nodes-"
  description = "Ghost Agent Platform control-plane nodes"
  vpc_id      = module.vpc.vpc_id

  tags = { Name = "${local.name}-control-plane-nodes" }

  lifecycle {
    create_before_destroy = true
  }
}

module "ebs_csi_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.9"

  name                      = "${local.name}-ebs-csi"
  attach_aws_ebs_csi_policy = true
}

module "efs_csi_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.9"

  name                      = "${local.name}-efs-csi"
  attach_aws_efs_csi_policy = true
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.29"

  name               = local.name
  kubernetes_version = var.kubernetes_version

  # Fixed so the platform's pinned Service addresses (.12 and .13 of this
  # range) are predictable.
  service_ipv4_cidr = "172.20.0.0/16"

  endpoint_public_access                   = true
  endpoint_public_access_cidrs             = var.cluster_admin_cidrs
  enable_cluster_creator_admin_permissions = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Pod traffic between nodes passes the node security group. The
  # module's recommended rules already allow TCP 1025-65535 between
  # nodes; workers also send DNS to the credential proxy on UDP 8053.
  node_security_group_additional_rules = {
    ingress_self_credential_proxy_dns = {
      description = "Worker DNS queries to the credential proxy"
      protocol    = "udp"
      from_port   = 8053
      to_port     = 8053
      type        = "ingress"
      self        = true
    }
  }

  addons = {
    # Network policy enforcement confines worker traffic to the
    # credential proxy and the gateway.
    vpc-cni = {
      before_compute       = true
      configuration_values = jsonencode({ enableNetworkPolicy = "true" })
    }
    eks-pod-identity-agent = {
      before_compute = true
    }
    coredns    = {}
    kube-proxy = {}
    aws-ebs-csi-driver = {
      pod_identity_association = [{
        role_arn        = module.ebs_csi_pod_identity.iam_role_arn
        service_account = "ebs-csi-controller-sa"
      }]
    }
    aws-efs-csi-driver = {
      pod_identity_association = [{
        role_arn        = module.efs_csi_pod_identity.iam_role_arn
        service_account = "efs-csi-controller-sa"
      }]
    }
  }

  # Both groups require IMDSv2 with a hop limit of 1 (the module's
  # default), so pods cannot reach the node's instance metadata.
  eks_managed_node_groups = {
    # Gateway, credential proxy, updater, UI, database, and cluster
    # add-ons.
    system = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = ["m7i.large"]
      min_size       = 2
      max_size       = 3
      desired_size   = 2

      labels                 = local.system_node_labels
      vpc_security_group_ids = [aws_security_group.control_plane_nodes.id]

      # Session Manager on these nodes only: the path for your own
      # port forwarding and for Ghost support access. Worker nodes run
      # agent code and stay out of it.
      iam_role_additional_policies = {
        AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
      }

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 50
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }
    }

    # Agents only: the taint keeps everything else off these nodes.
    workers = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = ["m7i.xlarge"]
      min_size       = 1
      max_size       = 3
      desired_size   = 1

      labels = local.worker_node_labels
      taints = {
        dedicated = {
          key    = "dedicated"
          value  = "exo-worker"
          effect = "NO_SCHEDULE"
        }
      }

      # Room for worker images and each run's scratch space.
      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 100
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }
    }
  }
}

# ----------------------------------------------------------------------
# Kubernetes and Helm providers
# ----------------------------------------------------------------------

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
  }
}

# Login for the platform's chart, read fresh on every run.
data "aws_ecr_authorization_token" "ghost" {
  registry_id = split(".", local.ghost_registry)[0]
  region      = split(".", local.ghost_registry)[3]
}

provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
    }
  }

  registries = [{
    url      = "oci://${local.ghost_registry}"
    username = data.aws_ecr_authorization_token.ghost.user_name
    password = data.aws_ecr_authorization_token.ghost.password
  }]
}

# ----------------------------------------------------------------------
# AWS Load Balancer Controller
# ----------------------------------------------------------------------

module "lb_controller_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.9"

  name                            = "${local.name}-lb-controller"
  attach_aws_lb_controller_policy = true

  associations = {
    this = {
      cluster_name    = module.eks.cluster_name
      namespace       = "kube-system"
      service_account = "aws-load-balancer-controller"
    }
  }
}

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "3.6.0"

  values = [yamlencode({
    clusterName = module.eks.cluster_name
    # Set explicitly: the nodes' instance metadata is out of reach.
    region       = var.aws_region
    vpcId        = module.vpc.vpc_id
    nodeSelector = local.system_node_labels
    serviceAccount = {
      create = true
      name   = "aws-load-balancer-controller"
    }
    # The platform uses an Ingress, not LoadBalancer Services. Without the
    # Service webhook, creating any Service never waits on this controller.
    enableServiceMutatorWebhook = false
  })]

  depends_on = [module.lb_controller_pod_identity]
}

# ----------------------------------------------------------------------
# Ghost Agent Platform
# ----------------------------------------------------------------------

module "ghost_agent" {
  source = "../../modules/eks"

  cluster_name = module.eks.cluster_name
  exo_version  = var.exo_version
  domain_name  = var.domain_name

  route53_zone_id     = var.route53_zone_id
  acm_certificate_arn = var.acm_certificate_arn
  ingress_cidrs       = var.ingress_cidrs

  subnet_ids                            = module.vpc.private_subnets
  node_security_group_ids               = [module.eks.node_security_group_id]
  control_plane_node_security_group_ids = [aws_security_group.control_plane_nodes.id]

  control_plane_node_selector = local.system_node_labels
  worker_node_selector        = local.worker_node_labels
  worker_tolerations = [{
    key      = "dedicated"
    operator = "Equal"
    value    = "exo-worker"
    effect   = "NoSchedule"
  }]

  worker_pools = [{ name = "default", replicas = 2 }]

  # No depends_on here: it would postpone the module's reads of the
  # cluster to apply time whenever the cluster changes, and make Terraform
  # replace resources built from them. The cluster and its add-ons exist
  # from the first apply step, and the load balancer controller has long
  # started by the time the module creates its Ingress, after the
  # platform's release is up.
}

# ----------------------------------------------------------------------
# Example inputs (set in terraform.tfvars)
# ----------------------------------------------------------------------

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "name" {
  description = "Name for the cluster, VPC, and the platform's AWS resources."
  type        = string
  default     = "ghost-agent-eks"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version: any version in EKS standard support. The node groups need it set explicitly."
  type        = string
  default     = "1.37"

  validation {
    condition     = can(regex("^1\\.[0-9]+$", var.kubernetes_version))
    error_message = "kubernetes_version must be a Kubernetes minor version such as \"1.36\"."
  }
}

variable "cluster_admin_cidrs" {
  description = "CIDR blocks allowed to reach the cluster's public API endpoint: where you run Terraform and kubectl from."
  type        = list(string)
}

variable "exo_version" {
  description = "Release to install, for example \"v1.2.3\"."
  type        = string
}

variable "domain_name" {
  description = "Public hostname, for example \"ghost.example.com\"."
  type        = string
}

variable "route53_zone_id" {
  description = "Route 53 hosted zone for domain_name. The module validates a certificate in it and points domain_name at the load balancer."
  type        = string
  default     = ""
}

variable "acm_certificate_arn" {
  description = "Existing ACM certificate for domain_name, instead of a new one validated in route53_zone_id."
  type        = string
  default     = ""
}

variable "ingress_cidrs" {
  description = "CIDR blocks allowed to reach the load balancer."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# ----------------------------------------------------------------------
# Outputs
# ----------------------------------------------------------------------

output "url" {
  value = module.ghost_agent.url
}

output "claim_token" {
  value     = module.ghost_agent.claim_token
  sensitive = true
}

output "load_balancer_hostname" {
  value = module.ghost_agent.load_balancer_hostname
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

output "port_forward_command" {
  value = module.ghost_agent.port_forward_command
}

output "helm_test_command" {
  value = module.ghost_agent.helm_test_command
}

output "ghost_support_role_arn" {
  value = module.ghost_agent.ghost_support_role_arn
}
