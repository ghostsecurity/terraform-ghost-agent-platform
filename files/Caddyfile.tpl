# Caddy reverse proxy + static UI server for the Ghost Agent Platform.
# Terraform renders this with the bring-up domain (real FQDN or
# <dashed-eip>.nip.io); Caddy auto-issues a Let's Encrypt cert for it
# via HTTP-01.
#
# The `email` directive registers an ACME account with LE for this
# deployment. LE sends expiry warnings to it when a renewal fails
# within ~3 weeks of expiry. Reusing the seed admin email so the
# notification reaches a real, validated address without an extra
# configuration knob.

{
    email ${admin_email}
}

${domain} {
    encode gzip zstd

    # API + health. The gateway terminates its own TLS with a
    # self-signed cert on the docker bridge; tls_insecure_skip_verify
    # is safe here because the connection never leaves the bridge,
    # and the gateway cert's SAN is bound to the bridge hostname
    # `gateway` (no public CA could issue for it anyway).
    @api path /api/* /healthz
    handle @api {
        reverse_proxy https://gateway:8000 {
            transport http {
                tls
                tls_insecure_skip_verify
            }
        }
    }

    # Static SPA. try_files {path} /index.html is the SPA fallback so
    # deep-link hard refreshes serve index.html and client-side routing
    # takes over.
    handle {
        root * /srv/ui
        try_files {path} /index.html
        file_server
    }
}
