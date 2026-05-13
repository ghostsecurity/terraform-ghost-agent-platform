# ----------------------------------------------------------------------
# Security group + Elastic IP + (optional) Route 53 record
# ----------------------------------------------------------------------

resource "aws_security_group" "vm" {
  name        = "${local.name}-vm"
  description = "Ingress + egress for the Ghost Agent Platform VM"
  vpc_id      = local.vpc_id
  tags        = local.common_tags
}

# SSH — admin CIDR only.
resource "aws_vpc_security_group_ingress_rule" "ssh" {
  security_group_id = aws_security_group.vm.id
  cidr_ipv4         = var.admin_cidr
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  description       = "SSH from admin CIDR"
  tags              = local.common_tags
}

# HTTP — needed for Let's Encrypt HTTP-01 challenge + HTTPS redirect.
# Open to var.public_ingress_cidrs (default: world). See variables.tf
# for the rationale on not locking down further.
resource "aws_vpc_security_group_ingress_rule" "http" {
  for_each = toset(var.public_ingress_cidrs)

  security_group_id = aws_security_group.vm.id
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  description       = "HTTP for ACME HTTP-01 challenge + redirect"
  tags              = local.common_tags
}

# HTTPS — public-facing UI + /api.
resource "aws_vpc_security_group_ingress_rule" "https" {
  for_each = toset(var.public_ingress_cidrs)

  security_group_id = aws_security_group.vm.id
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "HTTPS for UI + /api"
  tags              = local.common_tags
}

# Egress — unrestricted. The VM dials:
#   - ECR for image pulls
#   - Let's Encrypt + Sigstore for cert issuance / cosign verify
#   - Vendor APIs via the credential-proxy on outbound runtime traffic
resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.vm.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "All egress"
  tags              = local.common_tags
}

# ----------------------------------------------------------------------
# Elastic IP — stable public address. Survives instance replacement.
# Required for:
#   - a predictable bring-up URL (especially in the nip.io fallback)
#   - Let's Encrypt cert persistence across reboots (the cert SAN
#     must match a stable IP/host)
# ----------------------------------------------------------------------

resource "aws_eip" "this" {
  domain = "vpc"
  tags   = merge(local.common_tags, { Name = "${local.name}-eip" })
}

resource "aws_eip_association" "this" {
  instance_id   = aws_instance.vm.id
  allocation_id = aws_eip.this.id
}

# ----------------------------------------------------------------------
# Optional: Route 53 A record for a custom domain
# ----------------------------------------------------------------------
#
# Created only when BOTH domain_name and route53_zone_id are set. When
# DNS is managed outside this module, the A record is created out of
# band; var.domain_name still flows into the Caddyfile and TLS issuance.

resource "aws_route53_record" "this" {
  count = var.domain_name != "" && var.route53_zone_id != "" ? 1 : 0

  zone_id = var.route53_zone_id
  name    = var.domain_name
  type    = "A"
  ttl     = 300
  records = [aws_eip.this.public_ip]
}
