# ----------------------------------------------------------------------
# Shared storage: two EFS file systems
# ----------------------------------------------------------------------
#
# The platform's pods share files across nodes, so its volumes are
# ReadWriteMany on EFS:
#   - private: the platform's CA keys, session-signing secret, and service
#     certificates. Mounted by the gateway, credential proxy, and updater,
#     and reachable over NFS only from control-plane nodes.
#   - shared: public CA certificates, run artifacts, and runner identities.
#     Mounted by workers too.
# Volumes are provisioned as EFS access points owned by uid/gid 65532,
# the user the platform's containers run as.
#
# prevent_destroy guards the file systems against `terraform destroy`:
# the private one holds the CAs every runner identity and intercepted
# credential depends on. Remove the line temporarily to tear down a test
# deployment.

resource "aws_efs_file_system" "private" {
  creation_token  = "${local.name}-private"
  encrypted       = true
  throughput_mode = "elastic"

  tags = merge(local.common_tags, { Name = "${local.name}-private" })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_efs_file_system" "shared" {
  creation_token  = "${local.name}-shared"
  encrypted       = true
  throughput_mode = "elastic"

  tags = merge(local.common_tags, { Name = "${local.name}-shared" })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_efs_backup_policy" "private" {
  file_system_id = aws_efs_file_system.private.id

  backup_policy {
    status = var.efs_backup ? "ENABLED" : "DISABLED"
  }
}

resource "aws_efs_backup_policy" "shared" {
  file_system_id = aws_efs_file_system.shared.id

  backup_policy {
    status = var.efs_backup ? "ENABLED" : "DISABLED"
  }
}

# ----------------------------------------------------------------------
# File system policies
# ----------------------------------------------------------------------
#
# A second layer behind the security groups: those decide who can reach
# a mount target, these decide who may mount. Both file systems refuse
# mounts without TLS. The private one admits only the control-plane
# nodes' IAM roles, which its storage class mounts with (the `iam` mount
# option); the EFS driver's node agent takes the node's role from the
# instance metadata. No client gets root access: the access points set
# the owner of every file.

