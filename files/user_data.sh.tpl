#!/bin/bash
# Ghost Agent Platform — EC2 cloud-init bootstrap.
#
# Runs once on first boot. Bring-up flow:
#   1. Mount the data EBS volume at /var/lib/exo
#   2. Install Docker, compose plugin, jq, cosign
#   3. Create the on-VM directory layout under /var/lib/exo
#   4. Log in to ECR + install an hourly re-login timer
#   5. Fetch secrets from AWS Secrets Manager
#   6. Render configs to /opt/exo/ (compose, Caddyfile, gateway +
#      proxy TOMLs, .env)
#   7. cosign verify each image against the configured identity policy
#   8. docker compose pull + up -d
#   9. Install a systemd unit so the stack auto-restarts after reboot
#
# All output streams to /var/log/ghost-agent-bootstrap.log (and also
# the standard cloud-init log) for post-mortem inspection.
#
# Strict mode: any unhandled error aborts. No partial bring-ups.

set -euo pipefail
exec > >(tee -a /var/log/ghost-agent-bootstrap.log) 2>&1
echo "===> Bootstrap starting at $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ----------------------------------------------------------------------
# Terraform-rendered constants
# ----------------------------------------------------------------------
AWS_REGION='${aws_region}'
IMAGE_REGISTRY='${image_registry}'
IMAGE_TAG='${image_tag}'
BRINGUP_DOMAIN='${bringup_domain}'
SEED_ADMIN_EMAIL='${seed_admin_email}'
WORKER_REPLICAS='${worker_replicas}'
SIGN_IDENTITY_REGEX='${image_signing_identity_regex}'
SIGN_OIDC_ISSUER='${image_signing_oidc_issuer}'
SECRET_ARN_JWT='${secret_arn_jwt}'
SECRET_ARN_ENCRYPTION_KEY='${secret_arn_encryption_key}'
SECRET_ARN_SEED_PASSWORD='${secret_arn_seed_password}'
SECRET_ARN_SLACK='${secret_arn_slack}'

# Pinned tool versions + SHA256 sums of the release binaries. cosign is
# locked to match the publish-side pin in
# .github/workflows/publish-to-ecr.yml — bump both together or
# verification breaks. SHAs come from the official checksums.txt at
# each release; verify before use to close the GitHub-download trust
# gap (a tampered cosign binary would defeat the image-signature
# verification chain below).
COSIGN_VERSION=v3.0.6
COSIGN_SHA256=c956e5dfcac53d52bcf058360d579472f0c1d2d9b69f55209e256fe7783f4c74
COMPOSE_VERSION=v5.1.3
COMPOSE_SHA256=a0298760c9772d2c06888fc8703a487c94c3c3b0134adeef830742a2fc7647b4

DATA_DIR=/var/lib/exo
OPT_DIR=/opt/exo

# ----------------------------------------------------------------------
# 1. Mount the data EBS volume
# ----------------------------------------------------------------------
echo "===> Mounting data volume at $${DATA_DIR}"

# Find the EBS data volume by excluding the root disk. AL2023 on
# Nitro instances sees EBS volumes as nvme devices regardless of the
# aws_volume_attachment device_name (which is a hint, not a literal
# path on modern instance families).
#
# Root-disk detection: findmnt → root partition → lsblk PKNAME → disk.
# Verified to work on AL2023.
ROOT_DISK=$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" | head -1)
echo "       root disk: $${ROOT_DISK}"

# Race condition note: aws_volume_attachment in Terraform happens AFTER
# the instance enters `running` state, but cloud-init starts running
# user_data immediately at boot. The data volume may not be attached
# yet — poll for up to 5 minutes.
#
# Plain bash string comparison (no regex, no awk field-counting) so
# escaping in the template can't cause subtle filter failures.
DATA_DEV=""
for i in $(seq 1 30); do
  for d in $(lsblk -dno NAME); do
    if [[ "$${d}" != "$${ROOT_DISK}" ]]; then
      DATA_DEV="/dev/$${d}"
      break 2
    fi
  done
  echo "       waiting for data volume attachment (attempt $${i}/30)..."
  sleep 10
