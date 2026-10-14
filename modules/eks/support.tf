# ----------------------------------------------------------------------
# Ghost support access. Optional, on by default.
# ----------------------------------------------------------------------
#
# Publishes a role that Ghost Security assumes for support. Everything
# goes through AWS Systems Manager Session Manager on the cluster's
# nodes, so it needs no inbound ports and works with a private cluster
# API:
#   - Two port-forwarding session documents with fixed destinations: the
#     platform's UI, and the cluster's API endpoint. Sessions cannot use
#     any other document, so the role opens no shell and reaches nothing
#     else.
#   - Kubernetes access through an EKS access entry, bound to a role in
#     the platform's namespace that can read pods, logs, events, and
#     workloads, and delete pods to restart them. It cannot read Secrets,
#     exec into pods, or forward ports to them. Cluster-wide it can read
#     nodes and volumes only.
# Set var.ghost_support_access_enabled = false to remove all of it.

locals {
  ghost_support_enabled = var.ghost_support_access_enabled

  # The role Ghost Security assumes. It lives in the account that owns
  # image_registry, so the account is taken from there.
  ghost_support_principal_arn = "arn:aws:iam::${local.ghost_account_id}:role/exo-ssm-support"

  # Per namespace, so a second installation's support role cannot reach
  # this one.
  ghost_support_group = "${var.namespace}-ghost-support"

  account_id       = data.aws_caller_identity.current.account_id
  cluster_endpoint = trimprefix(data.aws_eks_cluster.this.endpoint, "https://")

  # Session Manager's own pattern for a local port; 0 picks a free one.
  local_port_parameter = {
    type           = "String"
    description    = "(Optional) Port on the local machine to forward to. An open port is chosen if not provided."
    allowedPattern = "^([0-9]|[1-9][0-9]{1,3}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5])$"
    default        = "0"
  }
}

data "aws_caller_identity" "current" {}

# ----------------------------------------------------------------------
# Session documents
# ----------------------------------------------------------------------

resource "aws_ssm_document" "ghost_support_ui" {
  count = local.ghost_support_enabled ? 1 : 0

  name            = "${local.name}-support-ui"
  document_type   = "Session"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "1.0"
    description   = "Forwards a local port to the Ghost Agent Platform UI for Ghost Security support."
    sessionType   = "Port"
    parameters = {
      localPortNumber = local.local_port_parameter
    }
    properties = {
      # The UI Service's fixed address (ui.clusterIP in the chart).
      type            = "LocalPortForwarding"
      host            = local.ui_ip
      portNumber      = "8080"
      localPortNumber = "{{ localPortNumber }}"
    }
  })

  tags = local.common_tags
}

resource "aws_ssm_document" "ghost_support_api" {
  count = local.ghost_support_enabled ? 1 : 0

  name            = "${local.name}-support-api"
  document_type   = "Session"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "1.0"
    description   = "Forwards a local port to the cluster's private API endpoint for Ghost Security support."
    sessionType   = "Port"
    parameters = {
      localPortNumber = local.local_port_parameter
    }
    properties = {
      type            = "LocalPortForwarding"
      host            = local.cluster_endpoint
      portNumber      = "443"
      localPortNumber = "{{ localPortNumber }}"
    }
  })

  tags = local.common_tags
}

# ----------------------------------------------------------------------
# Support role
# ----------------------------------------------------------------------

