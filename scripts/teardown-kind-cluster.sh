#!/usr/bin/env bash
set -euo pipefail

log()   { echo "[$(date +%H:%M:%S)] $*"; }

KIND_CLUSTER_NAME="vault-kube-kms"

log "Deleting kind cluster '${KIND_CLUSTER_NAME}'..."
kind delete cluster --name "$KIND_CLUSTER_NAME" || true
log "Cluster deleted."
