# ----------------------------------------------------------------------
# Required inputs
# ----------------------------------------------------------------------

variable "image_registry" {
  description = "Container registry hosting the Ghost Agent Platform images, e.g. \"012345678901.dkr.ecr.<region, e.g. us-east-1>.amazonaws.com\". Provided by Ghost Security during onboarding. The AWS account running this module must be granted cross-account ECR pull access by Ghost before `terraform apply` succeeds."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}\\.dkr\\.ecr\\.[a-z0-9-]+\\.amazonaws\\.com$", var.image_registry))
    error_message = "image_registry must be an ECR registry URL of the form <12-digit-account>.dkr.ecr.<region>.amazonaws.com."
  }
}

variable "image_tag" {
  description = "Image tag to deploy (e.g. \"v1.0.0\"). Must exist in image_registry for every Ghost Agent Platform service image (gateway, credential-proxy, worker, ui, updater)."
  type        = string
}

variable "subnet_id" {
  description = "Subnet to place the EC2 instance in. Must be a public subnet — Let's Encrypt's HTTP-01 challenge needs inbound HTTP from arbitrary internet IPs. The VPC + AZ are inferred from the subnet."
  type        = string
}

variable "admin_cidr" {
  description = "CIDR block allowed SSH (port 22) access to the VM. Gates the security-group rule for port 22 only — it has no effect on AWS Systems Manager Session Manager, which tunnels via the instance's egress to the SSM service and is the default access path when ssh_key_name is empty. Set this tightly (e.g. an office IP /32 or a VPN egress block, never 0.0.0.0/0) as defense-in-depth, even if you don't plan to use SSH."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.admin_cidr))
    error_message = "admin_cidr must be a valid CIDR block."
  }
}

variable "seed_admin_email" {
  description = "Email for the initial admin user seeded into the app at first boot. The password is auto-generated and stored in AWS Secrets Manager (see the Secrets section of the README for retrieval)."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.seed_admin_email))
    error_message = "seed_admin_email must look like a valid email."
  }
}

# ----------------------------------------------------------------------
# Optional: public-facing access
# ----------------------------------------------------------------------

