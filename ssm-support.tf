# ----------------------------------------------------------------------
# Ghost support access (cross-account SSM). Optional, on by default.
# ----------------------------------------------------------------------
#
# Publishes a role that Ghost Security assumes to open an AWS Systems
# Manager Session Manager shell on the VM for support. It grants only
# ssm:StartSession on this instance plus management of the caller's own
# sessions: no SSH key, no inbound ports, no access to any other
# resource. Set var.ghost_support_access_enabled = false to remove it.

locals {
  ghost_support_enabled = var.ghost_support_access_enabled

  # The role Ghost Security assumes. It lives in the account that owns
  # image_registry, so the account is taken from there.
  ghost_support_principal_arn = "arn:aws:iam::${local.ghost_account_id}:role/exo-ssm-support"
}

resource "aws_iam_role" "ssm_support" {
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

resource "aws_iam_role_policy" "ssm_support" {
  count = local.ghost_support_enabled ? 1 : 0

  name = "ssm-start-session"
  role = aws_iam_role.ssm_support[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Open a Session Manager shell on this instance, or forward a port
        # on it (the port-forward document lets an operator reach the UI
        # without any inbound ports). StartSession is authorized against
        # the instance and each session document, so all are listed;
        # SessionDocumentAccessCheck stops the instance scope from being
        # bypassed with another document.
        Sid    = "StartSessionOnInstance"
        Effect = "Allow"
        Action = "ssm:StartSession"
        Resource = [
          "arn:aws:ec2:${local.aws_region}:${local.aws_account_id}:instance/${aws_instance.vm.id}",
          "arn:aws:ssm:${local.aws_region}:${local.aws_account_id}:document/SSM-SessionManagerRunShell",
          # AWS-owned public documents carry no account ID in their ARN,
          # unlike the account-scoped SSM-SessionManagerRunShell default.
          "arn:aws:ssm:${local.aws_region}::document/AWS-StartPortForwardingSession",
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
        Resource = "arn:aws:ssm:${local.aws_region}:${local.aws_account_id}:session/$${aws:userid}-*"
      },
    ]
  })
}
