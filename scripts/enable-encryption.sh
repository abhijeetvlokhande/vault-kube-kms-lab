#!/usr/bin/env bash
# Patch the kube-apiserver static pod manifest to add --encryption-provider-config,
# then wait for the API server to come back healthy.
set -euo pipefail

log()   { echo "[$(date +%H:%M:%S)] $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }

KIND_CLUSTER_NAME="vault-kube-kms"
CONTAINER="${KIND_CLUSTER_NAME}-control-plane"
APISERVER_MANIFEST="/etc/kubernetes/manifests/kube-apiserver.yaml"
BACKUP_MANIFEST="/etc/kubernetes/kube-apiserver.yaml.backup"

log "Enabling KMS encryption on kube-apiserver..."

if ! docker exec "$CONTAINER" test -S /tmp/vault-kube-kms.socket 2>/dev/null; then
	error "vault-kube-kms socket not found. Run: make deploy-kms"
fi

docker exec "$CONTAINER" cp "$APISERVER_MANIFEST" "$BACKUP_MANIFEST"
log "Backed up manifest to $BACKUP_MANIFEST"

if docker exec "$CONTAINER" grep -q 'encryption-provider-config' "$APISERVER_MANIFEST" 2>/dev/null; then
	log "encryption-provider-config already present in manifest — skipping patch"
else
	docker exec "$CONTAINER" bash -c "
		awk '
		/^    - kube-apiserver\$/ {
			print
			print \"    - --encryption-provider-config=/etc/kubernetes/encryption-config.yaml\"
			print \"    - --encryption-provider-config-automatic-reload=true\"
			next
		}
		{print}
		' ${APISERVER_MANIFEST} > ${APISERVER_MANIFEST}.tmp
		mv ${APISERVER_MANIFEST}.tmp ${APISERVER_MANIFEST}
	"
	log "Patched $APISERVER_MANIFEST with encryption-provider-config flags"
fi

log "Waiting for kube-apiserver to restart (up to 5 minutes)..."
TIMEOUT=300
ELAPSED=0
while [[ $ELAPSED -lt $TIMEOUT ]]; do
	if docker exec "$CONTAINER" kubectl get --raw /healthz >/dev/null 2>&1; then
		log "kube-apiserver is healthy with KMS encryption enabled (${ELAPSED}s)"
		break
	fi
	if [[ $ELAPSED -eq $TIMEOUT ]]; then
		log "API server did not recover. Restoring backup..."
		docker exec "$CONTAINER" cp "$BACKUP_MANIFEST" "$APISERVER_MANIFEST"
		error "kube-apiserver did not become healthy within ${TIMEOUT}s after encryption patch."
	fi
	sleep 2
	ELAPSED=$((ELAPSED + 2))
done

log "KMS encryption is active. Run: ./vault-demo kms-verify"
