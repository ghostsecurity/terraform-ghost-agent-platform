#!/bin/bash
# Ghost Agent Platform — EC2 cloud-init bootstrap.
#
# Runs once on first boot. Bring-up flow:
#   1. Mount the data EBS volume at /var/lib/exo
#   2. Install Docker, compose plugin, jq, cosign, oras
#   3. Create the on-VM directory layout under /var/lib/exo
#   4. Log in to ECR + install an hourly re-login timer
#   5. Fetch secrets from AWS Secrets Manager
#   6. cosign-verify + oras-fetch the stack bundle (compose) and render
#      the rest of the configs to /opt/exo/ (Caddyfile, gateway + proxy
#      TOMLs, .env)
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

# cloud-init runs with $HOME unset; oras requires it. Point it at root's
# home, where the ECR docker login writes /root/.docker/config.json.
export HOME=/root

# ----------------------------------------------------------------------
# Terraform-rendered constants
# ----------------------------------------------------------------------
AWS_REGION='${aws_region}'
IMAGE_REGISTRY='${image_registry}'
IMAGE_REGISTRY_REGION='${image_registry_region}'
IMAGE_REGISTRY_ACCOUNT_ID='${image_registry_account_id}'
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
# locked to the version that signs the published images — keep them in
# step or verification breaks. SHAs come from the official checksums.txt
# at each release; verify before use to close the GitHub-download trust
# gap (a tampered cosign binary would defeat the image-signature
# verification chain below).
COSIGN_VERSION=v3.0.6
COSIGN_SHA256=c956e5dfcac53d52bcf058360d579472f0c1d2d9b69f55209e256fe7783f4c74
COMPOSE_VERSION=v5.1.3
COMPOSE_SHA256=a0298760c9772d2c06888fc8703a487c94c3c3b0134adeef830742a2fc7647b4
# oras pulls the signed stack bundle (the docker-compose) from ECR at
# boot. Verified against the release's published checksums file (no SHA
# to maintain here).
ORAS_VERSION=1.2.3

# Docker is pinned (not "latest") and version-locked below. AL2023's docker
# 25.0.16 has a libnetwork regression: it fails to attach a container to
# multiple bridge networks when one is `internal: true`, erroring with
# "cannot program address ... conflicts with existing route 0.0.0.0/0".
# That breaks the credential-proxy and gateway, which both sit on the
# internal + database + external networks. 25.0.14 is the last good build.
# Bump this once a fixed docker lands in the AL2023 repo (verify the proxy
# comes up on its 3 networks), then update the versionlock accordingly.
DOCKER_VERSION=25.0.14-1.amzn2023.0.6

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
# access (the alternative to SSH) doesn't work. docker is pinned to
# DOCKER_VERSION and then version-locked (see the versions block above)
# so a later `dnf upgrade` or unattended patch can't bump it back to a
# libnetwork-broken build.
dnf install -y "docker-$${DOCKER_VERSION}" jq amazon-ssm-agent python3-dnf-plugin-versionlock
dnf versionlock add docker

# Daemon-wide log rotation. Without this, the json-file driver
# accumulates container stdout/stderr under /var/lib/docker/containers/*/
# without bound - a verbose worker on a busy stack can fill the root
# EBS volume. The cap below holds each container to ≤ 3 × 10 MB
# of log retention (current + 2 rotated), which is small enough that a
# fully-loaded stack (gateway + proxy + db + N workers + caddy +
# updater) stays under ~1 GB of log spillover even with chatty agent
# output. Written BEFORE `systemctl enable --now docker` so the daemon
# picks it up on its very first boot — no restart needed.
mkdir -p /etc/docker
cat >/etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF

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

echo "===> Installing oras v$${ORAS_VERSION}"
# Download the tarball + its checksums file under their canonical names
# (so `sha256sum -c` finds the artifact), verify, then extract the oras
# binary. Subshell keeps the cd contained; strict mode aborts on any
# download/checksum failure.
ORAS_TMP=$(mktemp -d)
( cd "$${ORAS_TMP}"
  curl -fsSL -O "https://github.com/oras-project/oras/releases/download/v$${ORAS_VERSION}/oras_$${ORAS_VERSION}_linux_amd64.tar.gz"
  curl -fsSL -O "https://github.com/oras-project/oras/releases/download/v$${ORAS_VERSION}/oras_$${ORAS_VERSION}_checksums.txt"
  grep " oras_$${ORAS_VERSION}_linux_amd64.tar.gz$" "oras_$${ORAS_VERSION}_checksums.txt" | sha256sum -c -
  tar -xzf "oras_$${ORAS_VERSION}_linux_amd64.tar.gz" -C /usr/local/bin oras )
