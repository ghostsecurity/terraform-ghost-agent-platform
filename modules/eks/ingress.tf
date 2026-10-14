# ----------------------------------------------------------------------
# Certificate
# ----------------------------------------------------------------------
#
# An existing certificate (acm_certificate_arn), or a new one validated
# through DNS in route53_zone_id.

locals {
  create_certificate = var.acm_certificate_arn == "" && var.route53_zone_id != ""
  certificate_arn    = var.acm_certificate_arn != "" ? var.acm_certificate_arn : try(aws_acm_certificate_validation.this[0].certificate_arn, "")
}

resource "aws_acm_certificate" "this" {
  count = local.create_certificate ? 1 : 0

  domain_name       = var.domain_name
  validation_method = "DNS"

  tags = local.common_tags

  lifecycle {
    create_before_destroy = true
  }
}

# The certificate names domain_name alone, so it has exactly one
# validation record.
resource "aws_route53_record" "certificate_validation" {
  count = local.create_certificate ? 1 : 0

  zone_id         = var.route53_zone_id
  name            = one(aws_acm_certificate.this[0].domain_validation_options).resource_record_name
  type            = one(aws_acm_certificate.this[0].domain_validation_options).resource_record_type
  ttl             = 60
  records         = [one(aws_acm_certificate.this[0].domain_validation_options).resource_record_value]
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "this" {
  count = local.create_certificate ? 1 : 0

  certificate_arn         = aws_acm_certificate.this[0].arn
  validation_record_fqdns = aws_route53_record.certificate_validation[*].fqdn
}

# ----------------------------------------------------------------------
# Ingress (AWS Load Balancer Controller)
# ----------------------------------------------------------------------
#
# An ALB terminating TLS in front of the UI service, which also proxies
# the API. The idle timeout keeps the UI's live-update WebSocket open.
# Only with manage_release: the controller builds the load balancer from
# the UI Service, which the release creates.

resource "kubernetes_ingress_v1" "this" {
  count = var.manage_release ? 1 : 0

  metadata {
    name      = "exo"
    namespace = kubernetes_namespace_v1.this.metadata[0].name

    annotations = merge(
      {
        "alb.ingress.kubernetes.io/scheme"                   = var.internal_load_balancer ? "internal" : "internet-facing"
        "alb.ingress.kubernetes.io/target-type"              = "ip"
        "alb.ingress.kubernetes.io/listen-ports"             = jsonencode([{ HTTP = 80 }, { HTTPS = 443 }])
        "alb.ingress.kubernetes.io/ssl-redirect"             = "443"
        "alb.ingress.kubernetes.io/certificate-arn"          = local.certificate_arn
        "alb.ingress.kubernetes.io/ssl-policy"               = "ELBSecurityPolicy-TLS13-1-2-2021-06"
        "alb.ingress.kubernetes.io/inbound-cidrs"            = join(",", var.ingress_cidrs)
        "alb.ingress.kubernetes.io/load-balancer-attributes" = "idle_timeout.timeout_seconds=3600"
        "alb.ingress.kubernetes.io/tags"                     = join(",", [for k, v in local.common_tags : "${k}=${v}"])
      },
      var.ingress_annotations,
    )
  }

  spec {
    ingress_class_name = "alb"

    rule {
      host = var.domain_name

      http {
        path {
          path      = "/"
          path_type = "Prefix"

          backend {
            service {
              name = "exo-ui"
              port {
                name = "http"
              }
            }
          }
        }
      }
    }
  }

  wait_for_load_balancer = true

  depends_on = [helm_release.this]

  lifecycle {
    precondition {
      condition     = var.acm_certificate_arn != "" || var.route53_zone_id != ""
      error_message = "Set acm_certificate_arn, or route53_zone_id so the module can request a certificate for domain_name."
    }
  }
}

# ----------------------------------------------------------------------
# DNS
# ----------------------------------------------------------------------

data "aws_lb_hosted_zone_id" "alb" {
  load_balancer_type = "application"
}

# Points domain_name at the module's load balancer, so only with
# manage_release. The certificate above is created either way.
resource "aws_route53_record" "this" {
  count = var.manage_release && var.route53_zone_id != "" ? 1 : 0

  zone_id = var.route53_zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = kubernetes_ingress_v1.this[0].status[0].load_balancer[0].ingress[0].hostname
    zone_id                = data.aws_lb_hosted_zone_id.alb.id
    evaluate_target_health = true
  }
}
