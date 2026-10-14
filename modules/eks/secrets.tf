# ----------------------------------------------------------------------
# Secrets: encryption key and claim token
# ----------------------------------------------------------------------

# Credential encryption key. 32 bytes hex (AES-256). Stored credentials
# cannot be decrypted without it. The credential proxy reads it from the
# Kubernetes Secret; the Secrets Manager copy keeps it recoverable
# independently of the cluster.
resource "random_id" "encryption_key" {
  byte_length = 32
}

resource "aws_secretsmanager_secret" "encryption_key" {
  name        = "${local.name}/encryption-key"
  description = "AES-256 wrapping key for the Ghost Agent Platform credential proxy. Treat as the most sensitive secret in the system: its compromise exposes every stored vendor credential."
  tags        = local.common_tags

  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "encryption_key" {
  secret_id     = aws_secretsmanager_secret.encryption_key.id
  secret_string = random_id.encryption_key.hex
}

resource "kubernetes_secret_v1" "encryption_key" {
  metadata {
    name      = "exo-encryption-key"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }

  data = {
    ENCRYPTION_KEY = random_id.encryption_key.hex
  }
}

# One-time claim token for the setup wizard. 32 bytes hex. Printed to the
# operator through the claim_token output; the platform stores only its
# hash, and the token is inert once the first admin exists.
resource "random_id" "claim_token" {
  byte_length = 32
}

resource "kubernetes_secret_v1" "claim_token" {
  metadata {
    name      = "exo-claim-token"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }

  data = {
    EXO_CLAIM_TOKEN = random_id.claim_token.hex
  }
}