chmod +x /usr/local/bin/oras
rm -rf "$${ORAS_TMP}"

# ----------------------------------------------------------------------
# 3. ECR login + hourly re-login timer (tokens expire every 12h)
# ----------------------------------------------------------------------
echo "===> Logging in to ECR"
aws ecr get-login-password --region "$${IMAGE_REGISTRY_REGION}" \
  | docker login --username AWS --password-stdin "$${IMAGE_REGISTRY}"

cat >/etc/systemd/system/ecr-login.service <<EOF
[Unit]
Description=Refresh ECR auth token
After=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'aws ecr get-login-password --region ${image_registry_region} | docker login --username AWS --password-stdin ${image_registry}'
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
# 3b. Daily prune of stale Docker images
# ----------------------------------------------------------------------
# Each in-app upgrade leaves the previous release's images on disk for
# instant rollback. The 7-day window keeps a 30 GB root volume safe at
# ≤5 releases/week (worker image dominates at ~4 GB each). Pruning a
# tag locally is safe: `docker compose pull` re-fetches from ECR on
# rollback, just takes a few extra seconds.

cat >/etc/systemd/system/exo-docker-prune.service <<'EOF'
[Unit]
Description=Prune unused Docker images older than 7 days
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/bin/docker image prune -a --filter "until=168h" -f
EOF

cat >/etc/systemd/system/exo-docker-prune.timer <<'EOF'
[Unit]
Description=Daily Docker image prune

[Timer]
OnCalendar=daily
# Spread fleet-wide prunes across an hour so they don't all hit ECR /
# disk at the same instant if a future change makes the job heavier.
RandomizedDelaySec=1h
# Persistent=true catches up missed runs (host was off, etc.) on next
# boot instead of waiting another 24h.
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now exo-docker-prune.timer

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
chown -R "$${WORKER_UID}:$${WORKER_GID}" "$${DATA_DIR}/runner-identity"
# Artifacts is shared read-write between the gateway (runs as 65532:65532)
# and the worker (agent user, a supplementary member of gid 65532). Group
# 65532 + setgid (2775) makes files written by either side inherit group
# 65532 and stay mutually readable.
chown -R 65532:65532 "$${DATA_DIR}/artifacts"
chmod 2775 "$${DATA_DIR}/artifacts"
# TLS dirs are owned by 65532 — the credential-proxy (writer) and the
# gateway (reader) both run as that UID. The updater also reads tls but
# runs as root (see exo-updater user: "0:0"), so it reads via root's
# permission bypass. tls stays 0700 (holds private keys); tls-public is
# left world-readable (the worker reads ca.crt from it).
chown -R 65532:65532 "$${DATA_DIR}/tls" "$${DATA_DIR}/tls-public"
chmod 0700 "$${DATA_DIR}/tls"
# The ui-extract oneshot runs as the nginx-unprivileged UID 101 and writes
# the static bundle into this bind mount.
chown -R 101:101 "$${DATA_DIR}/ui"

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
# 6. Fetch the stack bundle + write configs to /opt/exo/
# ----------------------------------------------------------------------
echo "===> Writing configs to $${OPT_DIR}"
mkdir -p "$${OPT_DIR}"

# docker-compose.prod.yml — fetched from the signed stack bundle in ECR
# (not baked into this script), so the compose topology travels with the
# release and stays the single source of truth the in-stack updater also
# pulls. cosign-verify against the publish-workflow identity BEFORE
# pulling, then oras-pull into /opt/exo. The bundle's file is named
# docker-compose.prod.yml (matching config.toml's compose_file_path); the
# ECR login above lets oras/cosign authenticate via /root/.docker/config.json.
echo "===> Verifying + fetching stack bundle exo-stack:$${IMAGE_TAG}"
cosign verify "$${IMAGE_REGISTRY}/exo-stack:$${IMAGE_TAG}" \
  --certificate-oidc-issuer="$${SIGN_OIDC_ISSUER}" \
  --certificate-identity-regexp="$${SIGN_IDENTITY_REGEX}" \
  >/dev/null