resource "aws_iam_role" "ghost_support" {
  count = local.ghost_support_enabled ? 1 : 0

  name = "${local.name}-ssm-support"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = local.ghost_support_principal_arn }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "ghost_support" {
  count = local.ghost_support_enabled ? 1 : 0

  name = "ssm-port-forward"
  role = aws_iam_role.ghost_support[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Sessions on this cluster's nodes. StartSession is authorized
        # against the instance and the session document;
        # SessionDocumentAccessCheck makes the document check explicit,
        # so the default shell document is refused.
        Sid      = "StartSessionOnClusterNodes"
        Effect   = "Allow"
        Action   = "ssm:StartSession"
        Resource = "arn:aws:ec2:${local.region}:${local.account_id}:instance/*"
        Condition = {
          StringEquals = {
            "ssm:resourceTag/eks:cluster-name" = var.cluster_name
          }
          BoolIfExists = {
            "ssm:SessionDocumentAccessCheck" = "true"
          }
        }
      },
      {
        Sid    = "StartSessionWithSupportDocuments"
        Effect = "Allow"
        Action = "ssm:StartSession"
        Resource = [
          aws_ssm_document.ghost_support_ui[0].arn,
          aws_ssm_document.ghost_support_api[0].arn,
        ]
        Condition = {
          BoolIfExists = {
            "ssm:SessionDocumentAccessCheck" = "true"
          }
        }
      },
      {
        # Clean disconnect and reconnect, scoped to the caller's own
        # sessions.
        Sid    = "ManageOwnSessions"
        Effect = "Allow"
        Action = [
          "ssm:TerminateSession",
          "ssm:ResumeSession",
        ]
        Resource = "arn:aws:ssm:${local.region}:${local.account_id}:session/$${aws:userid}-*"
      },
      {
        # Find a node to open the session on. The API takes no resource
        # scope.
        Sid      = "FindNodes"
        Effect   = "Allow"
        Action   = "ssm:DescribeInstanceInformation"
        Resource = "*"
      },
      {
        # The endpoint and CA certificate for a kubeconfig.
        Sid      = "DescribeCluster"
        Effect   = "Allow"
        Action   = "eks:DescribeCluster"
        Resource = data.aws_eks_cluster.this.arn
      },
    ]
  })
}

# ----------------------------------------------------------------------
# Kubernetes access
# ----------------------------------------------------------------------

resource "aws_eks_access_entry" "ghost_support" {
  count = local.ghost_support_enabled ? 1 : 0

  cluster_name      = var.cluster_name
  principal_arn     = aws_iam_role.ghost_support[0].arn
  kubernetes_groups = [local.ghost_support_group]
  type              = "STANDARD"

  tags = local.common_tags

  lifecycle {
    precondition {
      condition     = data.aws_eks_cluster.this.access_config[0].authentication_mode != "CONFIG_MAP"
      error_message = "Ghost support access uses an EKS access entry, which needs the cluster's authentication mode to be API or API_AND_CONFIG_MAP. Change the mode, or set ghost_support_access_enabled = false."
    }
  }
}

resource "kubernetes_role_v1" "ghost_support" {
  count = local.ghost_support_enabled ? 1 : 0

  metadata {
    name      = "ghost-support"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["pods", "pods/log", "events", "services", "endpoints", "configmaps", "persistentvolumeclaims", "serviceaccounts"]
    verbs      = ["get", "list", "watch"]
  }

  # Restart a pod; its Deployment or StatefulSet replaces it.
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["delete"]
  }

  rule {
    api_groups = ["apps"]
    resources  = ["deployments", "statefulsets", "replicasets"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["networking.k8s.io"]
    resources  = ["ingresses", "networkpolicies"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["events.k8s.io"]
    resources  = ["events"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_role_binding_v1" "ghost_support" {
  count = local.ghost_support_enabled ? 1 : 0

  metadata {
    name      = "ghost-support"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.ghost_support[0].metadata[0].name
  }

  subject {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Group"
    name      = local.ghost_support_group
  }
}

# Scheduling and storage problems show on nodes and volumes, which are
# cluster-wide.
resource "kubernetes_cluster_role_v1" "ghost_support" {
  count = local.ghost_support_enabled ? 1 : 0

  metadata {
    name = "${var.namespace}-ghost-support"
  }

  rule {
    api_groups = [""]
    resources  = ["nodes", "persistentvolumes"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["storage.k8s.io"]
    resources  = ["storageclasses"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "ghost_support" {
  count = local.ghost_support_enabled ? 1 : 0

  metadata {
    name = "${var.namespace}-ghost-support"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.ghost_support[0].metadata[0].name
  }

  subject {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Group"
    name      = local.ghost_support_group
  }
}
