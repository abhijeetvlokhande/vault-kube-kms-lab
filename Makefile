.DEFAULT_GOAL := help

SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c

LAB_BINARY := .lab-state/vault-kube-kms

.PHONY: help
help:
	@echo "Vault KMS on Kubernetes — Lab"
	@echo "────────────────────────────────────────────────────────────────"
	@echo "Startup (run in order):"
	@echo "  make enterprise          Start Vault Enterprise (reads License/vault.hclic)"
	@echo "  make setup-k8s           Create kind cluster (k8s v1.33.1) + detect gateway"
	@echo "  make build-kms-binary    Clone vault-kube-kms + cross-compile Linux binary"
	@echo "  make deploy-kms          Copy binary into kind node + start plugin"
	@echo "  make enable-encryption   Patch kube-apiserver + wait for healthy restart"
	@echo ""
	@echo "  make bootstrap           Run all 5 startup steps in sequence"
	@echo ""
	@echo "Demo:"
	@echo "  ./vault-demo kms-setup   Configure Vault: Transit + AppRole + policy"
	@echo "  ./vault-demo kms-verify  Prove etcd encryption with etcdctl"
	@echo "  ./vault-demo kms-rotate  Zero-downtime KEK rotation"
	@echo "  ./vault-demo kms-failover  Vault outage resilience story"
	@echo "  ./vault-demo kms-telemetry Prometheus metrics + Vault audit log"
	@echo "  ./vault-demo all         Run all demo modules in sequence"
	@echo ""
	@echo "Validation:"
	@echo "  make verify-assumptions  Prove source-derived claims against binary"
	@echo ""
	@echo "Operations:"
	@echo "  make logs                Tail vault-kube-kms plugin log"
	@echo "  make status              Vault + kind + plugin status"
	@echo "  make clean               Tear down everything"
	@echo "  make enterprise-reset    Reset Vault raft state"
	@echo "────────────────────────────────────────────────────────────────"

# ── Startup ────────────────────────────────────────────────────────────────────────

.PHONY: enterprise
enterprise:
	@echo ">>> Starting Vault Enterprise..."
	@./scripts/start-vault.sh

.PHONY: setup-k8s
setup-k8s:
	@echo ">>> Creating kind cluster and detecting bridge gateway..."
	@./scripts/setup-kind-cluster.sh

.PHONY: build-kms-binary
build-kms-binary:
	@echo ">>> Building vault-kube-kms Linux binary..."
	@./scripts/build-kms-binary.sh

.PHONY: deploy-kms
deploy-kms:
	@echo ">>> Deploying KMS plugin binary into kind node..."
	@./scripts/deploy-kms-binary.sh

.PHONY: enable-encryption
enable-encryption:
	@echo ">>> Patching kube-apiserver to enable KMS encryption..."
	@./scripts/enable-encryption.sh

.PHONY: bootstrap
bootstrap:
	@echo ">>> Running full bootstrap: Vault → k8s → binary → deploy → encrypt..."
	@$(MAKE) enterprise
	@./vault-demo kms-setup
	@$(MAKE) setup-k8s
	@$(MAKE) build-kms-binary
	@$(MAKE) deploy-kms
	@$(MAKE) enable-encryption
	@echo ">>> Bootstrap complete. Run: ./vault-demo kms-verify"

# ── Validation ─────────────────────────────────────────────────────────────────

