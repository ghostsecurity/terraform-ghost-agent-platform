# ----------------------------------------------------------------------
# AWS identities for platform pods (EKS Pod Identity)
# ----------------------------------------------------------------------
#
#   - updater: reads the release tags of Ghost's exo-stack repository to
#     report new versions in the UI.
#   - gateway (only with enable_ses_email): sends email through SES.
# No other platform pod gets an AWS identity.

data "aws_iam_policy_document" "pod_identity_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "updater" {
  name               = "${local.name}-updater"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json

  tags = local.common_tags
}

resource "aws_iam_role_policy" "updater" {
  name = "release-check"
  role = aws_iam_role.updater.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "DescribeReleases"
      Effect   = "Allow"
      Action   = ["ecr:DescribeImages"]
      Resource = "arn:aws:ecr:${local.ghost_region}:${local.ghost_account_id}:repository/exo-stack"
    }]
  })
}

resource "aws_eks_pod_identity_association" "updater" {
  cluster_name    = var.cluster_name
  namespace       = var.namespace
  service_account = "exo-updater"
  role_arn        = aws_iam_role.updater.arn

  tags = local.common_tags
}

resource "aws_iam_role" "gateway" {
  count = var.enable_ses_email ? 1 : 0

  name               = "${local.name}-gateway"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json

  tags = local.common_tags
}

resource "aws_iam_role_policy" "gateway_ses" {
  count = var.enable_ses_email ? 1 : 0

  name = "ses-send"
  role = aws_iam_role.gateway[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "SesSendEmail"
      Effect = "Allow"
      Action = ["ses:SendEmail"]
      # Scope to specific SES identity ARNs when provided; otherwise any
      # identity verified in the account.
      Resource = length(var.ses_identity_arns) > 0 ? var.ses_identity_arns : ["*"]
    }]
  })
}

resource "aws_eks_pod_identity_association" "gateway" {
  count = var.enable_ses_email ? 1 : 0

  cluster_name    = var.cluster_name
  namespace       = var.namespace
  service_account = "exo-gateway"
  role_arn        = aws_iam_role.gateway[0].arn

  tags = local.common_tags
}
