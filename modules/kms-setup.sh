#!/usr/bin/env bash
# Configure Vault for vault-kube-kms:
#   1. Enable Transit engine
#   2. Create the KEK (transit/keys/kms)
#   3. Write the minimum-privilege policy
#   4. Enable AppRole auth
#   5. Create role + generate secret-id
#   6. Copy secret-id into kind node
#   7. Enable Vault audit log
set -euo pipefail

log()   { echo "[$(date +%H:%M:%S)] $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../scripts/detect-mode.sh"

LAB_STATE="$REPO_ROOT/.lab-state"
mkdir -p "$LAB_STATE"

KIND_CLUSTER_NAME="vault-kube-kms"
CONTAINER="${KIND_CLUSTER_NAME}-control-plane"
APPROLE_ROLE_NAME="kube-kms"
APPROLE_ROLE_ID="lab-kube-kms"
TRANSIT_MOUNT="transit"
KEY_NAME="kms"

log "=== KMS Setup | Mode: $VAULT_MODE ==="

# ── 1. Transit engine ─────────────────────────────────────────────────────
if vault secrets list -format=json | jq -e '."transit/"' >/dev/null 2>&1; then
	log "Transit engine already enabled at transit/"
else
	log "Enabling Transit engine at transit/"
	vault secrets enable -path="$TRANSIT_MOUNT" transit >/dev/null || \
		error "Failed to enable Transit engine"
fi

# ── 2. Create key ─────────────────────────────────────────────────────────────
if vault read -format=json "$TRANSIT_MOUNT/keys/$KEY_NAME" >/dev/null 2>&1; then
	log "Transit key '$KEY_NAME' already exists"
	CURRENT_VERSION="$(vault read -format=json "$TRANSIT_MOUNT/keys/$KEY_NAME" \
		| jq -r '.data.latest_version')"
	log "Current key version: $CURRENT_VERSION"
else
	log "Creating Transit key '$KEY_NAME' (type: aes256-gcm96)"
	vault write -f "$TRANSIT_MOUNT/keys/$KEY_NAME" >/dev/null || \
		error "Failed to create Transit key"
	CURRENT_VERSION=1
fi

# ── 3. Policy ─────────────────────────────────────────────────────────────────────
log "Writing policy 'transit-encrypt-decrypt'"
vault policy write transit-encrypt-decrypt \
	"$REPO_ROOT/config/kms-policy.hcl" >/dev/null || \
	error "Failed to write Vault policy"

# ── 4. AppRole ────────────────────────────────────────────────────────────────
if vault auth list -format=json | jq -e '."approle/"' >/dev/null 2>&1; then
	log "AppRole auth already enabled at approle/"
else
	log "Enabling AppRole auth at approle/"
	vault auth enable -path=approle approle >/dev/null || \
		error "Failed to enable AppRole"
fi

# ── 5. Role ───────────────────────────────────────────────────────────────────────
log "Configuring AppRole role '$APPROLE_ROLE_NAME' (role_id: $APPROLE_ROLE_ID)"
vault write "auth/approle/role/$APPROLE_ROLE_NAME" \
	role_id="$APPROLE_ROLE_ID" \
	token_policies="transit-encrypt-decrypt" \
	token_ttl="1h" \
	token_max_ttl="4h" >/dev/null || error "Failed to configure AppRole role"

# ── 6. Secret-id ───────────────────────────────────────────────────────────────
log "Generating AppRole secret-id..."
SECRET_ID="$(vault write -f -format=json \
	"auth/approle/role/$APPROLE_ROLE_NAME/secret-id" \
	| jq -r '.data.secret_id')"
[[ -n "$SECRET_ID" && "$SECRET_ID" != "null" ]] || \
	error "Failed to generate secret-id"

echo "$SECRET_ID"       > "$LAB_STATE/approle-secret-id"
echo "$APPROLE_ROLE_ID" > "$LAB_STATE/approle-role-id"
chmod 0400 "$LAB_STATE/approle-secret-id"
log "secret-id written to $LAB_STATE/approle-secret-id (mode 0400)"

# Copy secret-id into kind node (if cluster is up)
# Use /opt/kms/ — /tmp is a tmpfs in kind nodes and docker cp writes are not visible
if kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER_NAME}$"; then
	log "Copying secret-id into kind node: ${CONTAINER}:/opt/kms/approle-secret-id"
	docker exec "$CONTAINER" mkdir -p /opt/kms
	docker cp "$LAB_STATE/approle-secret-id" "${CONTAINER}:/opt/kms/approle-secret-id"
	docker exec "$CONTAINER" chmod 0400 /opt/kms/approle-secret-id
	log "secret-id deployed to kind node"
else
	log "kind cluster not yet up — secret-id will be copied by make deploy-kms"
fi

# ── 7. Audit log ───────────────────────────────────────────────────────────────
if vault audit list -format=json | jq -e '."file/"' >/dev/null 2>&1; then
	log "Audit log already enabled"
else
	log "Enabling audit log at /vault/logs/audit.log"
	mkdir -p "$LAB_STATE/logs"
	vault audit enable file file_path=/vault/logs/audit.log >/dev/null || \
		log "WARNING: Could not enable audit log (non-fatal for lab)"
fi

echo ""
echo "┌─────────────────────────────────────────────────────┐"
echo "│  KMS Setup Complete                                 │"
echo "├─────────────────────────────────────────────────────┤"
printf "│  Transit mount:  %-35s│\n" "$TRANSIT_MOUNT/"
printf "│  Key name:       %-35s│\n" "$KEY_NAME  (version $CURRENT_VERSION)"
printf "│  Key path flag:  %-35s│\n" "--vault-key-path=$TRANSIT_MOUNT/keys/$KEY_NAME"
printf "│  AppRole role:   %-35s│\n" "$APPROLE_ROLE_NAME  (id: $APPROLE_ROLE_ID)"
printf "│  Policy:         %-35s│\n" "transit-encrypt-decrypt"
echo "└─────────────────────────────────────────────────────┘"
echo ""
log "Next: make deploy-kms  (if kind is already up)"
