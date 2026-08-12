#!/usr/bin/env bash
# install-dependencies.sh
# Installs every host tool required by vault-kms-kubernetes-lab.
#
# Supported platforms:
#   macOS  — installs via Homebrew (installs Homebrew itself if missing)
#   Linux  — installs via apt-get (Debian/Ubuntu) or dnf (RHEL/Fedora)
#
# NOTE: etcdctl is NOT installed here — it is installed automatically
#       inside the kind node by scripts/setup-kind-cluster.sh.
set -euo pipefail

log()  { echo "[$(date +%H:%M:%S)]  $*"; }
ok()   { echo "[$(date +%H:%M:%S)] \u2713  $*"; }
skip() { echo "[$(date +%H:%M:%S)] –  $* (already installed)"; }
err()  { echo "[ERROR] $*" >&2; exit 1; }

OS="$(uname -s)"
ARCH="$(uname -m)"

install_macos() {
	log "Detected macOS ($ARCH)"

	if ! command -v brew >/dev/null 2>&1; then
		log "Installing Homebrew..."
		/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
		if [[ "$ARCH" == "arm64" ]]; then
			eval "$(/opt/homebrew/bin/brew shellenv)"
		else
			eval "$(/usr/local/bin/brew shellenv)"
		fi
	else
		skip "Homebrew"
	fi

	brew_install() {
		local pkg="$1" cmd="${2:-$1}"
		if command -v "$cmd" >/dev/null 2>&1; then
			skip "$pkg"
		else
			log "Installing $pkg..."
			brew install "$pkg"
			ok "$pkg"
		fi
	}

	brew_install curl
	brew_install git
	brew_install jq
	brew_install kind
	brew_install kubectl

	if command -v go >/dev/null 2>&1; then
		skip "go  ($(go version | awk '{print $3}'))"
	else
		log "Installing go..."
		brew install go
		ok "go"
	fi

	if command -v vault >/dev/null 2>&1; then
		skip "vault  ($(vault version | head -1))"
	else
		log "Installing vault CLI..."
		brew tap hashicorp/tap
		brew install hashicorp/tap/vault
		ok "vault"
	fi

	if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
		skip "docker  (daemon running)"
	else
		echo ""
		echo "  Docker Desktop is not installed or not running."
		echo "  Download and install manually from:"
		echo "  https://docs.docker.com/desktop/install/mac-install/"
		echo ""
		echo "  After installing, start Docker Desktop, then re-run this script"
		echo "  or continue with: make bootstrap"
	fi
}

install_linux_apt() {
	log "Detected Linux with apt ($ARCH)"
	sudo apt-get update -qq

	apt_install() {
		local pkg="$1" cmd="${2:-$1}"
		if command -v "$cmd" >/dev/null 2>&1; then
			skip "$pkg"
		else
			log "Installing $pkg..."
			sudo apt-get install -y -qq "$pkg"
			ok "$pkg"
		fi
	}

	apt_install curl
	apt_install git
	apt_install jq

	if ! command -v kind >/dev/null 2>&1; then
		log "Installing kind..."
		KIND_VERSION="v0.25.0"
		curl -Lo /tmp/kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64"
		chmod +x /tmp/kind
		sudo mv /tmp/kind /usr/local/bin/kind
		ok "kind"
	else
		skip "kind"
	fi

	if ! command -v kubectl >/dev/null 2>&1; then
		log "Installing kubectl..."
		curl -Lo /tmp/kubectl \
			"https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
		chmod +x /tmp/kubectl
		sudo mv /tmp/kubectl /usr/local/bin/kubectl
		ok "kubectl"
	else
		skip "kubectl"
	fi

	if ! command -v go >/dev/null 2>&1; then
		log "Installing go (via apt)..."
		sudo apt-get install -y -qq golang-go
		ok "go"
	else
		skip "go  ($(go version | awk '{print $3}'))"
	fi

	if ! command -v vault >/dev/null 2>&1; then
		log "Installing vault CLI..."
		wget -O - https://apt.releases.hashicorp.com/gpg 2>/dev/null | \
			sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
		echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
			https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
			sudo tee /etc/apt/sources.list.d/hashicorp.list >/dev/null
		sudo apt-get update -qq
		sudo apt-get install -y -qq vault
		ok "vault"
	else
		skip "vault  ($(vault version | head -1))"
	fi
}

install_linux_dnf() {
	log "Detected Linux with dnf ($ARCH)"

	dnf_install() {
		local pkg="$1" cmd="${2:-$1}"
		if command -v "$cmd" >/dev/null 2>&1; then
			skip "$pkg"
		else
			sudo dnf install -y "$pkg" && ok "$pkg"
		fi
	}

	dnf_install curl
	dnf_install git
	dnf_install jq

	if ! command -v kind >/dev/null 2>&1; then
		log "Installing kind..."
		KIND_VERSION="v0.25.0"
		curl -Lo /tmp/kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64"
		chmod +x /tmp/kind && sudo mv /tmp/kind /usr/local/bin/kind
		ok "kind"
	else
		skip "kind"
	fi

	if ! command -v kubectl >/dev/null 2>&1; then
		log "Installing kubectl..."
		curl -Lo /tmp/kubectl \
			"https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
		chmod +x /tmp/kubectl && sudo mv /tmp/kubectl /usr/local/bin/kubectl
		ok "kubectl"
	else
		skip "kubectl"
	fi

	if ! command -v go >/dev/null 2>&1; then
		sudo dnf install -y golang && ok "go"
	else
		skip "go"
	fi

	if ! command -v vault >/dev/null 2>&1; then
		log "Installing vault CLI via HashiCorp repo..."
		sudo dnf install -y dnf-plugins-core
		sudo dnf config-manager --add-repo https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo
		sudo dnf install -y vault
		ok "vault"
	else
		skip "vault"
	fi
}

case "$OS" in
	Darwin)  install_macos ;;
	Linux)
		if command -v apt-get >/dev/null 2>&1; then
			install_linux_apt
		elif command -v dnf >/dev/null 2>&1; then
			install_linux_dnf
		else
			err "Unsupported Linux package manager. Install manually: kind kubectl go vault jq curl git"
		fi
		;;
	*)
		err "Unsupported OS: $OS. Install manually: kind kubectl go vault jq curl git"
		;;
esac

echo ""
log "All tools installed. Verifying..."
echo ""
FAILED=0
for tool in docker kind kubectl go vault jq curl git; do
	if command -v "$tool" >/dev/null 2>&1; then
		printf "  \u2713  %-10s %s\n" "$tool" "$(command -v "$tool")"
	else
		printf "  \u2717  %-10s NOT FOUND\n" "$tool"
		FAILED=1
	fi
done
echo ""
[[ "$FAILED" -eq 0 ]] && ok "All tools present. Next: see README.md -> Quick Start" || \
	err "Some tools are missing. See output above."
