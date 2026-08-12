#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date +%H:%M:%S)] $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/detect-mode.sh"

log "Starting Vault Enterprise..."
compose_file="$REPO_ROOT/docker-compose.yml"

echo "enterprise" > "$REPO_ROOT/.vault-mode"

if ! docker compose -f "$compose_file" -p vault-kms-lab \
     --profile enterprise up -d vault-enterprise; then
	error "Failed to start vault-enterprise container"
fi

if ! "$SCRIPT_DIR/wait-for-vault.sh"; then
	error "Vault did not become reachable"
fi

if ! "$SCRIPT_DIR/init-vault.sh"; then
	error "Vault initialization/unseal failed"
fi

log "Vault Enterprise is up, initialized, and unsealed."
log "Vault UI: http://127.0.0.1:8200"
log "Root token stored in: $REPO_ROOT/.vault-init.json"
log ""
log "Next step: ./vault-demo kms-setup (configure Transit + AppRole)"
