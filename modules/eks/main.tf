# ----------------------------------------------------------------------
# Cluster, network, and account data
# ----------------------------------------------------------------------

data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

data "aws_vpc" "this" {
  id = data.aws_eks_cluster.this.vpc_config[0].vpc_id
}

data "aws_region" "current" {}

# ----------------------------------------------------------------------
# Locals
# ----------------------------------------------------------------------

locals {
  name   = var.name_prefix
  region = data.aws_region.current.region
  vpc_id = data.aws_vpc.this.id

  # Ghost's account and region from the registry URL
  # (<account>.dkr.ecr.<region>.amazonaws.com, validated in variables.tf).
  registry_parts   = split(".", var.image_registry)
  ghost_account_id = local.registry_parts[0]
  ghost_region     = local.registry_parts[3]

  # Chart versions are the release tag without its "v".
  chart_version = trimprefix(var.exo_version, "v")

  # Worker pods use the credential proxy as their DNS server, and it
  # answers "gateway" with the gateway's address, so both Services get
  # fixed addresses from the low, statically allocated end of the
  # cluster's Service range. The UI Service gets one too, as the
  # destination of the Ghost support UI session.
  ip_family           = data.aws_eks_cluster.this.kubernetes_network_config[0].ip_family
  service_cidr        = data.aws_eks_cluster.this.kubernetes_network_config[0].service_ipv4_cidr
  credential_proxy_ip = cidrhost(local.service_cidr, 12)
  gateway_ip          = cidrhost(local.service_cidr, 13)
  ui_ip               = cidrhost(local.service_cidr, 14)

  # With the VPC CNI, pods and the load balancer take addresses from the
  # VPC's ranges. Workers enroll from them, and the UI front and gateway
  # trust X-Forwarded-For from them.
  pod_cidrs = distinct(concat(
    [data.aws_vpc.this.cidr_block],
    [for a in data.aws_vpc.this.cidr_block_associations : a.cidr_block],
  ))

  ses_region = var.ses_region != "" ? var.ses_region : local.region

  # Optional toleration fields left unset are dropped rather than passed
  # to the chart as nulls.
  worker_tolerations        = [for t in var.worker_tolerations : { for k, v in t : k => v if v != null }]
  control_plane_tolerations = [for t in var.control_plane_tolerations : { for k, v in t : k => v if v != null }]

  control_plane_placement = {
    nodeSelector = var.control_plane_node_selector
    tolerations  = local.control_plane_tolerations
  }

  common_tags = merge(
    {
      ManagedBy = "terraform-ghost-agent-platform"
      Component = "ghost-agent-platform"
    },
    var.tags,
  )
}
