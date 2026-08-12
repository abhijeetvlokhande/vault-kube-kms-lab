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
# It must be present via the kubeadmConfigPatches extraVolumes bind-mount.
# If it is missing the cluster was created with an old kind-config.yaml.
if ! docker exec "$CONTAINER" test -f /etc/kubernetes/encryption-config.yaml 2>/dev/null; then
    error "encryption-config.yaml not found at /etc/kubernetes/encryption-config.yaml inside the node.
The cluster was likely created without kubeadmConfigPatches.
Run: make clean && make bootstrap"
fi

# ── Backup manifest ───────────────────────────────────────────────────────────
docker exec "$CONTAINER" cp "$APISERVER_MANIFEST" "$BACKUP_MANIFEST"
log "Backed up manifest to $BACKUP_MANIFEST"

# ── Add the flag (idempotent) ─────────────────────────────────────────────────
if docker exec "$CONTAINER" grep -q 'encryption-provider-config' "$APISERVER_MANIFEST" 2>/dev/null; then
    log "encryption-provider-config flag already present in manifest — skipping patch"
else
    # Use awk inside a bash -c string so there is no heredoc / stdin to pass.
    # awk inserts the two flags on the line immediately after '- kube-apiserver',
    # writes to a tmp file, then mv atomically replaces the manifest.
    docker exec "$CONTAINER" bash -c '
        awk "/- kube-apiserver/{print; print \"    - --encryption-provider-config=/etc/kubernetes/encryption-config.yaml\"; print \"    - --encryption-provider-config-automatic-reload=true\"; next}1" \
            /etc/kubernetes/manifests/kube-apiserver.yaml \
            > /tmp/apiserver-patched.yaml \
        && mv /tmp/apiserver-patched.yaml /etc/kubernetes/manifests/kube-apiserver.yaml
    '

    # Verify the patch actually landed
    PATCH_COUNT=$(docker exec "$CONTAINER" grep -c 'encryption-provider-config' "$APISERVER_MANIFEST" 2>/dev/null || echo 0)
    if [[ "$PATCH_COUNT" -lt 2 ]]; then
        log "Manifest patch verification failed — restoring backup"
        docker exec "$CONTAINER" cp "$BACKUP_MANIFEST" "$APISERVER_MANIFEST"
        error "Failed to patch $APISERVER_MANIFEST (expected 2 occurrences of 'encryption-provider-config', got ${PATCH_COUNT})."
    fi
    log "Added --encryption-provider-config to kube-apiserver manifest (${PATCH_COUNT} occurrences confirmed)"
fi

# ── Wait for API server to come back healthy ──────────────────────────────────
log "Waiting for kube-apiserver to restart (up to 5 minutes)..."
TIMEOUT=300
ELAPSED=0
while [[ $ELAPSED -lt $TIMEOUT ]]; do
    if kubectl --context "kind-${KIND_CLUSTER_NAME}" get --raw /healthz >/dev/null 2>&1; then
        # Double-check it's the new pod (encryption flag present in running args).
        # crictl inspect returns the full container config including args.
        NEW_POD_ID=$(docker exec "$CONTAINER" crictl ps --name kube-apiserver -q 2>/dev/null | head -1)
        if [[ -n "$NEW_POD_ID" ]]; then
            ARGS=$(docker exec "$CONTAINER" crictl inspect "$NEW_POD_ID" 2>/dev/null || true)
            if echo "$ARGS" | grep -q 'encryption-provider-config'; then
                log "kube-apiserver is healthy with KMS encryption enabled (${ELAPSED}s)"
                break
            fi
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