done
if [[ -z "$${DATA_DEV}" ]]; then
  echo "ERROR: no data volume found after 5 minutes"
  lsblk
  exit 1
fi
echo "       data volume device: $${DATA_DEV}"

# Format only when blank — never touch an existing filesystem (this
# is the survival-critical state).
if ! blkid "$${DATA_DEV}" >/dev/null 2>&1; then
  echo "       formatting $${DATA_DEV} as xfs"
  mkfs.xfs "$${DATA_DEV}"
fi

mkdir -p "$${DATA_DIR}"

# Persistent mount via UUID. nofail keeps a missing volume from
# blocking boot — SSH still works for recovery.
UUID=$(blkid -s UUID -o value "$${DATA_DEV}")
if ! grep -q "$${UUID}" /etc/fstab; then
  echo "UUID=$${UUID} $${DATA_DIR} xfs defaults,nofail 0 2" >> /etc/fstab
fi
mount -a

# Hard-fail if the data dir isn't actually on the EBS — otherwise
# everything below writes to the root volume and gets lost on
# instance replacement.
if ! mountpoint -q "$${DATA_DIR}"; then
  echo "ERROR: $${DATA_DIR} is not a mountpoint after mount -a"
  exit 1
fi

# ----------------------------------------------------------------------
# 2. Install Docker, compose plugin, jq, cosign
# ----------------------------------------------------------------------
echo "===> Installing system packages"
# amazon-ssm-agent is installed explicitly: AL2023 AMIs are inconsistent
# about including it preinstalled. Without it, SSM Session Manager
# access (the alternative to SSH) doesn't work.
dnf install -y docker jq amazon-ssm-agent

systemctl enable --now docker
systemctl enable --now amazon-ssm-agent
usermod -aG docker ec2-user

echo "===> Installing docker compose plugin $${COMPOSE_VERSION}"
mkdir -p /usr/local/lib/docker/cli-plugins
curl -fsSL "https://github.com/docker/compose/releases/download/$${COMPOSE_VERSION}/docker-compose-linux-x86_64" \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
echo "$${COMPOSE_SHA256}  /usr/local/lib/docker/cli-plugins/docker-compose" | sha256sum -c -
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

echo "===> Installing cosign $${COSIGN_VERSION}"
curl -fsSL "https://github.com/sigstore/cosign/releases/download/$${COSIGN_VERSION}/cosign-linux-amd64" \
  -o /usr/local/bin/cosign
echo "$${COSIGN_SHA256}  /usr/local/bin/cosign" | sha256sum -c -
chmod +x /usr/local/bin/cosign

# ----------------------------------------------------------------------
# 3. ECR login + hourly re-login timer (tokens expire every 12h)
# ----------------------------------------------------------------------
echo "===> Logging in to ECR"
aws ecr get-login-password --region "$${AWS_REGION}" \
  | docker login --username AWS --password-stdin "$${IMAGE_REGISTRY}"

cat >/etc/systemd/system/ecr-login.service <<EOF
[Unit]
Description=Refresh ECR auth token
After=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'aws ecr get-login-password --region ${aws_region} | docker login --username AWS --password-stdin ${image_registry}'
EOF

cat >/etc/systemd/system/ecr-login.timer <<'EOF'
[Unit]
Description=Refresh ECR auth token hourly

[Timer]
OnBootSec=5min
OnUnitActiveSec=1h

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now ecr-login.timer

# ----------------------------------------------------------------------
# 4. Create the on-VM directory layout under /var/lib/exo
# ----------------------------------------------------------------------
echo "===> Creating data subdirectories"
mkdir -p \
  "$${DATA_DIR}/mongo-data" \
  "$${DATA_DIR}/tls" \
  "$${DATA_DIR}/tls-public" \
  "$${DATA_DIR}/artifacts" \
  "$${DATA_DIR}/runner-identity" \
  "$${DATA_DIR}/caddy-data" \
  "$${DATA_DIR}/caddy-config" \
  "$${DATA_DIR}/ui"

