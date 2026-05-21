# Basic example

End-to-end deployment with a fresh network. Provisions a new VPC + public subnet + internet gateway, then deploys the Ghost Agent Platform module into them.

Intended as a starting point — copy this directory and adapt for your environment. For production, pin the module `source` to a released tag (`source = "github.com/ghostsecurity/terraform-ghost-agent-platform?ref=<latest release tag, e.g. v0.1.2>"`) and swap the example's VPC/subnet for the network the rest of your account uses.

## Prerequisites

- AWS credentials configured for the target account (e.g. `AWS_PROFILE` or `aws configure`).
- Cross-account ECR pull access granted by Ghost Security for this account — see the [Onboarding](../../README.md#onboarding) section of the parent README.
- The `10.0.0.0/16` CIDR block must be unused in the target region (this example creates a VPC with that range).
- Terraform >= 1.5.

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with the values Ghost provided + your admin IP + email.
terraform init
terraform plan
terraform apply
```

`terraform apply` returns once the EC2 is created; on-VM bootstrap takes another ~3-5 minutes. See [After apply](../../README.md#after-apply) in the parent README for how to watch the bootstrap log, retrieve the initial admin password, and verify the deployment.
