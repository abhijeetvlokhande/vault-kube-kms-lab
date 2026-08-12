#!/usr/bin/env bash
# Prove that Kubernetes secrets are encrypted at rest in etcd by Vault.
#
# Steps:
#   1. Write a k8s secret with a known plaintext value
#   2. Read it directly from etcd -- must show k8s:enc:kms:v2:vault-kube-kms: prefix
#   3. Assert the plaintext is NOT visible in the etcd dump
#   4. Read via kubectl -- API server decrypts transparently
#
# etcd prefix proven from repo README: 'k8s:enc:kms:v2:vault-kube-kms:'
set -euo pipefail

log()   { echo "[$(date +%H:%M:%S)] $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }
pass()  { echo "[$(date +%H:%M:%S)] \u2713  $*"; }
fail()  { echo "[FAIL] $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../scripts/detect-mode.sh"

KIND_CLUSTER_NAME="vault-kube-kms"
CONTAINER="${KIND_CLUSTER_NAME}-control-plane"
EXPECTED_PREFIX="k8s:enc:kms:v2:vault-kube-kms:"
SECRET_NAME="kms-verify-test"
SECRET_VALUE="supersecret-$(date +%s)"

log "=== KMS Verify | Mode: $VAULT_MODE ==="

kubectl get nodes >/dev/null 2>&1 || error "kubectl cannot reach the cluster. Run: make enable-encryption"

log "Creating k8s secret '$SECRET_NAME' with value '$SECRET_VALUE'..."
kubectl delete secret "$SECRET_NAME" --ignore-not-found >/dev/null
kubectl create secret generic "$SECRET_NAME" \
	--from-literal="password=$SECRET_VALUE" >/dev/null
log "Secret created"

log "Reading $SECRET_NAME directly from etcd..."
ETCD_OUTPUT="$(docker exec "$CONTAINER" \
	etcdctl --endpoints=https://127.0.0.1:2379 \
	  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
	  --cert=/etc/kubernetes/pki/etcd/server.crt \
	  --key=/etc/kubernetes/pki/etcd/server.key \
	  get "/registry/secrets/default/${SECRET_NAME}" 2>/dev/null)"

[[ -n "$ETCD_OUTPUT" ]] || error "etcd returned empty output. Is encryption enabled? Run: make enable-encryption"

if echo "$ETCD_OUTPUT" | grep -q "$EXPECTED_PREFIX"; then
	pass "etcd entry starts with: $EXPECTED_PREFIX"
else
	echo ""
	echo "  First 200 bytes of etcd output:"
	echo "$ETCD_OUTPUT" | head -c 200 | cat -v
	echo ""
	fail "etcd prefix MISMATCH. Expected: $EXPECTED_PREFIX
This means encryption is not active. Check:
  1. make enable-encryption was run and succeeded
  2. vault-kube-kms is running: make logs
  3. Vault is up: vault status"
fi

if echo "$ETCD_OUTPUT" | grep -q "$SECRET_VALUE"; then
	fail "Plaintext '$SECRET_VALUE' found in etcd dump — encryption is NOT working!"
else
	pass "Plaintext value is absent from etcd dump (ciphertext confirmed)"
fi

log "Reading secret via kubectl (API server decrypts transparently)..."
DECODED="$(kubectl get secret "$SECRET_NAME" \
	-o jsonpath='{.data.password}' | base64 -d)"
if [[ "$DECODED" == "$SECRET_VALUE" ]]; then
	pass "API server decrypted correctly: '$DECODED'"
else
	fail "API server returned unexpected value: '$DECODED' (expected '$SECRET_VALUE')"
fi

echo ""
echo "─── Raw etcd bytes (first 120) ──────────────────────────────────────────────"
echo "$ETCD_OUTPUT" | head -c 120 | cat -v
echo ""
echo "─────────────────────────────────────────────────────────────────────"

kubectl delete secret "$SECRET_NAME" >/dev/null 2>&1 || true

echo ""
log "Verification complete."
log "  etcd:       k8s:enc:kms:v2:vault-kube-kms: <- ciphertext"
log "  kubectl:    '$DECODED'  <- plaintext (Vault decrypted)"
log "  Vault audit: vault audit logs show every Transit call"
