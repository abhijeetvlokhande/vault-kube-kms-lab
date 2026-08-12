# Minimum-privilege policy for vault-kube-kms.
#
# Source of truth: test/integration/configure-vault/transit.tf in
# github.com/hashicorp/vault-kube-kms (verified against compiled binary).
#
# NOTE: Both "update" AND "create" are required on encrypt/decrypt paths.
# Using only "update" will cause silent failures.
#
# sys/license/status is required. vault-kube-kms validates Vault Enterprise
# at startup and exits immediately if this path is missing from the policy.

path "transit/decrypt/kms" {
  capabilities = ["update", "create"]
}

path "transit/encrypt/kms" {
  capabilities = ["update", "create"]
}

path "transit/keys/kms" {
  capabilities = ["read"]
}

path "sys/license/status" {
  capabilities = ["read"]
}
