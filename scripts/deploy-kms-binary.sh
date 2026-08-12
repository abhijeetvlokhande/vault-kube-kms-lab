#!/usr/bin/env bash
# Copy the vault-kube-kms binary into the kind node and start it as a
# background process. This mirrors the upstream DEPLOY_STANDALONE_BINARY=true
# path used by the integration tests.
set -euo pipefail

log()   { echo "[$(date +%H:%M:%S)] $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LAB_STATE="$REPO_ROOT/.lab-state"

KIND_CLUSTER_NAME="vault-kube-kms"
CONTAINER="${KIND_CLUSTER_NAME}-control-plane"
BINARY_SRC="$LAB_STATE/vault-kube-kms"
BINARY_DEST="/opt/kms/vault-kube-kms"
SECRET_ID_SRC="$LAB_STATE/approle-secret-id"
SECRET_ID_DEST="/tmp/approle-secret-id"
VAULT_KEY_PATH="transit/keys/kms"
LOG_FILE="/var/log/kms.log"
SOCKET_PATH="/tmp/vault-kube-kms.socket"

[[ -f "$BINARY_SRC" ]] || \
	error "Binary not found at $BINARY_SRC. Run: make build-kms-binary"

[[ -s "$SECRET_ID_SRC" ]] || \
	error "AppRole secret-id not found at $SECRET_ID_SRC. Run: ./vault-demo kms-setup"

VAULT_ADDR_FILE="$LAB_STATE/vault-addr"
[[ -f "$VAULT_ADDR_FILE" ]] || \
	error "Vault address file not found at $VAULT_ADDR_FILE. Run: make setup-k8s"
VAULT_ADDR_FROM_KIND="$(cat "$VAULT_ADDR_FILE")"

ROLE_ID_FILE="$LAB_STATE/approle-role-id"
[[ -f "$ROLE_ID_FILE" ]] || \
	error "AppRole role-id not found at $ROLE_ID_FILE. Run: ./vault-demo kms-setup"
APPROLE_ROLE_ID="$(cat "$ROLE_ID_FILE")"

log "Stopping any existing vault-kube-kms process..."
docker exec "$CONTAINER" pkill -x vault-kube-kms 2>/dev/null || true
sleep 1

log "Copying binary to ${CONTAINER}:${BINARY_DEST}  ($(du -sh "$BINARY_SRC" | cut -f1))"
docker exec "$CONTAINER" mkdir -p "$(dirname "$BINARY_DEST")"
docker cp "$BINARY_SRC" "${CONTAINER}:${BINARY_DEST}"
docker exec "$CONTAINER" chmod +x "$BINARY_DEST"

log "Copying AppRole secret-id to ${CONTAINER}:${SECRET_ID_DEST}"
docker cp "$SECRET_ID_SRC" "${CONTAINER}:${SECRET_ID_DEST}"
docker exec "$CONTAINER" chmod 0400 "$SECRET_ID_DEST"

log "Starting vault-kube-kms plugin..."
log "  --vault-address=$VAULT_ADDR_FROM_KIND"
log "  --vault-key-path=$VAULT_KEY_PATH"
log "  --approle-role-id=$APPROLE_ROLE_ID"
log "  --tls-skip-verify (LAB ONLY — never use in production)"

docker exec -d "$CONTAINER" sh -c "
	${BINARY_DEST} \\
	  --vault-address=${VAULT_ADDR_FROM_KIND} \\
	  --vault-key-path=${VAULT_KEY_PATH} \\
	  --approle-role-id=${APPROLE_ROLE_ID} \\
	  --approle-secret-id-path=${SECRET_ID_DEST} \\
	  --listen-address=unix://${SOCKET_PATH} \\
	  --tls-skip-verify \\
	  --metrics-port=9090 \\
	  --health-port=8081 \\
	  --zap-log-level=info \\
	  2>&1 | tee -a ${LOG_FILE}
"

log "Waiting for socket at ${SOCKET_PATH}..."
for i in $(seq 1 30); do
	if docker exec "$CONTAINER" test -S "$SOCKET_PATH" 2>/dev/null; then
		log "Plugin socket ready after ${i}x2s"
		break
	fi
	if [[ "$i" -eq 30 ]]; then
		log "Socket not found after 60s. Last log lines:"
		docker exec "$CONTAINER" tail -20 "$LOG_FILE" 2>/dev/null || true
		error "vault-kube-kms did not start. Check logs: make logs"
	fi
	sleep 2
done

log "Checking /readyz health endpoint..."
for i in $(seq 1 15); do
	if docker exec "$CONTAINER" sh -c \
		'curl -sf http://127.0.0.1:8081/readyz' >/dev/null 2>&1; then
		log "Plugin is ready (/readyz returned 200)"
		break
	fi
	if [[ "$i" -eq 15 ]]; then
		log "Plugin /readyz not healthy. Last log lines:"
		docker exec "$CONTAINER" tail -20 "$LOG_FILE" 2>/dev/null || true
		error "Plugin health check failed. Check logs: make logs"
	fi
	sleep 2
done

log "vault-kube-kms deployed and running."
log "View logs: make logs"
log "Next step: make enable-encryption"