oras pull "$${IMAGE_REGISTRY}/exo-stack:$${IMAGE_TAG}" -o "$${OPT_DIR}"

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

# The stack-signing identity regex contains backslashes (\.) and the
# `|` sed delimiter is meaningful, so escape both values for use as sed
# REPLACEMENT text (escape `\`, then `|`, then `&`).
SIGN_IDENTITY_REGEX_SED=$(printf '%s' "$${SIGN_IDENTITY_REGEX}" | sed -e 's/\\/\\\\/g' -e 's/|/\\|/g' -e 's/&/\\&/g')
SIGN_OIDC_ISSUER_SED=$(printf '%s' "$${SIGN_OIDC_ISSUER}" | sed -e 's/\\/\\\\/g' -e 's/|/\\|/g' -e 's/&/\\&/g')

# `|` delimiter on sed to avoid collisions with `/` in any value.
# The chosen random_password special chars exclude `&` and `\` so
# replacement is safe; the signing values are pre-escaped above.
sed \
  -e "s|@@DOMAIN@@|$${BRINGUP_DOMAIN}|g" \
  -e "s|@@SEED_ADMIN_EMAIL@@|$${SEED_ADMIN_EMAIL}|g" \
  -e "s|@@IMAGE_REGISTRY_REGION@@|$${IMAGE_REGISTRY_REGION}|g" \
  -e "s|@@IMAGE_REGISTRY_ACCOUNT_ID@@|$${IMAGE_REGISTRY_ACCOUNT_ID}|g" \
  -e "s|@@STACK_SIGNING_IDENTITY_REGEX@@|$${SIGN_IDENTITY_REGEX_SED}|g" \
  -e "s|@@STACK_SIGNING_OIDC_ISSUER@@|$${SIGN_OIDC_ISSUER_SED}|g" \
  /tmp/config.toml.tpl > "$${OPT_DIR}/config.toml"
rm /tmp/config.toml.tpl

# Compose env file. Provides the runtime values docker compose
# substitutes when reading docker-compose.prod.yml. WORKER_REPLICAS is
# safe to edit in place after first boot — `docker compose up -d`
# scales workers without a full restart.
cat >"$${OPT_DIR}/.env" <<EOF
REGISTRY=$${IMAGE_REGISTRY}
TAG=$${IMAGE_TAG}
# Updater image tag is tracked separately from the rest of the
# stack. UI-driven upgrades rewrite TAG but leave UPDATER_TAG
# untouched (the updater excludes itself from `docker compose up
# -d`); operator bumps it out of band on release.
UPDATER_TAG=$${IMAGE_TAG}
WORKER_REPLICAS=$${WORKER_REPLICAS}
ENCRYPTION_KEY=$${ENCRYPTION_KEY}
# Gateway secrets supplied via env (not config.toml) so config.toml stays
# non-secret and the non-root gateway can read it. config.Load prefers
# these over the (blank) config.toml values.
EXO_JWT_SECRET=$${JWT_SECRET}
EXO_SEED_ADMIN_PASSWORD=$${SEED_ADMIN_PASSWORD}
SLACK_APP_TOKEN=$${SLACK_APP_TOKEN}
SLACK_BOT_TOKEN=$${SLACK_BOT_TOKEN}
SLACK_SIGNING_SECRET=$${SLACK_SIGNING_SECRET}
EOF
# config.toml and config.proxy.toml now carry no secrets (gateway secrets
# come from .env via the compose environment), so they can be world-readable
# for the non-root gateway + credential-proxy (UID 65532) reading them from
# bind mounts. .env holds the secrets and stays root-only 0600 — only the
# host's `docker compose` (which injects them as env) and the root updater
# read it.
chmod 0644 "$${OPT_DIR}/config.toml" "$${OPT_DIR}/config.proxy.toml"
chmod 0600 "$${OPT_DIR}/.env"

# ----------------------------------------------------------------------
# 7. Verify image signatures with cosign
# ----------------------------------------------------------------------
echo "===> Verifying image signatures"
for img in exo-server exo-credential-proxy exo-worker exo-ui exo-updater; do
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