.PHONY: verify-assumptions
verify-assumptions: build-kms-binary
	@echo ""
	@echo "━━━  verify-assumptions: checking source-derived claims against binary  ━━━"
	@echo ""
	@# ── Check 1: --vault-key-path flag exists ──────────────────────────────
	@echo "[1/4] --vault-key-path flag exists in binary..."
	@$(LAB_BINARY) --help 2>&1 | grep -q 'vault-key-path' || \
		(echo "FAIL: --vault-key-path not found in binary --help" && exit 1)
	@echo "  PASS: --vault-key-path present"
	@echo ""
	@# ── Check 2: No standalone --transit-mount/--transit-key flags ───────────
	@echo "[2/4] --transit-mount and --transit-key absent as standalone flags..."
	@HITS=$$($(LAB_BINARY) --help 2>&1 | grep -E '\-transit-(mount|key)' | \
		grep -v 'deprecated' || true); \
	[ -z "$$HITS" ] || \
		(echo "FAIL: legacy --transit-mount or --transit-key exist as standalone flags:" && \
		 echo "$$HITS" && exit 1)
	@echo "  PASS: no standalone --transit-mount or --transit-key flags"
	@echo ""
	@# ── Check 3: Default socket path ────────────────────────────────────
	@echo "[3/4] Default socket is unix:///tmp/vault-kube-kms.socket..."
	@$(LAB_BINARY) --help 2>&1 | grep -q 'vault-kube-kms.socket' || \
		(echo "FAIL: default socket path does not contain 'vault-kube-kms.socket'" && exit 1)
	@echo "  PASS: default socket is unix:///tmp/vault-kube-kms.socket"
	@echo ""
	@# ── Check 4: Live etcd prefix (requires running cluster) ───────────────
	@echo "[4/4] Live etcd prefix check (run after kms-verify, skip if cluster not up)..."
	@if kind get clusters 2>/dev/null | grep -q '^vault-kube-kms$$'; then \
		CONTAINER="vault-kube-kms-control-plane"; \
		kubectl create secret generic va-check-$$(date +%s) \
			--from-literal=x=y --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1 || true; \
		ETCD_OUT=$$(docker exec $$CONTAINER \
			etcdctl --endpoints=https://127.0.0.1:2379 \
			  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
			  --cert=/etc/kubernetes/pki/etcd/server.crt \
			  --key=/etc/kubernetes/pki/etcd/server.key \
			  get /registry/secrets/default/ --prefix --keys-only 2>/dev/null | head -1 || true); \
		if [ -n "$$ETCD_OUT" ]; then \
			FIRST_SECRET=$$(echo $$ETCD_OUT | awk '{print $$1}'); \
			docker exec $$CONTAINER \
				etcdctl --endpoints=https://127.0.0.1:2379 \
				  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
				  --cert=/etc/kubernetes/pki/etcd/server.crt \
				  --key=/etc/kubernetes/pki/etcd/server.key \
				  get "$$FIRST_SECRET" 2>/dev/null | grep -q 'k8s:enc:kms:v2:vault-kube-kms:' || \
				  (echo "FAIL: etcd prefix does not match k8s:enc:kms:v2:vault-kube-kms:" && exit 1); \
			echo "  PASS: etcd prefix confirmed: k8s:enc:kms:v2:vault-kube-kms:"; \
		else \
			echo "  SKIP: no secrets in etcd yet (run ./vault-demo kms-verify first)"; \
		fi; \
	else \
		echo "  SKIP: kind cluster not running (run make setup-k8s + make enable-encryption first)"; \
	fi
	@echo ""
	@echo "━━━  All binary-level assumptions verified  ━━━"

# ── Demo shortcuts ──────────────────────────────────────────────────────────

.PHONY: verify
verify:
	@./vault-demo kms-verify

.PHONY: rotate
rotate:
	@./vault-demo kms-rotate

.PHONY: failover
failover:
	@./vault-demo kms-failover

.PHONY: telemetry
telemetry:
	@./vault-demo kms-telemetry

.PHONY: demo
demo:
	@./vault-demo all

# ── Operations ────────────────────────────────────────────────────────────────

.PHONY: logs
logs:
	@docker exec vault-kube-kms-control-plane tail -f /var/log/kms.log

.PHONY: status
status:
	@./vault-demo status

.PHONY: clean
clean:
	@./vault-demo clean

.PHONY: enterprise-reset
enterprise-reset:
	@echo ">>> Resetting enterprise storage and init state..."
	@./vault-demo enterprise-reset
