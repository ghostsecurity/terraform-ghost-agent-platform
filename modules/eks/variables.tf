# ----------------------------------------------------------------------
# Required inputs
# ----------------------------------------------------------------------

variable "cluster_name" {
  description = "Name of the existing EKS cluster to install into. The cluster must meet the prerequisites in this module's README (network policy enforcement, EKS Pod Identity, the EBS and EFS CSI drivers, and the AWS Load Balancer Controller)."
  type        = string
}

variable "exo_version" {
  description = "Release to install, for example \"v1.2.3\". Selects the Helm chart version (the tag without its \"v\") and, through it, the image tag. Change it to upgrade."
  type        = string

  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.-]+)?$", var.exo_version))
    error_message = "exo_version must be a release tag like v1.2.3 or v1.2.3-rc1."
  }
}

variable "domain_name" {
  description = "Public hostname for the deployment, for example \"ghost.example.com\". Used as the load balancer's host rule, the certificate's name, and the address the platform puts in links, OAuth redirects, and webhook URLs."
  type        = string
}

variable "subnet_ids" {
  description = "Subnets for the EFS mount targets: the private subnets the cluster's nodes run in, one per availability zone."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) > 0
    error_message = "subnet_ids must list at least one subnet."
  }
}

variable "node_security_group_ids" {
  description = "Security groups of every node that runs platform pods, workers included. These nodes may mount the shared file system (artifacts, public certificates, runner identities)."
  type        = list(string)

  validation {
    condition     = length(var.node_security_group_ids) > 0
    error_message = "node_security_group_ids must list at least one security group."
  }
}

variable "control_plane_node_security_group_ids" {
  description = "Security groups attached only to the nodes that run the gateway, credential proxy, and updater. Only these nodes may mount the private file system that holds the platform's keys, so worker nodes must not carry any of them."
  type        = list(string)

  validation {
    condition     = length(var.control_plane_node_security_group_ids) > 0
    error_message = "control_plane_node_security_group_ids must list at least one security group."
  }
}