data "aws_iam_policy_document" "efs_private" {
  statement {
    sid       = "ControlPlaneNodesMount"
    actions   = ["elasticfilesystem:ClientMount", "elasticfilesystem:ClientWrite"]
    resources = [aws_efs_file_system.private.arn]

    principals {
      type        = "AWS"
      identifiers = var.control_plane_node_role_arns
    }

    condition {
      test     = "Bool"
      variable = "elasticfilesystem:AccessedViaMountTarget"
      values   = ["true"]
    }
  }

  statement {
    sid       = "DenyUnencryptedTransport"
    effect    = "Deny"
    actions   = ["*"]
    resources = [aws_efs_file_system.private.arn]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

data "aws_iam_policy_document" "efs_shared" {
  statement {
    sid       = "NodesMount"
    actions   = ["elasticfilesystem:ClientMount", "elasticfilesystem:ClientWrite"]
    resources = [aws_efs_file_system.shared.arn]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "elasticfilesystem:AccessedViaMountTarget"
      values   = ["true"]
    }
  }

  statement {
    sid       = "DenyUnencryptedTransport"
    effect    = "Deny"
    actions   = ["*"]
    resources = [aws_efs_file_system.shared.arn]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_efs_file_system_policy" "private" {
  file_system_id = aws_efs_file_system.private.id
  policy         = data.aws_iam_policy_document.efs_private.json
}

resource "aws_efs_file_system_policy" "shared" {
  file_system_id = aws_efs_file_system.shared.id
  policy         = data.aws_iam_policy_document.efs_shared.json
}

# ----------------------------------------------------------------------
# Mount targets and NFS access
# ----------------------------------------------------------------------
#
# Losing NFS access stalls every pod with an EFS volume, and pods that
# cannot unmount block node drains. So a replaced security group gets its
# rules before the old ones go (create_before_destroy on the rules), and
# the mount targets move to it only once those rules exist (depends_on).
#
# vpc_id is the cluster's VPC, which cannot change, so it is ignored after
# creation: when Terraform has to defer reading the cluster (for example
# under a depends_on on this module), an unknown VPC would otherwise
# replace both groups.

resource "aws_security_group" "efs_private" {
  name_prefix = "${local.name}-efs-private-"
  description = "NFS to the Ghost Agent Platform private file system, from control-plane nodes only"
  vpc_id      = local.vpc_id

  tags = merge(local.common_tags, { Name = "${local.name}-efs-private" })

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [vpc_id]
  }
}

resource "aws_vpc_security_group_ingress_rule" "efs_private" {
  count = length(var.control_plane_node_security_group_ids)

  security_group_id            = aws_security_group.efs_private.id
  referenced_security_group_id = var.control_plane_node_security_group_ids[count.index]
  ip_protocol                  = "tcp"
  from_port                    = 2049
  to_port                      = 2049
  description                  = "NFS from control-plane nodes"

  tags = local.common_tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "efs_shared" {
  name_prefix = "${local.name}-efs-shared-"
  description = "NFS to the Ghost Agent Platform shared file system, from platform nodes"
  vpc_id      = local.vpc_id

  tags = merge(local.common_tags, { Name = "${local.name}-efs-shared" })

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [vpc_id]
  }
}

resource "aws_vpc_security_group_ingress_rule" "efs_shared" {
  count = length(var.node_security_group_ids)

  security_group_id            = aws_security_group.efs_shared.id
  referenced_security_group_id = var.node_security_group_ids[count.index]
  ip_protocol                  = "tcp"
  from_port                    = 2049
  to_port                      = 2049
  description                  = "NFS from platform nodes"

  tags = local.common_tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_efs_mount_target" "private" {
  count = length(var.subnet_ids)

  file_system_id  = aws_efs_file_system.private.id
  subnet_id       = var.subnet_ids[count.index]
  security_groups = [aws_security_group.efs_private.id]

  depends_on = [aws_vpc_security_group_ingress_rule.efs_private]
}

resource "aws_efs_mount_target" "shared" {
  count = length(var.subnet_ids)

  file_system_id  = aws_efs_file_system.shared.id
  subnet_id       = var.subnet_ids[count.index]
  security_groups = [aws_security_group.efs_shared.id]

  depends_on = [aws_vpc_security_group_ingress_rule.efs_shared]
}

# ----------------------------------------------------------------------
# Storage classes
# ----------------------------------------------------------------------
#
# Retain keeps the data behind a volume whose claim is deleted, for
# example by deleting the namespace.

resource "kubernetes_storage_class_v1" "efs_private" {
  metadata {
    name = "${local.name}-efs-private"
  }

  storage_provisioner = "efs.csi.aws.com"
  reclaim_policy      = "Retain"
  volume_binding_mode = "Immediate"
  # Mount with the node's IAM identity, which the file system policy
  # requires; TLS is the driver's default, stated for clarity.
  mount_options = ["tls", "iam"]

  parameters = {
    provisioningMode = "efs-ap"
    fileSystemId     = aws_efs_file_system.private.id
    uid              = "65532"
    gid              = "65532"
    directoryPerms   = "700"
    basePath         = "/exo"
  }
}

resource "kubernetes_storage_class_v1" "efs_shared" {
  metadata {
    name = "${local.name}-efs-shared"
  }

  storage_provisioner = "efs.csi.aws.com"
  reclaim_policy      = "Retain"
  volume_binding_mode = "Immediate"

  parameters = {
    provisioningMode = "efs-ap"
    fileSystemId     = aws_efs_file_system.shared.id
    uid              = "65532"
    gid              = "65532"
    directoryPerms   = "700"
    basePath         = "/exo"
  }
}

# MongoDB's volume: gp3 EBS in the availability zone of the node the
# database first schedules on.
resource "kubernetes_storage_class_v1" "database" {
  metadata {
    name = "${local.name}-gp3"
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Retain"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type      = "gp3"
    encrypted = "true"
    # How the optional snapshot policy (snapshots.tf) finds this
    # installation's database volume.
    tagSpecification_1 = "exo:snapshot-group=${local.name}"
  }
}
