#!/usr/bin/env bash
# Shared compose/docker helpers — sourced by other scripts.
set -euo pipefail

WEBAPP_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$WEBAPP_COMMON_DIR/detect-mode.sh"

docker_cmd() {
	env -u DOCKER_HOST -u CONTAINER_HOST -u CONTAINER_SSHKEY docker "$@"
}

compose_cmd() {
	local compose_file="$REPO_ROOT/docker-compose.yml"
	local project_name="${COMPOSE_PROJECT_NAME:-vault-kms-lab}"
	if command -v docker-compose >/dev/null 2>&1; then
		env -u DOCKER_HOST -u CONTAINER_HOST -u CONTAINER_SSHKEY \
			docker-compose -f "$compose_file" -p "$project_name" "$@"
		return
	fi
	docker_cmd compose -f "$compose_file" -p "$project_name" "$@"
}
