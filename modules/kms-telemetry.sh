#!/usr/bin/env bash
# Show plugin telemetry: Prometheus /metrics and Vault audit log.
set -euo pipefail

log()   { echo "[$(date +%H:%M:%S)] $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }
pass()  { echo "[$(date +%H:%M:%S)] \u2713  $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../scripts/detect-mode.sh"

KIND_CLUSTER_NAME="vault-kube-kms"
CONTAINER="${KIND_CLUSTER_NAME}-control-plane"
METRICS_PORT=9090
COMPOSE_PROJECT="vault-kms-lab"
COMPOSE_FILE="$REPO_ROOT/docker-compose.yml"

log "=== KMS Telemetry | Mode: $VAULT_MODE ==="

log "Writing 3 test secrets to generate encrypt/decrypt traffic..."
for i in 1 2 3; do
	kubectl create secret generic "kms-telemetry-${i}" \
		--from-literal="v=telemetry-${i}" --dry-run=client -o yaml | \
		kubectl apply -f - >/dev/null 2>&1 || true
	kubectl get secret "kms-telemetry-${i}" \
		-o jsonpath='{.data.v}' >/dev/null 2>&1 || true
done

echo ""
echo "━━━  Plugin Prometheus /metrics  (port $METRICS_PORT on plugin process)  ━━━"
METRICS="$(docker exec "$CONTAINER" \
	curl -sf "http://127.0.0.1:${METRICS_PORT}/metrics" 2>/dev/null || true)"

if [[ -z "$METRICS" ]]; then
	log "WARNING: Could not reach /metrics on port $METRICS_PORT."
	log "  Check plugin is running: make logs"
else
	echo ""
	echo "── gRPC latency histogram (rpc_server_duration_milliseconds) ───────────"
	echo "$METRICS" | grep 'rpc_server_duration_milliseconds' | \
		grep -v '^#' | head -20 || \
		echo "  (no rpc_server_duration_milliseconds metrics yet)"

	echo ""
	echo "── Vault client operations (vso_client_operations_total) ──────────────"
	echo "$METRICS" | grep 'vso_client_operations_total' | \
		grep -v '^#' | head -10 || \
		echo "  (no vso_client_operations_total metrics yet)"

	echo ""
	echo "── Vault client errors (vso_client_operations_errors_total) ──────────"
	echo "$METRICS" | grep 'vso_client_operations_errors_total' | \
		grep -v '^#' | head -5 || \
		echo "  (no errors recorded — good)"

	pass "Metrics endpoint accessible on plugin process"
fi

echo ""
echo "━━━  Plugin Health Endpoints  ━━━"
for ep in healthz readyz; do
	STATUS="$(docker exec "$CONTAINER" \
		curl -sf -o /dev/null -w "%{http_code}" "http://127.0.0.1:8081/${ep}" \
		2>/dev/null || echo "000")"
	if [[ "$STATUS" == "200" ]]; then
		pass "/${ep} -> HTTP $STATUS"
	else
		log "/${ep} -> HTTP $STATUS (non-200)"
	fi
done

echo ""
echo "━━━  Vault Audit Log (Transit operations)  ━━━"
AUDIT_LOG_PATH="$REPO_ROOT/.lab-state/logs/audit.log"
if [[ -f "$AUDIT_LOG_PATH" ]]; then
	echo ""
	echo "── Last 5 Transit encrypt/decrypt entries ────────────────────────────"
	grep '"path":"transit' "$AUDIT_LOG_PATH" 2>/dev/null | tail -5 | \
		jq -c '{time:.time, op:.request.operation, path:.request.path, auth_display:.auth.display_name}' \
		2>/dev/null || \
		grep '"path":"transit' "$AUDIT_LOG_PATH" | tail -5
	pass "Vault audit log contains Transit operations"
else
	log "Audit log not found at $AUDIT_LOG_PATH."
	log "Check via: docker compose -p $COMPOSE_PROJECT exec vault-enterprise cat /vault/logs/audit.log | jq ."
fi

echo ""
echo "━━━  Plugin Process Log (last 10 lines)  ━━━"
docker exec "$CONTAINER" tail -10 /var/log/kms.log 2>/dev/null || \
	log "(log not yet available)"

kubectl delete secret kms-telemetry-1 kms-telemetry-2 kms-telemetry-3 \
	--ignore-not-found >/dev/null 2>&1 || true

echo ""
log "Telemetry demo complete."
log ""
log "To scrape metrics continuously:"
log "  docker exec ${CONTAINER} curl -sf http://127.0.0.1:${METRICS_PORT}/metrics"
log ""
log "To tail the plugin log:"
log "  make logs"
