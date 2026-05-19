# ----------------------------------------------------------------------
# Account / region / subnet data
# ----------------------------------------------------------------------

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Subnet placement. VPC + AZ are derived from it; no separate vpc_id
# input needed.
data "aws_subnet" "selected" {
  id = var.subnet_id
}

# Latest Amazon Linux 2023 AMI. Only consulted when var.ami_id is empty
# (the default) — count=0 when overridden to avoid an unused API call.
data "aws_ami" "al2023" {
  count       = var.ami_id == "" ? 1 : 0
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

# ----------------------------------------------------------------------
# Locals
# ----------------------------------------------------------------------

locals {
  aws_region     = data.aws_region.current.region
  aws_account_id = data.aws_caller_identity.current.account_id

  # Network placement derived from the customer-provided subnet.
  vpc_id = data.aws_subnet.selected.vpc_id
  az     = data.aws_subnet.selected.availability_zone

  # AMI: override if provided, otherwise latest AL2023.
  ami_id = var.ami_id != "" ? var.ami_id : data.aws_ami.al2023[0].id

  # Parse Ghost's account ID + region out of the registry URL. Registry
  # format is `<account>.dkr.ecr.<region>.amazonaws.com` (validated in
  # variables.tf).
  registry_parts   = split(".", var.image_registry)
  ghost_account_id = local.registry_parts[0]
  ghost_region     = local.registry_parts[3]

  # ECR repo ARNs for the five images the EC2 needs to pull. Used by
  # the IAM policy in iam.tf.
  ghost_ecr_repo_arns = [
    for img in ["exo-server", "exo-credential-proxy", "exo-worker", "exo-ui", "exo-updater"] :
    "arn:aws:ecr:${local.ghost_region}:${local.ghost_account_id}:repository/${img}"
  ]

  # Bring-up hostname. Real FQDN when var.domain_name is set; otherwise
  # a nip.io subdomain encoding the EIP — resolves automatically, no DNS
  # setup needed. Both paths give Caddy a public-DNS-resolvable name for
  # the Let's Encrypt HTTP-01 challenge.
  bringup_domain = (
    var.domain_name != ""
    ? var.domain_name
    : "${replace(aws_eip.this.public_ip, ".", "-")}.nip.io"
  )

  name = var.name_prefix

  common_tags = merge(
    {
      ManagedBy = "terraform-ghost-agent-platform"
      Component = "ghost-agent-platform"
    },
    var.tags,
  )
}
