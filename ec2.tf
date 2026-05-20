# ----------------------------------------------------------------------
# EC2 instance + EBS data volume + cloud-init user_data
# ----------------------------------------------------------------------

resource "aws_instance" "vm" {
  ami                  = local.ami_id
  instance_type        = var.instance_type
  subnet_id            = var.subnet_id
  iam_instance_profile = aws_iam_instance_profile.vm.name
  key_name             = var.ssh_key_name != "" ? var.ssh_key_name : null

  vpc_security_group_ids = [aws_security_group.vm.id]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size = var.root_volume_size_gb
    volume_type = "gp3"
    encrypted   = true
  }

  # Cloud-init bootstrap script. Receives everything it needs to
  # render configs and bring up the stack. Secret VALUES are NOT
  # passed in — only ARNs; cloud-init fetches values at boot via
  # the instance role.
  #
  # gzip+base64 because the rendered script (with the embedded
  # compose YAML, Caddyfile, and two TOML configs) exceeds the
  # 16 KB raw user_data limit. cloud-init detects the gzip magic
  # bytes and decompresses automatically before execution.
  user_data_base64 = base64gzip(templatefile("${path.module}/files/user_data.sh.tpl", {
    aws_region                   = local.aws_region
    image_registry               = var.image_registry
    image_registry_region        = local.ghost_region
    image_registry_account_id    = local.ghost_account_id
    image_tag                    = var.image_tag
    bringup_domain               = local.bringup_domain
    seed_admin_email             = var.seed_admin_email
    worker_replicas              = var.worker_replicas
    image_signing_identity_regex = var.image_signing_identity_regex
    image_signing_oidc_issuer    = var.image_signing_oidc_issuer

    secret_arn_jwt            = aws_secretsmanager_secret.jwt.arn
    secret_arn_encryption_key = aws_secretsmanager_secret.encryption_key.arn
    secret_arn_seed_password  = aws_secretsmanager_secret.seed_admin_password.arn
    secret_arn_slack          = aws_secretsmanager_secret.slack.arn

    # On-VM static artifacts. Cloud-init writes these to /opt/exo/.
    # config.toml is the only template rendered at boot time (after
    # secrets are fetched); the rest are inert.
    docker_compose_yml = file("${path.module}/files/docker-compose.prod.yml")
    caddyfile = templatefile("${path.module}/files/Caddyfile.tpl", {
      domain      = local.bringup_domain
      admin_email = var.seed_admin_email
    })
    config_toml_template = file("${path.module}/files/config.toml.tpl")
    config_proxy_toml    = file("${path.module}/files/config.proxy.toml.tpl")
  }))

  lifecycle {
    ignore_changes = [
      # AMI changes shouldn't recycle a long-lived production VM
      # automatically. Replace explicitly by setting var.ami_id and
      # tainting the instance.
      ami,
      # Same logic for user_data: cosmetic edits to the cloud-init
      # script shouldn't trigger reprovisioning. Force a recycle by
      # tainting when the bootstrap really needs to re-run.
      user_data_base64,
    ]
  }

  tags = merge(local.common_tags, { Name = local.name })
}

# ----------------------------------------------------------------------
# Data EBS volume — separate from the root volume so the survival-
# critical state (MongoDB, TLS certs, runner identities, Caddy LE
# certs, secrets cache) persists across instance replacement.
# ----------------------------------------------------------------------

resource "aws_ebs_volume" "data" {
  availability_zone = local.az
  size              = var.data_volume_size_gb
  type              = "gp3"
  encrypted         = true

  tags = merge(local.common_tags, { Name = "${local.name}-data" })

  lifecycle {
    # Extra guard against accidental `terraform destroy`. Removing this
    # volume orphans the application's most critical state — the MITM
    # CA private key (encrypts every stored credential) and the service
    # CA (trust root for every runner identity). Re-enable destruction
    # by removing this line temporarily.
    prevent_destroy = true
  }
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.vm.id
}