# Container UID/GID for the bind mounts. Hardcoding the worker's UID
# was brittle (depends on what `useradd` picks during image build), so
# query the actual image instead. Mongo's 999 is stable across the
# mongo:7 image line — keep that hardcoded.
echo "       querying worker image UID..."
WORKER_UID=$(docker run --rm --entrypoint id "$${IMAGE_REGISTRY}/exo-worker:$${IMAGE_TAG}" -u)
WORKER_GID=$(docker run --rm --entrypoint id "$${IMAGE_REGISTRY}/exo-worker:$${IMAGE_TAG}" -g)
echo "       worker uid:gid = $${WORKER_UID}:$${WORKER_GID}"

chown -R 999:999 "$${DATA_DIR}/mongo-data"
chown -R "$${WORKER_UID}:$${WORKER_GID}" "$${DATA_DIR}/artifacts" "$${DATA_DIR}/runner-identity"
chmod 0700 "$${DATA_DIR}/tls"

# Worker /etc/resolv.conf. Bind-mounted into the worker container to
# bypass Docker's embedded DNS resolver, which on user-defined
# networks listens at 127.0.0.11 and is supposed to forward to the
# upstream configured via the compose `dns:` directive. In this stack
# the forwarder returns SERVFAIL when the upstream is a docker bridge
# IP (the credential-proxy at 172.28.0.10) — even though the daemon's
# netns can reach the proxy fine on :53. Writing the resolver list
# directly sidesteps the embedded resolver entirely:
#   - 127.0.0.11 stays FIRST so docker service discovery still resolves
#     stack-internal names (gateway, database, credential-proxy)
#     without depending on the credential-proxy being up.
#   - 172.28.0.10 is the fallthrough for everything else — every
#     public hostname resolves to the proxy's own IP, landing all
#     agent HTTPS dials at the MITM listener so the run-token gets
#     swapped for the real upstream secret.
#   - ndots:0 disables search-list expansion so absolute names like
#     `api.openai.com` aren't tried as `api.openai.com.ec2.internal`
#     first.
cat >"$${DATA_DIR}/worker-resolv.conf" <<'EOF'
nameserver 127.0.0.11
nameserver 172.28.0.10
options ndots:0
EOF
chmod 0644 "$${DATA_DIR}/worker-resolv.conf"

# ----------------------------------------------------------------------
# 5. Fetch secrets from AWS Secrets Manager
# ----------------------------------------------------------------------
echo "===> Fetching secrets"
JWT_SECRET=$(aws secretsmanager get-secret-value \
  --region "$${AWS_REGION}" --secret-id "$${SECRET_ARN_JWT}" \
  --query SecretString --output text)
ENCRYPTION_KEY=$(aws secretsmanager get-secret-value \
  --region "$${AWS_REGION}" --secret-id "$${SECRET_ARN_ENCRYPTION_KEY}" \
  --query SecretString --output text)
SEED_ADMIN_PASSWORD=$(aws secretsmanager get-secret-value \
  --region "$${AWS_REGION}" --secret-id "$${SECRET_ARN_SEED_PASSWORD}" \
  --query SecretString --output text)
SLACK_JSON=$(aws secretsmanager get-secret-value \
  --region "$${AWS_REGION}" --secret-id "$${SECRET_ARN_SLACK}" \
  --query SecretString --output text)
SLACK_APP_TOKEN=$(echo "$${SLACK_JSON}" | jq -r '.app_token // ""')
SLACK_BOT_TOKEN=$(echo "$${SLACK_JSON}" | jq -r '.bot_token // ""')
SLACK_SIGNING_SECRET=$(echo "$${SLACK_JSON}" | jq -r '.signing_secret // ""')

# ----------------------------------------------------------------------
# 6. Write configs to /opt/exo/
# ----------------------------------------------------------------------
echo "===> Writing configs to $${OPT_DIR}"
mkdir -p "$${OPT_DIR}"

# docker-compose.prod.yml — verbatim copy of the file rendered into
# this script by terraform. Quoted heredoc keeps bash from
# interpreting the $${REGISTRY} / $${TAG} substitutions in the YAML;
# docker compose resolves those itself when it reads .env below.
cat >"$${OPT_DIR}/docker-compose.prod.yml" <<'COMPOSE_EOF'
${docker_compose_yml}
COMPOSE_EOF

