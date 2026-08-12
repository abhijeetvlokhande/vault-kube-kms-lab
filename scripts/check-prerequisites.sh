#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date +%H:%M:%S)] $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }
ok()    { echo "[$(date +%H:%M:%S)] \u2713  $*"; }
fail()  { echo "[FAIL] $*" >&2; exit 1; }

log "Checking prerequisites..."

check_cmd() {
	local cmd="$1" hint="$2"
	if ! command -v "$cmd" >/dev/null 2>&1; then
		fail "'$cmd' not found. Install with: $hint"
	fi
	ok "$cmd  ($(command -v "$cmd"))"
}

check_cmd docker      "Docker Desktop — https://docs.docker.com/desktop/"
check_cmd kind        "brew install kind"
check_cmd kubectl     "brew install kubectl"
check_cmd go          "brew install go"
check_cmd vault       "brew install hashicorp/tap/vault"
check_cmd jq          "brew install jq"
check_cmd curl        "brew install curl"

if ! docker info >/dev/null 2>&1; then
	fail "Docker daemon is not running. Start Docker Desktop first."
fi
ok "Docker daemon is running"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LICENSE_FILE="$REPO_ROOT/License/vault.hclic"

if [[ -n "${VAULT_LICENSE:-}" ]]; then
	ok "VAULT_LICENSE is set in environment"
elif [[ -f "$LICENSE_FILE" && -s "$LICENSE_FILE" ]]; then
	ok "License file present: $LICENSE_FILE"
else
	fail "No Vault Enterprise license found.
Export VAULT_LICENSE or place your license in License/vault.hclic"
fi

log "All prerequisites satisfied."
