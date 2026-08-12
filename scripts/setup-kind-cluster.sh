#!/usr/bin/env bash
# Create the kind cluster and detect the Docker bridge gateway address
# that the KMS plugin (running inside kind) will use to reach Vault (on host).
set -euo pipefail

log()   { echo "[$(date +%H:%M:%S)] $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LAB_STATE="$REPO_ROOT/.lab-state"
mkdir -p "$LAB_STATE"

KIND_CLUSTER_NAME="vault-kube-kms"
KIND_CONFIG="$REPO_ROOT/k8s/kind-config.yaml"

if kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER_NAME}$"; then
	log "kind cluster '${KIND_CLUSTER_NAME}' already exists — skipping create"
else
	log "Creating kind cluster '${KIND_CLUSTER_NAME}' (k8s v1.33.1)..."
	(cd "$REPO_ROOT" && kind create cluster \
		--name "$KIND_CLUSTER_NAME" \
		--config "$KIND_CONFIG" \
		--wait 5m)
fi

kubectl config use-context "kind-${KIND_CLUSTER_NAME}"
log "kubectl context set to kind-${KIND_CLUSTER_NAME}"

detect_vault_addr() {
	local container="${KIND_CLUSTER_NAME}-control-plane"
	if docker exec "$container" sh -c 'getent hosts host.docker.internal' >/dev/null 2>&1; then
		echo "http://host.docker.internal:8200"
		return 0
	fi
	local gw
	gw="$(docker network inspect bridge 2>/dev/null | jq -r '.[0].IPAM.Config[0].Gateway' 2>/dev/null || true)"
	if [[ -n "$gw" && "$gw" != "null" ]]; then
		echo "http://${gw}:8200"
		return 0
	fi
	echo "http://172.17.0.1:8200"
}

VAULT_ADDR_FROM_KIND="$(detect_vault_addr)"
echo "$VAULT_ADDR_FROM_KIND" > "$LAB_STATE/vault-addr"
log "Vault address from inside kind: $VAULT_ADDR_FROM_KIND"
log "Saved to: $LAB_STATE/vault-addr"

CONTAINER="${KIND_CLUSTER_NAME}-control-plane"
log "Installing etcdctl inside kind node (via apt)..."
docker exec "$CONTAINER" sh -c '
	if command -v etcdctl >/dev/null 2>&1; then
		echo "etcdctl already installed: $(etcdctl version 2>&1 | head -1)"
		exit 0
	fi
	apt-get update -qq && apt-get install -y -qq etcd-client && apt-get clean -qq
	echo "etcdctl installed: $(etcdctl version 2>&1 | head -1)"
'

log "kind cluster ready."
log "Run: make build-kms-binary  ->  make deploy-kms  ->  make enable-encryption"
