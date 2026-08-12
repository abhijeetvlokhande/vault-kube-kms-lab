# Minimum-privilege policy for vault-kube-kms.
#
# Source of truth: test/integration/configure-vault/transit.tf in
# github.com/hashicorp/vault-kube-kms (verified against compiled binary).
#
# NOTE: Both "update" AND "create" are required on encrypt/decrypt paths.
# The official HashiCorp docs show only "update" — that is incorrect and
# will cause silent failures. The upstream integration-test Terraform uses
# ["update", "create"] on both paths.
#
# sys/license/status is REQUIRED. vault-kube-kms validates Vault Enterprise
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
