# Gateway config — template. Cloud-init renders this at boot time
# after fetching secrets from AWS Secrets Manager.
#
# Placeholders use @@VAR@@ syntax (not Terraform's ${VAR}, not bash
# $VAR) so they survive terraform's templatefile() pass intact and
# can be sed-replaced by cloud-init with the runtime secret values.

[server]
addr = ":8000"
ui_origin = "https://@@DOMAIN@@"

[database]
# See config.proxy.toml.tpl for the URI-flag rationale.
mongo_uri = "mongodb://database:27017/?replicaSet=rs0&directConnection=true"
mongo_database = "exo"

[auth]
jwt_secret = "@@JWT_SECRET@@"
issuer = "exo-api"
audience = "exo-ui"
access_token_ttl = "1m"
refresh_token_ttl = "168h"

[artifacts]
root_dir = "/var/lib/exo/artifacts"

[runners]
heartbeat_timeout = "30s"
poll_interval = "5s"
# Runner client-cert TTL + renewal window. Short TTL bounds the
# worst-case exposure on a compromised runner host; heartbeat-driven
# renewal at 15m remaining keeps things smooth.
cert_ttl = "1h"
cert_renew_before = "15m"
# CIDR allowlist for the unauthenticated POST /api/v1/runners/enroll
# endpoint. Workers run on the same VM, on the docker `internal`
# bridge (172.28.0.0/24, an RFC1918 subnet) — included along with the
# rest of RFC1918 in case future runners run on a peered network.
enrollment_allowed_networks = ["127.0.0.1/32", "::1/128", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
enrollment_rate_per_ip_per_minute = 6

[proxy]
public_url = "https://credential-proxy"
internal_base_url = "https://credential-proxy:8444"
internal_ca_path = "/var/lib/exo/tls/service-ca.crt"
tls_dev_dir = "/var/lib/exo/tls"
service_ca_cert_path = "/var/lib/exo/tls/service-ca.crt"
gateway_cert_dir = "/var/lib/exo/tls"
per_run_burst          = 100
per_run_refill_per_sec = 20

# OAuth callback target. In prod, Caddy fronts the gateway with a real
# Let's Encrypt cert at the public domain, so callbacks land here at
# the same hostname the UI uses — no RFC 8252 loopback carve-out
# needed.
callback_base_url = "https://@@DOMAIN@@"

[updater]
# Consumed by the exo-updater binary; the gateway ignores this
# section. The two processes share this file because both also read
# [proxy] for cert paths and TLS-dev-dir — keeping them on the same
# config.toml avoids duplicating those values.
listen_addr = ":8080"
ecr_region = "@@IMAGE_REGISTRY_REGION@@"
# ecr_registry_id is the AWS account ID that owns the ECR repos
# (Ghost's account, NOT the customer's). Required for cross-account
# pulls: without it the SDK omits RegistryId on DescribeImages, ECR
# treats the caller's account as the registry, and the call fails
# AccessDenied even when Ghost's cross-account repo policy is set
# up correctly.
ecr_registry_id = "@@IMAGE_REGISTRY_ACCOUNT_ID@@"
ecr_repository = "exo-worker"
poll_interval = "10m"
env_file_path = "/opt/exo/.env"
compose_file_path = "/opt/exo/docker-compose.prod.yml"
# managed_services intentionally excludes "exo-updater" — every
# service shares the same TAG, so an unscoped `up -d` would recreate
# the updater container mid-flight and orphan the in-progress
# dispatch. Bumping the updater image is operator-driven (see the
# header comment in docker-compose.prod.yml).
#
# "ui-extract" (not "ui") is the right service name: the UI bundle
# lands on disk via a oneshot copy-out container of the same name;
# Caddy serves the static files from that bind mount. Caddy and the
# database are pinned to fixed upstream images so they're also
# excluded.
managed_services = ["gateway", "credential-proxy", "worker", "ui-extract"]
cert_dir = "/var/lib/exo/tls"
cert_ttl = "1h"
cert_renew_before = "15m"

[[seed.users]]
email = "@@SEED_ADMIN_EMAIL@@"
password = "@@SEED_ADMIN_PASSWORD@@"