variable "control_plane_node_role_arns" {
  description = "IAM roles of the nodes that run the gateway, credential proxy, and updater (the nodes carrying control_plane_node_security_group_ids). The private file system's policy lets only these roles mount it, and the module's storage class mounts it with the node's IAM identity."
  type        = list(string)

  validation {
    condition     = length(var.control_plane_node_role_arns) > 0 && alltrue([for a in var.control_plane_node_role_arns : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:role/", a))])
    error_message = "control_plane_node_role_arns must list at least one IAM role ARN."
  }
}

# ----------------------------------------------------------------------
# Optional: image source
# ----------------------------------------------------------------------

variable "image_registry" {
  description = "Registry hosting the platform's Helm chart and images. Defaults to Ghost Security's ECR registry; override only for a mirror. The AWS account running the cluster must be granted cross-account pull access by Ghost, and the Helm provider must be logged in to this registry (see the README)."
  type        = string
  default     = "052783882429.dkr.ecr.us-east-1.amazonaws.com"

  validation {
    condition     = can(regex("^[0-9]{12}\\.dkr\\.ecr\\.[a-z0-9-]+\\.amazonaws\\.com$", var.image_registry))
    error_message = "image_registry must be an ECR registry URL of the form <12-digit-account>.dkr.ecr.<region>.amazonaws.com."
  }
}

# ----------------------------------------------------------------------
# Optional: load balancer, certificate, and DNS
# ----------------------------------------------------------------------

variable "acm_certificate_arn" {
  description = "ARN of an existing ACM certificate for domain_name, in the cluster's region. Leave empty to have the module request one, which needs route53_zone_id for DNS validation."
  type        = string
  default     = ""
}

variable "route53_zone_id" {
  description = "Route 53 hosted zone for domain_name. When set, the module creates the A record pointing at the load balancer and, unless acm_certificate_arn is set, validates a new ACM certificate in this zone. Leave empty to manage DNS elsewhere (point domain_name at the load_balancer_hostname output)."
  type        = string
  default     = ""
}

variable "ingress_cidrs" {
  description = "CIDR blocks allowed to reach the load balancer on ports 80 and 443. Narrow this to corp or VPN egress ranges to restrict who can reach the deployment."
  type        = list(string)
  default     = ["0.0.0.0/0"]

  validation {
    condition     = length(var.ingress_cidrs) > 0 && alltrue([for c in var.ingress_cidrs : can(cidrnetmask(c))])
    error_message = "ingress_cidrs must list at least one valid IPv4 CIDR block."
  }
}

variable "internal_load_balancer" {
  description = "Create an internal load balancer, reachable only from inside the VPC and networks connected to it, instead of an internet-facing one."
  type        = bool
  default     = false
}

variable "ingress_annotations" {
  description = "Additional annotations for the Ingress, merged over the module's AWS Load Balancer Controller annotations, for example to attach a WAF ACL or join an existing load balancer group."
  type        = map(string)
  default     = {}
}

# ----------------------------------------------------------------------
# Optional: workers and node placement
# ----------------------------------------------------------------------

variable "worker_pools" {
  description = "Worker pools. Each runs its own Deployment of workers, and replicas is the number of runs the pool handles at once. An empty image runs the published worker image; set image to a worker image you built (System > Worker add-ons > Create worker image in the UI) and list the tools it adds in capabilities."
  type = list(object({
    name         = string
    replicas     = number
    image        = optional(string, "")
    capabilities = optional(list(string), [])
  }))
  default = [{ name = "default", replicas = 2 }]

  validation {
    condition     = length(var.worker_pools) > 0 && alltrue([for p in var.worker_pools : can(regex("^[a-z0-9][a-z0-9-]{0,31}$", p.name)) && p.replicas >= 0])
    error_message = "worker_pools needs at least one pool; names are lowercase letters, digits, and hyphens (at most 32), and replicas cannot be negative."
  }
}

variable "worker_node_selector" {
  description = "Node labels that worker pods must match, for example the labels of a dedicated worker node group."
  type        = map(string)
  default     = {}
}

variable "worker_tolerations" {
  description = "Tolerations for worker pods, matching the taints of a dedicated worker node group."
  type = list(object({
    key      = string
    operator = optional(string, "Equal")
    value    = optional(string)
    effect   = optional(string)
  }))
  default = []
}

variable "control_plane_node_selector" {
  description = "Node labels that the gateway, credential proxy, updater, UI, and database must match. Point it at the nodes that carry control_plane_node_security_group_ids: the gateway, credential proxy, and updater cannot mount their file system anywhere else."
  type        = map(string)
  default     = {}
}

variable "control_plane_tolerations" {
  description = "Tolerations for the gateway, credential proxy, updater, UI, and database."
  type = list(object({
    key      = string
    operator = optional(string, "Equal")
    value    = optional(string)
    effect   = optional(string)
  }))
  default = []
}

# ----------------------------------------------------------------------
# Optional: email
# ----------------------------------------------------------------------

variable "enable_ses_email" {
  description = "Send transactional email (password resets, invites) through Amazon SES with an AWS identity for the gateway, with no stored password. Requires email_from and a verified SES identity, managed outside this module. For SMTP or Resend instead, pass the chart's email values through extra_helm_values."
  type        = bool
  default     = false
}

variable "email_from" {
  description = "From address for platform email, for example \"noreply@ghost.example.com\". Required with enable_ses_email."
  type        = string
  default     = ""
}

variable "ses_region" {
  description = "Region of the verified SES identity. Empty uses the cluster's region."
  type        = string
  default     = ""
}

variable "ses_identity_arns" {
  description = "Restrict the gateway's ses:SendEmail grant to these SES identity ARNs (add the configuration-set ARN too if the account applies a default configuration set). Empty allows any verified identity in the account. Only applies with enable_ses_email."
  type        = list(string)
  default     = []
}

# ----------------------------------------------------------------------
# Optional: Ghost support access
# ----------------------------------------------------------------------

variable "ghost_support_access_enabled" {
  description = "When true (the default), this module publishes a `<prefix>-ssm-support` IAM role that Ghost Security can assume from its own AWS account for support. Through AWS Systems Manager Session Manager on the cluster's nodes, the role can forward a port to the platform's UI and to the cluster's API endpoint, and nothing else: no shell and no inbound ports. In Kubernetes it can read the platform's pods, logs, events, and workloads, and delete pods to restart them, but cannot read Secrets or exec into pods. Nodes are reachable only once their role allows Session Manager (see the README). Set to false to remove the role and all of its access."
  type        = bool
  default     = true
}

# ----------------------------------------------------------------------
# Optional: storage
# ----------------------------------------------------------------------

variable "efs_backup" {
  description = "Turn on AWS Backup's automatic daily backups for both EFS file systems (the platform's keys and certificates, and the shared artifacts)."
  type        = bool
  default     = true
}

variable "enable_database_snapshots" {
  description = "Create a Data Lifecycle Manager (DLM) policy that takes daily EBS snapshots of the bundled MongoDB's volume for disaster recovery, plus the DLM service role it runs as. Off by default."
  type        = bool
  default     = false
}

variable "database_snapshot_retention_days" {
  description = "Number of daily database snapshots to retain when enable_database_snapshots is true."
  type        = number
  default     = 30

  validation {
    condition     = var.database_snapshot_retention_days >= 1
    error_message = "database_snapshot_retention_days must be at least 1."
  }
}

# ----------------------------------------------------------------------
# Optional: release
# ----------------------------------------------------------------------

variable "service_ip_offset" {
  description = "Where in the cluster's Service range the platform's three fixed Service addresses start: the credential proxy takes this offset, the gateway the next, and the UI the one after (12 gives .12, .13, and .14 of a /16 range). Each installation in a cluster needs its own three free addresses. Set it at install: a Service's address cannot change afterwards."
  type        = number
  default     = 12

  validation {
    condition     = var.service_ip_offset >= 11 && var.service_ip_offset <= 250 && floor(var.service_ip_offset) == var.service_ip_offset
    error_message = "service_ip_offset must be a whole number from 11 to 250, clear of the API server (.1) and cluster DNS (.10) addresses."
  }
}

variable "manage_release" {
  description = "Install the platform's Helm release, its Ingress, and the DNS record (the default). Set false to install the release yourself, with Helm or a GitOps tool: the module then creates everything else (namespace, secrets, storage, AWS identities, the certificate, and Ghost support access) and outputs the Helm values to install with (helm_values)."
  type        = bool
  default     = true
}

variable "namespace" {
  description = "Namespace to install into. The module creates it, labeled for the restricted Pod Security Standard. One installation per namespace."
  type        = string
  default     = "exo"
}

variable "release_name" {
  description = "Helm release name."
  type        = string
  default     = "exo"
}

variable "extra_helm_values" {
  description = "Additional Helm values as YAML documents, applied after the module's own. See `helm show values` for the chart's keys, for example to set resources, the database volume size, or SMTP email."
  type        = list(string)
  default     = []
}

# ----------------------------------------------------------------------
# Optional: meta
# ----------------------------------------------------------------------

variable "name_prefix" {
  description = "Prefix for AWS resource names (IAM roles, EFS file systems, security groups, the Secrets Manager secret) and the module's storage classes. Change it to install more than once in the same account or cluster; a second installation in a cluster also needs its own namespace and service_ip_offset."
  type        = string
  default     = "ghost-agent-eks"
}

variable "tags" {
  description = "Additional tags applied to every AWS resource this module creates, the load balancer included."
  type        = map(string)
  default     = {}
}
