#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date +%H:%M:%S)] $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }

DETECT_MODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$DETECT_MODE_DIR/.." && pwd)"
MODE_FILE="$REPO_ROOT/.vault-mode"
DEFAULT_LICENSE_FILE="$REPO_ROOT/License/vault.hclic"

load_vault_license() {
	if [[ -n "${VAULT_LICENSE:-}" ]]; then
		export VAULT_LICENSE_SOURCE="environment"
		return 0
	fi

	if [[ -f "$DEFAULT_LICENSE_FILE" ]]; then
		local license_value
		license_value="$(tr -d '\r' < "$DEFAULT_LICENSE_FILE")"
		license_value="${license_value%$'\n'}"
		if [[ -n "$license_value" ]]; then
			export VAULT_LICENSE="$license_value"
			export VAULT_LICENSE_SOURCE="$DEFAULT_LICENSE_FILE"
			return 0
		fi
	fi

	return 1
}

# This lab is enterprise-only. Dev mode would be rejected by vault-kube-kms
# at startup because it validates sys/license/status.
if [[ -f "$MODE_FILE" ]]; then
	VAULT_MODE="$(tr -d '[:space:]' < "$MODE_FILE")"
else
	VAULT_MODE="enterprise"
fi

if [[ "$VAULT_MODE" != "enterprise" ]]; then
	error "vault-kms-kubernetes-lab requires Vault Enterprise.
vault-kube-kms validates sys/license/status at startup and exits if it
connects to a Community Edition instance.
Run: ./scripts/start-vault.sh enterprise"
fi

export VAULT_MODE
export VAULT_IMAGE="hashicorp/vault-enterprise:1.17.3-ent"
export VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
export REPO_ROOT

if load_vault_license; then
	if [[ "$VAULT_LICENSE_SOURCE" != "environment" ]]; then
		log "Loaded Vault Enterprise license from $VAULT_LICENSE_SOURCE"
	fi
else
	echo "WARNING: No Vault Enterprise license found.
Checked VAULT_LICENSE and $DEFAULT_LICENSE_FILE.
vault-kube-kms will fail to start without a valid Enterprise license."
fi

log "Running in $VAULT_MODE mode"