# Caddyfile — already rendered with the bring-up domain and admin
# email at TF apply time, so this is fully baked content.
cat >"$${OPT_DIR}/Caddyfile" <<'CADDY_EOF'
${caddyfile}
CADDY_EOF

# config.proxy.toml — no template vars, write verbatim.
cat >"$${OPT_DIR}/config.proxy.toml" <<'PROXY_EOF'
${config_proxy_toml}
PROXY_EOF

# config.toml — has @@VAR@@ placeholders. Write the template, then
# sed-substitute with the runtime-fetched values.
cat >/tmp/config.toml.tpl <<'CONFIG_TPL_EOF'
${config_toml_template}
CONFIG_TPL_EOF

# `|` delimiter on sed to avoid collisions with `/` in any value.
# The chosen random_password special chars exclude `&` and `\` so
# replacement is safe.
sed \
  -e "s|@@DOMAIN@@|$${BRINGUP_DOMAIN}|g" \
  -e "s|@@JWT_SECRET@@|$${JWT_SECRET}|g" \
  -e "s|@@SEED_ADMIN_EMAIL@@|$${SEED_ADMIN_EMAIL}|g" \
  -e "s|@@SEED_ADMIN_PASSWORD@@|$${SEED_ADMIN_PASSWORD}|g" \
  /tmp/config.toml.tpl > "$${OPT_DIR}/config.toml"
rm /tmp/config.toml.tpl

# Compose env file. Provides the runtime values docker compose
# substitutes when reading docker-compose.prod.yml. WORKER_REPLICAS is
# safe to edit in place after first boot — `docker compose up -d`
# scales workers without a full restart.
cat >"$${OPT_DIR}/.env" <<EOF
REGISTRY=$${IMAGE_REGISTRY}
TAG=$${IMAGE_TAG}
WORKER_REPLICAS=$${WORKER_REPLICAS}
ENCRYPTION_KEY=$${ENCRYPTION_KEY}
SLACK_APP_TOKEN=$${SLACK_APP_TOKEN}
SLACK_BOT_TOKEN=$${SLACK_BOT_TOKEN}
SLACK_SIGNING_SECRET=$${SLACK_SIGNING_SECRET}
EOF
chmod 0600 "$${OPT_DIR}/.env"
chmod 0600 "$${OPT_DIR}/config.toml"

# ----------------------------------------------------------------------
# 7. Verify image signatures with cosign
# ----------------------------------------------------------------------
echo "===> Verifying image signatures"
for img in exo-server exo-credential-proxy exo-worker exo-ui; do
  echo "       cosign verify $${img}:$${IMAGE_TAG}"
  cosign verify "$${IMAGE_REGISTRY}/$${img}:$${IMAGE_TAG}" \
    --certificate-oidc-issuer="$${SIGN_OIDC_ISSUER}" \
    --certificate-identity-regexp="$${SIGN_IDENTITY_REGEX}" \
    >/dev/null
done
echo "       all signatures verified"

# ----------------------------------------------------------------------
# 8. Bring up the stack
# ----------------------------------------------------------------------
echo "===> Pulling images"
cd "$${OPT_DIR}"
docker compose -f docker-compose.prod.yml pull

echo "===> Starting stack"
docker compose -f docker-compose.prod.yml up -d

# ----------------------------------------------------------------------
# 9. systemd unit so the stack restarts after reboots
# ----------------------------------------------------------------------
cat >/etc/systemd/system/ghost-agent.service <<'EOF'
[Unit]
Description=Ghost Agent Platform
Requires=docker.service
After=docker.service network-online.target

[Service]
Type=oneshot
RemainAfterExit=true
WorkingDirectory=/opt/exo
ExecStart=/usr/bin/docker compose -f /opt/exo/docker-compose.prod.yml up -d
ExecStop=/usr/bin/docker compose -f /opt/exo/docker-compose.prod.yml down

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable ghost-agent.service

echo "===> Bootstrap complete at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
