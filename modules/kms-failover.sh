#!/usr/bin/env bash
# Demonstrate KMS v2 resilience behaviour when Vault goes down.
#
# KMS v2 difference from KMS v1:
#   - The API server caches the DEK seed in memory after startup
#   - Existing READS survive a Vault outage (seed already in memory)
#   - New WRITES fail (new DEK seed requires Vault for encryption)
#
# This is the "write availability is the HA requirement" story.
set -euo pipefail

log()   { echo "[$(date +%H:%M:%S)] $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }
pass()  { echo "[$(date +%H:%M:%S)] \u2713  $*"; }
warn()  { echo "[$(date +%H:%M:%S)] \u26a0  $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../scripts/detect-mode.sh"

KIND_CLUSTER_NAME="vault-kube-kms"
COMPOSE_PROJECT="vault-kms-lab"
COMPOSE_FILE="$REPO_ROOT/docker-compose.yml"

log "=== KMS Failover | Mode: $VAULT_MODE ==="

EXISTING_VALUE="pre-failover-$(date +%s)"
kubectl delete secret kms-failover-existing --ignore-not-found >/dev/null
kubectl create secret generic kms-failover-existing \
	--from-literal="value=$EXISTING_VALUE" >/dev/null
log "Pre-failover secret written: '$EXISTING_VALUE'"

echo ""
warn "Stopping Vault Enterprise (simulating outage)..."
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" \
	--profile enterprise stop vault-enterprise
log "Vault is DOWN."
sleep 2

log "Testing: read of existing secret (should SUCCEED — DEK seed cached)..."
DECODED="$(kubectl get secret kms-failover-existing \
	-o jsonpath='{.data.value}' | base64 -d 2>/dev/null || echo "FAILED")"
if [[ "$DECODED" == "$EXISTING_VALUE" ]]; then
	pass "Read SUCCEEDED while Vault is down — KMS v2 DEK-seed caching works"
	echo "  Decoded value: '$DECODED'"
else
	warn "Read returned: '$DECODED' (may have failed — check if API server restarted)"
fi

log "Testing: new write (should FAIL — Vault unreachable for encrypt)..."
kubectl delete secret kms-failover-new --ignore-not-found >/dev/null 2>&1 || true
if kubectl create secret generic kms-failover-new \
	--from-literal="value=shouldfail" 2>&1 | grep -q -i 'error\|failed\|timeout\|timed out\|unable'; then
	pass "New write FAILED as expected (Vault unreachable)"
elif kubectl create secret generic kms-failover-new \
	--from-literal="value=shouldfail" >/dev/null 2>&1; then
	warn "New write SUCCEEDED — the API server may still have a valid cached connection"
	warn "KMS v2 behaviour: the timeout is 3s (encryption-config.yaml). Try again."
fi

echo ""
warn "Vault is still DOWN. Only new writes fail. Existing secrets remain readable."
echo "  This is why Vault HA is a write-availability requirement, not read-availability."
echo ""
read -r -p "  Press ENTER to restart Vault and show recovery..." || true
echo ""

log "Restarting Vault Enterprise..."
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" \
	--profile enterprise start vault-enterprise

log "Waiting for Vault to come back up..."
for i in $(seq 1 30); do
	http_code="$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8200/v1/sys/health || true)"
	if [[ "$http_code" != "000" ]]; then
		log "Vault reachable (HTTP $http_code)"
		break
	fi
	[[ "$i" -eq 30 ]] && error "Vault did not come back within 60s"
	sleep 2
done

log "Unsealing Vault (Shamir, 3 keys)..."
"$SCRIPT_DIR/../scripts/init-vault.sh"

log "Testing: new write after Vault recovery (should SUCCEED)..."
sleep 3
kubectl delete secret kms-failover-new --ignore-not-found >/dev/null 2>&1 || true
RECOVERY_VALUE="post-recovery-$(date +%s)"
if kubectl create secret generic kms-failover-new \
	--from-literal="value=$RECOVERY_VALUE" >/dev/null 2>&1; then
	DECODED_NEW="$(kubectl get secret kms-failover-new \
		-o jsonpath='{.data.value}' | base64 -d)"
	pass "New write SUCCEEDED after recovery: '$DECODED_NEW'"
else
	warn "New write still failing — plugin may need a moment to re-authenticate."
	warn "Check: make logs  (look for 'Vault KMS server initialized successfully')"
fi

DECODED_EXISTING="$(kubectl get secret kms-failover-existing \
	-o jsonpath='{.data.value}' | base64 -d)"
[[ "$DECODED_EXISTING" == "$EXISTING_VALUE" ]] && \
	pass "Pre-failover secret still readable after recovery: '$DECODED_EXISTING'"

echo ""
echo "┌──────────────────────────────────────────────────────────────┐"
echo "│  Failover Demo Summary                                       │"
echo "├──────────────────────────────────────────────────────────────┤"
echo "│  Vault DOWN: existing reads SUCCEED  (KMS v2 DEK cache)      │"
echo "│  Vault DOWN: new writes FAIL         (3s timeout)            │"
echo "│  Vault UP:   all operations SUCCEED  (plugin re-authed)      │"
echo "└──────────────────────────────────────────────────────────────┘"
echo ""
log "Vault HA requirement: write availability, not read availability."

kubectl delete secret kms-failover-existing kms-failover-new \
	--ignore-not-found >/dev/null 2>&1 || true
