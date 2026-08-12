#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date +%H:%M:%S)] $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/detect-mode.sh"

VAULT_HEALTH_URL="http://127.0.0.1:8200/v1/sys/health"
TIMEOUT_SECONDS=60
INTERVAL_SECONDS=2
elapsed=0

while (( elapsed < TIMEOUT_SECONDS )); do
	http_code="$(curl -s -o /dev/null -w "%{http_code}" "$VAULT_HEALTH_URL" || true)"
	if [[ "$http_code" != "000" ]]; then
		log "Vault is reachable (HTTP $http_code)"
		exit 0
	fi
	sleep "$INTERVAL_SECONDS"
	elapsed=$((elapsed + INTERVAL_SECONDS))
done

error "Vault did not start within ${TIMEOUT_SECONDS}s.
Check logs with: docker compose logs vault-enterprise"
