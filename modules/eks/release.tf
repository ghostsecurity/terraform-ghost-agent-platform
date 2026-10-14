# ----------------------------------------------------------------------
# Namespace
# ----------------------------------------------------------------------

resource "kubernetes_namespace_v1" "this" {
  metadata {
    name = var.namespace

    labels = {
      "pod-security.kubernetes.io/enforce"         = "restricted"
      "pod-security.kubernetes.io/enforce-version" = "latest"
      "pod-security.kubernetes.io/warn"            = "restricted"
      "pod-security.kubernetes.io/audit"           = "restricted"
    }
  }

  # On destroy, the namespace goes before EFS: deleting a namespace waits
  # until its pods are gone, and a pod can only go once its EFS volumes
  # are unmounted, which needs the mount targets and NFS rules still there.
  depends_on = [
    aws_efs_mount_target.private,
    aws_efs_mount_target.shared,
    aws_vpc_security_group_ingress_rule.efs_private,
    aws_vpc_security_group_ingress_rule.efs_shared,
  ]

  # Checked here rather than on the release, which may be installed
  # outside this module (manage_release = false).
  lifecycle {
    precondition {
      condition     = local.ip_family == "ipv4"
      error_message = "The cluster uses ${local.ip_family}; the Ghost Agent Platform needs an IPv4 cluster."
    }

    precondition {
      condition     = !var.enable_ses_email || var.email_from != ""
      error_message = "email_from is required when enable_ses_email is true."
    }
  }
}

# ----------------------------------------------------------------------
# Helm release
# ----------------------------------------------------------------------

locals {
  helm_values = {
    global = {
      imageRegistry = var.image_registry
    }

    domain = var.domain_name

    # The module manages the Ingress itself (ingress.tf) so it can wait
    # for the load balancer and point DNS at it. Without manage_release,
    # set the chart's ingress values in your own install.
    ingress = {
      enabled = false
    }

    secrets = {
      encryptionKey = { existingSecret = kubernetes_secret_v1.encryption_key.metadata[0].name }
      claimToken    = { existingSecret = kubernetes_secret_v1.claim_token.metadata[0].name }
    }

    networking = {
      podCIDRs = local.pod_cidrs
    }

    gateway         = merge(local.control_plane_placement, { clusterIP = local.gateway_ip })
    credentialProxy = merge(local.control_plane_placement, { clusterIP = local.credential_proxy_ip })
    ui              = merge(local.control_plane_placement, { clusterIP = local.ui_ip })
    updater         = local.control_plane_placement
    database = merge(local.control_plane_placement, {
      persistence = { storageClass = kubernetes_storage_class_v1.database.metadata[0].name }
    })

    storage = {
      sharedStorageClass  = kubernetes_storage_class_v1.efs_shared.metadata[0].name
      privateStorageClass = kubernetes_storage_class_v1.efs_private.metadata[0].name
    }

    workers = {
      nodeSelector = var.worker_node_selector
      tolerations  = local.worker_tolerations
      pools = [for p in var.worker_pools : {
        name         = p.name
        replicas     = p.replicas
        image        = p.image
        capabilities = p.capabilities
      }]
    }
  }

  ses_values = {
    email = {
      provider = "ses"
      from     = var.email_from
      ses      = { region = local.ses_region }
    }
  }

  # One document: what the module installs, and the helm_values output
  # for installing the release yourself.
  release_values = merge(
    local.helm_values,
    { for k, v in local.ses_values : k => v if var.enable_ses_email },
  )
}

# The chart and its images come from var.image_registry; the Helm
# provider must be logged in to it (see the README).
resource "helm_release" "this" {
  count = var.manage_release ? 1 : 0

  name       = var.release_name
  namespace  = kubernetes_namespace_v1.this.metadata[0].name
  repository = "oci://${var.image_registry}"
  chart      = "exo-helmchart"
  version    = local.chart_version

  values = concat(
    [yamlencode(local.release_values)],
    var.extra_helm_values,
  )

  # First installs pull the worker image and provision EFS volumes.
  wait        = true
  timeout     = 1200
  max_history = 10

  depends_on = [
    aws_efs_mount_target.private,
    aws_efs_mount_target.shared,
    aws_vpc_security_group_ingress_rule.efs_private,
    aws_vpc_security_group_ingress_rule.efs_shared,
    # Pods get their AWS identity when they start, so the associations
    # must exist first.
    aws_eks_pod_identity_association.updater,
    aws_eks_pod_identity_association.gateway,
  ]
}
