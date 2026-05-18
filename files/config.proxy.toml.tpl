# Credential-proxy config. Written to /opt/exo/config.proxy.toml on the
# VM and bind-mounted into the credential-proxy container at
# /etc/exo/config.proxy.toml.
#
# No template variables — every value here is constant. The .tpl
# extension is kept for symmetry with the other config templates.

[server]
# MITM data-plane listener. Agents reach this via DNS interception
# from inside worker containers (the proxy's DNS server resolves
# public hostnames to its own bridge IP, and the agent's HTTPS dial
# lands here transparently).
addr = ":443"

[database]
# directConnection=true keeps the Go driver from topology-discovering
# the replica-set's advertised hostname (which would time out inside
# the compose network). replicaSet=rs0 enables change-stream
# subscription for live UI run-event fan-out.
mongo_uri = "mongodb://database:27017/?replicaSet=rs0&directConnection=true"
mongo_database = "exo"

[proxy]
# Bridge-only identity. The MITM and control-plane listeners are not
# exposed outside the docker network; agents only ever reach this
# proxy via the DNS interception flow.
public_url = "https://credential-proxy"
internal_listen_addr = ":8444"
tls_dev_dir = "/var/lib/exo/tls"
gateway_cert_dir = "/var/lib/exo/tls"
per_run_burst          = 100
per_run_refill_per_sec = 20

# DNS server. Worker containers' resolv.conf points here; the server
# answers A/AAAA for public hostnames with the proxy's own bridge IP
# (so MITM can authorize each request against the per-credential
# allowed-hosts list) and forwards stack-internal names to Docker's
# embedded DNS at 127.0.0.11.
dns_listen_addr = ":53"
dns_proxy_ip   = "172.28.0.10"
dns_upstream   = "127.0.0.11:53"

# Public CA material published to the tls-public volume on startup —
# the worker container mounts this read-only to validate MITM certs.
# Private keys stay on the tls volume and never reach the worker.
tls_ca_public_path = "/var/lib/exo/tls-public/ca.crt"
service_ca_public_path = "/var/lib/exo/tls-public/service-ca.crt"
