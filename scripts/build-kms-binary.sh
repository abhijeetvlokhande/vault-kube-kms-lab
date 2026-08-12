#!/usr/bin/env bash
# Clone vault-kube-kms and cross-compile a Linux amd64 binary.
# Output: .lab-state/vault-kube-kms
#
# Cross-compilation is required because kind nodes run Linux amd64
# even on macOS Apple Silicon (arm64) hosts.
set -euo pipefail

log()   { echo "[$(date +%H:%M:%S)] $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LAB_STATE="$REPO_ROOT/.lab-state"
mkdir -p "$LAB_STATE"

UPSTREAM_REPO="https://github.com/hashicorp/vault-kube-kms.git"
BUILD_SRC="/tmp/vault-kube-kms-src"
OUTPUT="$LAB_STATE/vault-kube-kms"

if [[ -d "$BUILD_SRC/.git" ]]; then
	log "Reusing existing clone at $BUILD_SRC (run 'rm -rf $BUILD_SRC' to force re-clone)"
else
	log "Cloning $UPSTREAM_REPO..."
	rm -rf "$BUILD_SRC"
	git clone --depth 1 "$UPSTREAM_REPO" "$BUILD_SRC"
fi

cd "$BUILD_SRC"
log "Building vault-kube-kms (GOOS=linux GOARCH=amd64)..."

LD_FLAGS=""
if [[ -x "./scripts/ldflags-version.sh" ]]; then
	LD_FLAGS="$(GOOS=linux GOARCH=amd64 ./scripts/ldflags-version.sh 2>/dev/null || true)"
fi

CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
	-ldflags "$LD_FLAGS" \
	-o "$OUTPUT" \
	./main.go

chmod +x "$OUTPUT"
log "Binary built: $OUTPUT"
log "SHA256: $(sha256sum "$OUTPUT" | awk '{print $1}')"

# Smoke-test: the binary is Linux amd64 and cannot run on the macOS host.
# Run it inside the kind node if the cluster is up, otherwise skip.
KIND_CLUSTER_NAME="vault-kube-kms"
CONTAINER="${KIND_CLUSTER_NAME}-control-plane"
if kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER_NAME}$"; then
	docker exec "$CONTAINER" mkdir -p /opt/kms
	docker cp "$OUTPUT" "${CONTAINER}:/opt/kms/vault-kube-kms-smoketest"
	docker exec "$CONTAINER" chmod +x /opt/kms/vault-kube-kms-smoketest
	if ! docker exec "$CONTAINER" /opt/kms/vault-kube-kms-smoketest --help 2>&1 | grep -q 'vault-key-path'; then
		error "Smoke-test FAILED: --vault-key-path not found in binary --help.
This indicates a build or version mismatch. Check the upstream repo."
	fi
	docker exec "$CONTAINER" rm -f /opt/kms/vault-kube-kms-smoketest
	log "Smoke-test passed: --vault-key-path flag confirmed in binary."
else
	log "Smoke-test skipped: kind cluster not running (binary is Linux amd64, cannot run on host)."
fi