variable "public_ingress_cidrs" {
  description = "Optional. CIDR blocks allowed inbound on ports 80 and 443. Default is the open internet, which fits most deployments (the app is internet-facing). Override only when the VM sits behind a CDN/WAF and ingress should be limited to that origin. Note: scoping port 80 too tightly breaks Let's Encrypt — LE does NOT publish a stable list of validator IPs; HTTP-01 challenges arrive from arbitrary global addresses. The TLS-ALPN-01 alternative (443-only) is workable but less universally supported."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# ----------------------------------------------------------------------
# Optional: custom domain
# ----------------------------------------------------------------------

variable "domain_name" {
  description = "Optional. FQDN for the deployment (e.g. \"agents.example.com\"). If unset, falls back to <dashed-eip>.nip.io which resolves to the EC2's Elastic IP automatically — no DNS setup required, real Let's Encrypt cert via HTTP-01."
  type        = string
  default     = ""
}

variable "route53_zone_id" {
  description = "Optional. Route 53 hosted-zone ID to create an A record in for domain_name. Set only when domain_name is set AND this module should manage the DNS record. Leave empty when the A record is managed elsewhere or when the default nip.io bring-up URL is sufficient."
  type        = string
  default     = ""
}

# ----------------------------------------------------------------------
# Optional: AMI override
# ----------------------------------------------------------------------

variable "ami_id" {
  description = "Optional. AMI ID for the EC2 instance. Leave empty to use the latest Amazon Linux 2023 AMI in the region (the supported default — AL2023 is still the current Amazon Linux LTS line, supported through ~2028). Override to use a hardened image or a different distro — at the operator's own risk: cloud-init in this module assumes an AL2023-style userland (dnf, systemd, ec2-user account)."
  type        = string
  default     = ""
}

# ----------------------------------------------------------------------
# Optional: VM sizing
# ----------------------------------------------------------------------

variable "instance_type" {
  description = "Optional. EC2 instance type. t3.large is the smallest size that comfortably runs the full stack. Changeable post-deploy without data loss: AWS modifies EBS-backed instances in place (stop → modify type → start, ~1-2 min downtime); the data volume + cloud-init artifacts persist and the stack auto-restarts via systemd. Cross-architecture changes (x86 → ARM) require a different AMI and aren't supported by an in-place edit."
  type        = string
  default     = "t3.large"
}

variable "root_volume_size_gb" {
  description = "Optional. Root EBS volume size in GB (OS + Docker image storage). 30 is the AL2023 AMI's snapshot size — EC2 rejects anything smaller. Each in-app upgrade leaves the prior release's images on disk for rollback; a daily prune timer cleans them up after 30 days. The 100 GB default keeps a comfortable buffer between current/previous tags and the prune deadline."
  type        = number
  default     = 100

  validation {
    condition     = var.root_volume_size_gb >= 30
    error_message = "root_volume_size_gb must be at least 30 — the AL2023 AMI's source snapshot is 30 GB and EC2 won't shrink it."
  }
}

variable "data_volume_size_gb" {
  description = "Optional. Data EBS volume size in GB for the on-VM data directory (database state, TLS certs, run artifacts, runner identities, Caddy LE certs). All survival-critical state lives here. Sized for normal operation; oversize for high workflow throughput."
  type        = number
  default     = 100
}

variable "worker_replicas" {
  description = "Optional. Number of worker containers (agent runners) to run on the VM. Defaults to 2. Per-worker CPU/RAM footprint depends on workflow shape; size up var.instance_type before pushing this high. Adjustable post-deploy without `terraform apply` — edit WORKER_REPLICAS in /opt/exo/.env and `docker compose up -d`."
  type        = number
  default     = 2

  validation {
    condition     = var.worker_replicas >= 1
    error_message = "worker_replicas must be at least 1."
  }
}

# ----------------------------------------------------------------------
# Optional: SSH access
# ----------------------------------------------------------------------

variable "ssh_key_name" {
  description = "Optional. Name of an existing EC2 key pair to attach to the instance for SSH access. Leave empty (the default) to skip key-pair attachment entirely — AWS Systems Manager Session Manager is available without a key pair (the instance role grants SSM access and cloud-init installs the SSM agent). When this is empty, var.admin_cidr still controls the SSH security-group rule but has no auth-capable target behind it; set ssh_key_name to a real EC2 key pair name to make SSH usable."
  type        = string
  default     = ""
}

# ----------------------------------------------------------------------
# Optional: Ghost support access (cross-account SSM)
# ----------------------------------------------------------------------

variable "ghost_support_access_enabled" {
  description = "Optional. When true (the default), this module publishes a `<prefix>-ssm-support` IAM role that Ghost Security can assume from its own AWS account to open an AWS Systems Manager Session Manager shell on the VM for support. The role grants only `ssm:StartSession` on this one instance — no SSH key, no inbound ports, no other AWS access. Set to false to remove the role entirely and disable Ghost support access."
  type        = bool
  default     = true
}

# ----------------------------------------------------------------------
# Optional: signature verification policy
# ----------------------------------------------------------------------

variable "image_signing_identity_regex" {
  description = "Optional. Regex matching the cosign certificate identity that signed the released images. Cloud-init uses this with `cosign verify` before pulling images. Default matches the Ghost Security publish workflow on a v* tag — override only if Ghost rotates the workflow path or the regex needs to widen for pre-release tags."
  type        = string
  default     = "^https://github\\.com/ghostsecurity/exo/\\.github/workflows/publish-to-ecr\\.yml@refs/tags/v[0-9]+\\.[0-9]+\\.[0-9]+(-.*)?$"
}

variable "image_signing_oidc_issuer" {
  description = "Optional. OIDC issuer the publish workflow used when signing. Pinned to GitHub Actions by default."
  type        = string
  default     = "https://token.actions.githubusercontent.com"
}

# ----------------------------------------------------------------------
# Optional: meta
# ----------------------------------------------------------------------

variable "name_prefix" {
  description = "Optional. Prefix for resource names (`<prefix>-vm`, `<prefix>-data`, etc.). Useful when running multiple deploys in the same AWS account."
  type        = string
  default     = "ghost-agent"
}

variable "tags" {
  description = "Optional. Additional tags applied to every AWS resource this module creates."
  type        = map(string)
  default     = {}
}
