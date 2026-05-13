# Basic example: a complete from-scratch deployment.
#
# Provisions a fresh VPC + public subnet + internet gateway and
# deploys the Ghost Agent Platform module into it. Works in any AWS
# account that doesn't already have a resource using the 10.0.0.0/16
# CIDR block.
#
# Intended as a starting point. For production, copy this into a new
# directory, point `source` at a tagged version of the module
# (`source = "github.com/ghostsecurity/terraform-ghost-agent-platform?ref=vX.Y.Z"`),
# and either keep the example network or swap in the VPC + subnet
# that the rest of the account uses.
#
# Usage:
#   cp terraform.tfvars.example terraform.tfvars
#   # ... fill in terraform.tfvars
#   terraform init
#   terraform plan
#   terraform apply

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ----------------------------------------------------------------------
# Network: VPC + public subnet + IGW + default route
# ----------------------------------------------------------------------

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "this" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "ghost-agent" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "ghost-agent" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = { Name = "ghost-agent-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "ghost-agent-public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ----------------------------------------------------------------------
# Ghost Agent Platform
# ----------------------------------------------------------------------

module "ghost_agent" {
  source = "../.."

  image_registry   = var.image_registry
  image_tag        = var.image_tag
  subnet_id        = aws_subnet.public.id
  admin_cidr       = var.admin_cidr
  seed_admin_email = var.seed_admin_email
  ssh_key_name     = var.ssh_key_name
}

# ----------------------------------------------------------------------
# Example inputs (set in terraform.tfvars)
# ----------------------------------------------------------------------

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "image_registry" {
  type = string
}

variable "image_tag" {
  type = string
}

variable "admin_cidr" {
  type = string
}

variable "seed_admin_email" {
  type = string
}

variable "ssh_key_name" {
  type    = string
  default = ""
}

# ----------------------------------------------------------------------
# Outputs — pass through the module's outputs for convenience
# ----------------------------------------------------------------------

output "bringup_url" {
  value = module.ghost_agent.bringup_url
}

output "ssh_command" {
  value = module.ghost_agent.ssh_command
}

output "ssm_session_command" {
  value = module.ghost_agent.ssm_session_command
}

output "secret_arns" {
  value = module.ghost_agent.secret_arns
}

output "elastic_ip" {
  value = module.ghost_agent.elastic_ip
}

output "instance_id" {
  value = module.ghost_agent.instance_id
}

output "vpc_id" {
  value = aws_vpc.this.id
}

output "subnet_id" {
  value = aws_subnet.public.id
}
