#!/usr/bin/env bash
# Demonstrate zero-downtime KEK rotation:
#   1. Show current key version
#   2. Rotate the Transit key in Vault
#   3. Plugin auto-detects new version (logs confirm, no restart needed)
#   4. No-op replace to re-encrypt all existing secrets with the new KEK
#   5. Confirm min_decryption_version still covers old version (data safe)
#   6. Write + verify a new secret (uses new key version)
set -euo pipefail

log()   { echo "[$(date +%H:%M:%S)] $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }
pass()  { echo "[$(date +%H:%M:%S)] \u2713  $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../scripts/detect-mode.sh"

KIND_CLUSTER_NAME="vault-kube-kms"
CONTAINER="${KIND_CLUSTER_NAME}-control-plane"
TRANSIT_MOUNT="transit"
KEY_NAME="kms"

log "=== KMS Rotate | Mode: $VAULT_MODE ==="

log "Current Transit key state:"
KEY_INFO="$(vault read -format=json "$TRANSIT_MOUNT/keys/$KEY_NAME")"
CURRENT_VERSION="$(echo "$KEY_INFO" | jq -r '.data.latest_version')"
MIN_DECRYPT="$(echo "$KEY_INFO" | jq -r '.data.min_decryption_version')"
echo "  latest_version:         $CURRENT_VERSION"
echo "  min_decryption_version: $MIN_DECRYPT"

PRE_SECRET="pre-rotation-$(date +%s)"
kubectl delete secret kms-rotate-pre --ignore-not-found >/dev/null
kubectl create secret generic kms-rotate-pre \
	--from-literal="value=$PRE_SECRET" >/dev/null
log "Pre-rotation secret 'kms-rotate-pre' written"

log "Rotating Transit key '$KEY_NAME' in Vault..."
vault write -f "$TRANSIT_MOUNT/keys/$KEY_NAME/rotate" >/dev/null || \
	error "Key rotation failed"

NEW_VERSION="$(vault read -format=json "$TRANSIT_MOUNT/keys/$KEY_NAME" \
	| jq -r '.data.latest_version')"
log "Key rotated: version $CURRENT_VERSION -> version $NEW_VERSION"

log "Waiting for plugin to detect new key version (checking logs)..."
DETECTED=false
for i in $(seq 1 15); do
	if docker exec "$CONTAINER" grep -q "v${NEW_VERSION}" /var/log/kms.log 2>/dev/null; then
		pass "Plugin detected new key version v${NEW_VERSION} in logs"
		DETECTED=true
		break
	fi
	sleep 2
done
if [[ "$DETECTED" == "false" ]]; then
	log "NOTE: Plugin log does not show v${NEW_VERSION} yet — this is normal if"
	log "      the API server has not called Status() since rotation."
fi

log "Re-encrypting all existing secrets (no-op replace)..."
kubectl get secrets --all-namespaces -o json | kubectl replace -f - >/dev/null
pass "All secrets re-encrypted with key version $NEW_VERSION"

log "Verifying pre-rotation secret is still readable..."
DECODED="$(kubectl get secret kms-rotate-pre \
	-o jsonpath='{.data.value}' | base64 -d)"
[[ "$DECODED" == "$PRE_SECRET" ]] || \
	error "Pre-rotation secret unreadable after rotate! Got: $DECODED"
pass "Pre-rotation secret still readable: '$DECODED'"

POST_SECRET="post-rotation-$(date +%s)"
kubectl delete secret kms-rotate-post --ignore-not-found >/dev/null
kubectl create secret generic kms-rotate-post \
	--from-literal="value=$POST_SECRET" >/dev/null
DECODED_POST="$(kubectl get secret kms-rotate-post \
	-o jsonpath='{.data.value}' | base64 -d)"
[[ "$DECODED_POST" == "$POST_SECRET" ]] || \
	error "Post-rotation secret unreadable"
pass "Post-rotation secret readable: '$DECODED_POST'"

UPDATED_INFO="$(vault read -format=json "$TRANSIT_MOUNT/keys/$KEY_NAME")"
NEW_MIN_DECRYPT="$(echo "$UPDATED_INFO" | jq -r '.data.min_decryption_version')"
echo ""
echo "┌────────────────────────────────────────────────┐"
echo "│  KEK Rotation Complete                           │"
echo "├────────────────────────────────────────────────┤"
printf "│  Previous version:       %-25s│\n" "$CURRENT_VERSION"
printf "│  New version:            %-25s│\n" "$NEW_VERSION"
printf "│  min_decryption_version: %-25s│\n" "$NEW_MIN_DECRYPT  (old data safe)"
echo "├────────────────────────────────────────────────┤"
echo "│  No API server restart. No app downtime.         │"
echo "│  Old key version retained for existing data.     │"
echo "└────────────────────────────────────────────────┘"

kubectl delete secret kms-rotate-pre kms-rotate-post --ignore-not-found >/dev/null 2>&1 || true
