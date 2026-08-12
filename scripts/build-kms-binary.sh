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

if ! "$OUTPUT" --help 2>&1 | grep -q 'vault-key-path'; then
	error "Smoke-test FAILED: --vault-key-path not found in binary --help.
This indicates a build or version mismatch. Check the upstream repo."
fi
log "Smoke-test passed: --vault-key-path flag confirmed in binary."
