# ----------------------------------------------------------------------
# Optional: scheduled EBS snapshots of the data volume (disaster
# recovery), gated by var.enable_data_volume_snapshots.
#
# Uses Data Lifecycle Manager (DLM): a daily snapshot of the data volume
# retaining var.data_volume_snapshot_retention_days, plus the service
# role DLM runs as. The policy targets the volume by its
# `exo:snapshot-group` tag (added in ec2.tf under the same flag), so it
# only snapshots this deployment's volume. Snapshots are crash-
# consistent; see the README "Data persistence and recovery" for the
# quiesced-snapshot and restore steps.
# ----------------------------------------------------------------------

data "aws_iam_policy_document" "dlm_assume" {
  count = var.enable_data_volume_snapshots ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["dlm.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "dlm" {
  count              = var.enable_data_volume_snapshots ? 1 : 0
  name               = "${local.name}-dlm"
  assume_role_policy = data.aws_iam_policy_document.dlm_assume[0].json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "dlm" {
  count      = var.enable_data_volume_snapshots ? 1 : 0
  role       = aws_iam_role.dlm[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "data" {
  count              = var.enable_data_volume_snapshots ? 1 : 0
  description        = "${local.name} data volume daily snapshots"
  execution_role_arn = aws_iam_role.dlm[0].arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]

    target_tags = {
      "exo:snapshot-group" = local.name
    }

    schedule {
      name = "daily-${var.data_volume_snapshot_retention_days}d-retention"

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["14:00"] # TODO: revert to 03:00
      }

      retain_rule {
        count = var.data_volume_snapshot_retention_days
      }

      copy_tags = true
    }
  }

  tags = local.common_tags
}
