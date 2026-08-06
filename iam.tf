# ----------------------------------------------------------------------
# Instance role + instance profile
# ----------------------------------------------------------------------
#
# Permissions granted to the EC2 instance:
#   - ECR pull on Ghost's published image repos (cross-account, scoped
#     to just the service images this deployment uses).
#   - Secrets Manager read on the secrets this module creates.
#   - SSM managed-instance core for Session Manager access (alternative
#     to SSH-key-pair auth; works without exposing port 22 at all).

resource "aws_iam_role" "vm" {
  name = "${local.name}-vm"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

# SSM Session Manager + SSM-managed-instance basics. Enables
# `aws ssm start-session --target <instance-id>` as an alternative
# to SSH key-pair auth.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.vm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Inline policy: ECR pull (cross-account to Ghost's registry) +
# Secrets Manager read on this module's secrets only.
resource "aws_iam_role_policy" "vm_runtime" {
  name = "ghost-agent-runtime"
  role = aws_iam_role.vm.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Sid      = "EcrAuthToken"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "EcrPullPlatformImages"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          # DescribeImages lets the updater enumerate release tags for
          # the UI's "Check for updates" button — the docker daemon
          # doesn't need it for image pulls.
          "ecr:DescribeImages",
        ]
        Resource = local.ghost_ecr_repo_arns
      },
      {
        Sid    = "SecretsManagerRead"
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue"]
        Resource = [
          aws_secretsmanager_secret.encryption_key.arn,
          aws_secretsmanager_secret.claim_token.arn,
        ]
      },
      ],
      # Opt-in: lets the gateway send email through the SES v2 API as
      # this instance role, so the in-product Email settings can use
      # "Amazon SES (instance IAM role)" with no stored SMTP password.
      # Off by default — deployments not using SES get no SES grant.
      var.enable_ses_email ? [
        {
          Sid    = "SesSendEmail"
          Effect = "Allow"
          Action = ["ses:SendEmail"]
          # Scope to specific SES identity ARNs when provided (least
          # privilege); otherwise any identity verified in the account.
          Resource = length(var.ses_identity_arns) > 0 ? var.ses_identity_arns : ["*"]
        },
      ] : [],
    )
  })
}

resource "aws_iam_instance_profile" "vm" {
  name = "${local.name}-vm"
  role = aws_iam_role.vm.name
}
