# EKS example

End-to-end deployment on Amazon EKS with a fresh network and cluster. Provisions a VPC, an EKS cluster with the add-ons the platform needs, a `system` node group for the platform's control plane and a tainted `workers` node group for the agents, and the AWS Load Balancer Controller, then installs the platform with the [EKS module](../../modules/eks/README.md).

Intended as a starting point and test bed. To install into an existing cluster instead, use the module directly and check its [cluster prerequisites](../../modules/eks/README.md#cluster-prerequisites).

## Prerequisites

- AWS credentials for the target account (`AWS_PROFILE`, or exported access keys), and the AWS CLI: the Kubernetes and Helm providers get cluster tokens with `aws eks get-token`.
- Cross-account ECR pull access granted by Ghost Security for this account. See [Onboarding](../../README.md#onboarding).
- A Route 53 hosted zone for the hostname, or an ACM certificate for it in the deployment's region.
- Terraform 1.5.7 or later.

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: region, your IP for the cluster API, release, hostname, and zone.
terraform init
terraform apply -target=module.vpc -target=module.ebs_csi_pod_identity \
  -target=module.efs_csi_pod_identity -target=module.eks
terraform apply
```

The first apply runs in two steps because the Kubernetes and Helm providers connect to the cluster, which the first step creates. That step names every module the cluster depends on, because a target brings along only the resources the cluster references: without the others, the nodes would miss the VPC's NAT gateway and routes, and the storage drivers their IAM policies. Later applies are a single `terraform apply`.

The first step takes about 15 minutes. The second installs the load balancer controller and the platform, requests the certificate, and waits for the load balancer, which takes another 10 minutes or so.

## After apply

```bash
terraform output url                          # https://ghost.example.com
terraform output -raw claim_token             # one-time setup-wizard token
$(terraform output -raw kubeconfig_command)   # kubectl and helm access
$(terraform output -raw helm_test_command)    # health and worker isolation tests
```

Open the URL, enter the claim token, and create the first admin. DNS for a new record can take a few minutes; until then, `$(terraform output -raw port_forward_command)` serves the UI at `http://localhost:8080`.

`kubectl -n exo get pods -o wide` shows where everything runs: workers on the `workers` node group, everything else on `system`.

## Sizing

The `system` nodes have 50 GiB disks and the `workers` nodes 100 GiB; change `volume_size` under each node group's `block_device_mappings`. MongoDB gets a 100 GiB volume. See [Sizing](../../modules/eks/README.md#sizing) in the module README for how much disk workers need, and how to set or grow the database volume.

## Ghost support access

The module publishes a role Ghost Security assumes for support (output `ghost_support_role_arn`): it reaches the UI and reads the platform's logs over Session Manager on the `system` nodes, which this example registers with Session Manager. See [Ghost support access](../../modules/eks/README.md#ghost-support-access). To turn it off, set `ghost_support_access_enabled = false` in the `ghost_agent` module block.

## Upgrading

Set `exo_version` in `terraform.tfvars` to the new release and run `terraform apply`.

To upgrade the cluster's Kubernetes version, set `kubernetes_version` to the next minor version and run `terraform apply`. Read [Upgrading the cluster](../../modules/eks/README.md#upgrading-the-cluster) in the module README first.

## Removing

The platform's EFS file systems are protected against `terraform destroy`. To tear down this example:

1. Remove the `prevent_destroy = true` lines in [modules/eks/storage.tf](../../modules/eks/storage.tf).
2. Destroy the platform first, then everything else:

   ```bash
   terraform destroy -target=module.ghost_agent
   terraform destroy
   ```

   The first step removes the platform while the AWS Load Balancer Controller still runs, so the controller deletes the load balancer it created for the platform. In a single `terraform destroy`, the controller can be removed first, leaving the load balancer behind and the VPC impossible to delete.
3. Delete the database volume, which the `Retain` reclaim policy keeps:

   ```bash
   aws ec2 describe-volumes --region <region> \
     --filters Name=tag:kubernetes.io/created-for/pvc/name,Values=data-database-0 \
     --query 'Volumes[].VolumeId' --output text
   aws ec2 delete-volume --region <region> --volume-id <volume id>
   ```

The encryption key's Secrets Manager secret stays in a 7-day recovery window. To apply again with the same name before it ends, force-delete it: `aws secretsmanager delete-secret --secret-id ghost-agent-eks/encryption-key --force-delete-without-recovery --region <region>`.
