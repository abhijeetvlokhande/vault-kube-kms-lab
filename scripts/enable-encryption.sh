#!/usr/bin/env bash
# Add --encryption-provider-config to the kube-apiserver static pod manifest,
# then wait for the API server to restart cleanly.
#
# The volume mounts for the encryption config file and the KMS socket (/tmp)
# are already baked into the cluster by kind-config.yaml kubeadmConfigPatches.
# This script only needs to add the flag that activates them.
set -euo pipefail

log()   { echo "[$(date +%H:%M:%S)] $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }

KIND_CLUSTER_NAME="vault-kube-kms"
CONTAINER="${KIND_CLUSTER_NAME}-control-plane"
APISERVER_MANIFEST="/etc/kubernetes/manifests/kube-apiserver.yaml"
BACKUP_MANIFEST="/etc/kubernetes/kube-apiserver.yaml.backup"

log "Enabling KMS encryption on kube-apiserver..."

# ── Pre-flight checks ─────────────────────────────────────────────────────────
if ! docker exec "$CONTAINER" test -S /tmp/vault-kube-kms.socket 2>/dev/null; then
    error "vault-kube-kms socket not found. Run: make deploy-kms"
fi

# Confirm the encryption config file is visible inside the apiserver container.
# It should be there via the kubeadmConfigPatches extraVolumes bind-mount.
# If it's missing, the cluster was created with an old kind-config.yaml.
APISERVER_CONTAINER_ID=$(docker exec "$CONTAINER" crictl ps --name kube-apiserver -q 2>/dev/null | head -1)
if [[ -n "$APISERVER_CONTAINER_ID" ]]; then
    MOUNTS=$(docker exec "$CONTAINER" crictl inspect "$APISERVER_CONTAINER_ID" 2>/dev/null \
        | python3 -c "
import sys,json
d=json.load(sys.stdin)
paths=[m.get('container_path','') for m in d.get('info',{}).get('config',{}).get('mounts',[])]
print('\n'.join(paths))
" 2>/dev/null)
    if ! echo "$MOUNTS" | grep -q "encryption-config"; then
        error "encryption-config.yaml is not mounted into the apiserver container.
The cluster was likely created without kubeadmConfigPatches.
Run: make clean && make bootstrap"
    fi
fi

# ── Backup manifest ───────────────────────────────────────────────────────────
docker exec "$CONTAINER" cp "$APISERVER_MANIFEST" "$BACKUP_MANIFEST"
log "Backed up manifest to $BACKUP_MANIFEST"

# ── Add the flag (idempotent) ─────────────────────────────────────────────────
if docker exec "$CONTAINER" grep -q 'encryption-provider-config' "$APISERVER_MANIFEST" 2>/dev/null; then
    log "encryption-provider-config flag already present in manifest"
else
    docker exec "$CONTAINER" python3 - <<'PYEOF'
manifest_path = "/etc/kubernetes/manifests/kube-apiserver.yaml"
with open(manifest_path, "r") as f:
    content = f.read()
content = content.replace(
    "    - kube-apiserver\n",
    "    - kube-apiserver\n"
    "    - --encryption-provider-config=/etc/kubernetes/encryption-config.yaml\n"
    "    - --encryption-provider-config-automatic-reload=true\n"
)
with open(manifest_path, "w") as f:
    f.write(content)
print("Manifest patched: added encryption-provider-config flags")
PYEOF
    log "Added --encryption-provider-config to kube-apiserver manifest"
fi

# ── Wait for API server to come back healthy ──────────────────────────────────
log "Waiting for kube-apiserver to restart (up to 5 minutes)..."
TIMEOUT=300
ELAPSED=0
while [[ $ELAPSED -lt $TIMEOUT ]]; do
    if kubectl --context "kind-${KIND_CLUSTER_NAME}" get --raw /healthz >/dev/null 2>&1; then
        # Double-check it's the new pod (encryption flag present in running args)
        if docker exec "$CONTAINER" crictl inspect \
            "$(docker exec "$CONTAINER" crictl ps --name kube-apiserver -q 2>/dev/null | head -1)" \
            2>/dev/null | grep -q "encryption-provider-config"; then
            log "kube-apiserver is healthy with KMS encryption enabled (${ELAPSED}s)"
            break
        fi
    fi
    if [[ $ELAPSED -ge $TIMEOUT ]]; then
        log "API server did not recover. Restoring backup manifest..."
        docker exec "$CONTAINER" cp "$BACKUP_MANIFEST" "$APISERVER_MANIFEST"
        error "kube-apiserver did not become healthy within ${TIMEOUT}s."
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
done

log "KMS encryption is active. Run: ./vault-demo kms-verify"
