#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date +%H:%M:%S)] $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/detect-mode.sh"

INIT_FILE="$REPO_ROOT/.vault-init.json"
INIT_TMP_FILE="$REPO_ROOT/.vault-init.json.tmp"

init_file_has_required_fields() {
	local file_path="$1"
	[[ -s "$file_path" ]] || return 1
	jq -e '
		(.unseal_keys_b64 | type == "array" and length >= 3) and
		(.unseal_keys_b64[0] | type == "string" and length > 0) and
		(.unseal_keys_b64[1] | type == "string" and length > 0) and
		(.unseal_keys_b64[2] | type == "string" and length > 0) and
		(.root_token | type == "string" and length > 0)
	' "$file_path" >/dev/null 2>&1
}

vault_storage_is_initialized() {
	local status_json
	status_json="$(vault status -format=json 2>/dev/null || true)"
	[[ -n "$status_json" ]] || return 1
	jq -e '.initialized == true' >/dev/null 2>&1 <<< "$status_json"
}

if [[ -f "$INIT_FILE" ]]; then
	if init_file_has_required_fields "$INIT_FILE"; then
		log "Already initialized — loading existing keys"
	elif vault_storage_is_initialized; then
		error "Vault storage is already initialized, but $INIT_FILE is empty or invalid.
Restore a valid $INIT_FILE or reset with: make enterprise-reset"
	else
		log "Ignoring empty or invalid $INIT_FILE (storage not yet initialized)"
		rm -f "$INIT_FILE"
	fi
fi

if [[ ! -f "$INIT_FILE" ]]; then
	log "Initializing Vault..."
	rm -f "$INIT_TMP_FILE"
	if ! vault operator init -format=json > "$INIT_TMP_FILE"; then
		rm -f "$INIT_TMP_FILE"
		if vault_storage_is_initialized; then
			error "Vault storage is already initialized but no valid init file at $INIT_FILE.
Restore the original init file or reset with: make enterprise-reset"
		fi
		error "Vault initialization failed"
	fi
	mv "$INIT_TMP_FILE" "$INIT_FILE"
fi

if ! unseal_key_1="$(jq -r '.unseal_keys_b64[0]' "$INIT_FILE")"; then error "Failed to parse unseal key 1"; fi
if ! unseal_key_2="$(jq -r '.unseal_keys_b64[1]' "$INIT_FILE")"; then error "Failed to parse unseal key 2"; fi
if ! unseal_key_3="$(jq -r '.unseal_keys_b64[2]' "$INIT_FILE")"; then error "Failed to parse unseal key 3"; fi
if ! root_token="$(jq -r '.root_token' "$INIT_FILE")"; then error "Failed to parse root token"; fi

if [[ -z "$unseal_key_1" || "$unseal_key_1" == "null" ||
      -z "$unseal_key_2" || "$unseal_key_2" == "null" ||
      -z "$unseal_key_3" || "$unseal_key_3" == "null" ||
      -z "$root_token"   || "$root_token"   == "null" ]]; then
	error "Initialization data in $INIT_FILE is incomplete"
fi

log "Unsealing Vault (1/3)..."
vault operator unseal "$unseal_key_1" >/dev/null || error "Unseal step 1 failed"
log "Unsealing Vault (2/3)..."
vault operator unseal "$unseal_key_2" >/dev/null || error "Unseal step 2 failed"
log "Unsealing Vault (3/3)..."
vault operator unseal "$unseal_key_3" >/dev/null || error "Unseal step 3 failed"

vault login "$root_token" >/dev/null || error "Vault login failed after unseal"
export VAULT_TOKEN="$root_token"
log "Vault initialized, unsealed, and ready"
