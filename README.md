# Vault KMS on Kubernetes

> **Beta feature** — `vault-kube-kms` is subject to change. Do not use in production without thorough testing.
> **Vault Enterprise required** — the plugin validates `sys/license/status` at startup and exits immediately when connected to a Community Edition instance.

## What is vault-kube-kms?

[vault-kube-kms](https://github.com/hashicorp/vault-kube-kms) is a Kubernetes KMS v2 provider plugin that integrates HashiCorp Vault with the Kubernetes API server's [encryption at rest](https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/) mechanism.

### The problem it solves

By default, Kubernetes stores secrets in etcd as base64-encoded plaintext. Anyone with access to an etcd backup, an etcd snapshot, or the underlying storage can read every secret in the cluster — passwords, tokens, certificates, and private keys — without authentication. This is a significant risk in shared infrastructure, regulated environments, and any deployment where storage-layer access is not fully controlled.

### How it works

The Kubernetes API server supports an [encryption provider](https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/) interface that intercepts every secret write and read. When configured to use a KMS provider, the API server calls the plugin over a local Unix socket. The plugin forwards the request to Vault's [Transit secrets engine](https://developer.hashicorp.com/vault/docs/secrets/transit), which encrypts or decrypts the data encryption key (DEK) seed using a key encryption key (KEK) that never leaves Vault.

```
kubectl write/read secret
         │
         ▼
   kube-apiserver
         │  gRPC (KMS v2, Unix socket)
         ▼
   vault-kube-kms plugin
         │  Vault API
         ▼
   Vault Transit engine
   (KEK: transit/keys/kms)
         │
         ▼
   etcd  ←  stores only ciphertext
```

### What this means in practice

- **etcd at rest is ciphertext.** An etcd backup or stolen disk yields nothing without Vault.
- **Vault holds the only KEK.** Cloud storage, etcd admins, and infrastructure operators cannot decrypt secrets without going through Vault.
- **Transparent to applications.** `kubectl get secret` still returns plaintext — the API server handles decryption automatically.
- **Key rotation with no downtime.** Rotating the Vault Transit key requires one API call; no API server restart, no application changes.
- **Full audit trail.** Every encrypt and decrypt call is logged in Vault's audit log.

---

## What this lab covers

| Scenario | What it shows |
|---|---|
| etcd encryption proof | `etcdctl` dump shows `k8s:enc:kms:v2:vault-kube-kms:` prefix — plaintext is absent |
| Key ownership | Vault Transit holds the KEK — Kubernetes stores only encrypted DEK seeds |
| Zero-downtime rotation | One `vault write -f transit/keys/kms/rotate` — plugin auto-detects, no API server restart |
| Resilience under outage | KMS v2 DEK-seed caching keeps reads alive when Vault is unreachable; new writes fail |
| Observability | Vault audit log + Prometheus `/metrics` from the plugin |

---

## Prerequisites

- macOS or Linux
- Docker Desktop (macOS) or Docker Engine (Linux)
- Internet access to pull container images and clone the vault-kube-kms source

All other tools (`kind`, `kubectl`, `go`, `vault` CLI, `jq`) are installed automatically by the setup script.

---

## Getting started

### 1. Install dependencies

```bash
bash scripts/install-dependencies.sh
```

Installs `kind`, `kubectl`, `go`, `vault` CLI, `jq`, `curl`, and `git` via Homebrew (macOS) or apt/dnf (Linux). Docker Desktop must be installed manually on macOS — the script prints instructions if it is missing.

> `etcdctl` does **not** need to be installed on your machine. It is installed automatically inside the kind node by the setup scripts.

### 2. Add your Vault Enterprise license

Place your license file at:

```
License/vault.hclic
```

The file must contain a single-line license string. An example placeholder is at [`License/vault.hclic.example`](License/vault.hclic.example).

```bash
cp /path/to/your/vault.hclic License/vault.hclic

# Verify it is non-empty:
test -s License/vault.hclic && echo "License OK" || echo "LICENSE MISSING OR EMPTY"
```

> `License/vault.hclic` is in `.gitignore` and will never be committed.

Alternatively, export the license as an environment variable:

```bash
export VAULT_LICENSE="$(cat /path/to/vault.hclic)"
```

### 3. Obtain the vault-kube-kms source

The build step (`make build-kms-binary`) clones the upstream repository automatically:

```bash
# Automatic (default) — requires internet access to github.com/hashicorp/vault-kube-kms
make build-kms-binary
```

If you do not have access to the upstream repository, obtain a source archive (`.zip` or `.tar.gz`) and extract it manually:

```bash
# Extract the archive to the expected path
unzip vault-kube-kms-main.zip -d /tmp/
mv /tmp/vault-kube-kms-main /tmp/vault-kube-kms-src

# Then run the build (skips the clone step because the directory already exists)
make build-kms-binary
```

### 4. Bootstrap the full environment

```bash
make bootstrap
```

This runs all five setup steps in sequence (approximately 5–10 minutes on first run):

1. Start Vault Enterprise, initialize, and unseal
2. Configure Vault: Transit engine, KEK, policy, AppRole
3. Create kind cluster (Kubernetes v1.33.1), install etcdctl inside the node
4. Build and copy the vault-kube-kms binary into the kind node, start the plugin
5. Patch the kube-apiserver manifest to enable KMS encryption, wait for the API server to restart

### 5. Run the scenarios

```bash
./vault-demo kms-verify     # Prove etcd is encrypted
./vault-demo kms-rotate     # Zero-downtime key rotation
./vault-demo kms-failover   # Resilience under Vault outage
./vault-demo kms-telemetry  # Prometheus metrics and Vault audit log
./vault-demo all            # Run all scenarios in sequence
```

---

## Step-by-step (instead of bootstrap)

If you prefer to run each step individually — useful when iterating or troubleshooting:

```bash
make enterprise          # Start Vault Enterprise, initialize, and unseal
./vault-demo kms-setup   # Configure Transit engine, AppRole, policy, audit log
make setup-k8s           # Create kind cluster, detect Docker bridge gateway, install etcdctl
make build-kms-binary    # Clone vault-kube-kms source, cross-compile Linux amd64 binary
make deploy-kms          # Copy binary into kind node, start plugin, wait for /readyz
make enable-encryption   # Patch kube-apiserver manifest, wait for healthy restart
./vault-demo kms-verify  # Verify encryption is working
```

> **Order matters.** `kms-setup` must run before `setup-k8s` because it generates the AppRole secret-id that the plugin needs. `deploy-kms` must run before `enable-encryption` because the API server will refuse to start if the KMS socket is not present.

---

## Verify the build

```bash
make verify-assumptions
```

Runs four checks against the compiled binary to confirm the build is correct:

```
[1/4] --vault-key-path flag exists in binary...
  PASS: --vault-key-path present

[2/4] --transit-mount and --transit-key absent as standalone flags...
  PASS: no standalone --transit-mount or --transit-key flags

[3/4] Default socket is unix:///tmp/vault-kube-kms.socket...
  PASS: default socket is unix:///tmp/vault-kube-kms.socket

[4/4] Live etcd prefix check...
  PASS: etcd prefix confirmed: k8s:enc:kms:v2:vault-kube-kms:
```

---

## Architecture

```
Your Machine
│
├── Docker Compose
│   └── vault-enterprise              port 8200, Shamir unseal, file storage
│       ├── Transit engine: transit/
│       ├── Key: transit/keys/kms     AES-256-GCM96 KEK
│       ├── Policy: transit-encrypt-decrypt
│       │     path transit/encrypt/kms  { capabilities = ["update","create"] }
│       │     path transit/decrypt/kms  { capabilities = ["update","create"] }
│       │     path transit/keys/kms     { capabilities = ["read"] }
│       │     path sys/license/status   { capabilities = ["read"] }
│       ├── AppRole: approle/role/kube-kms  (role-id: lab-kube-kms)
│       └── Audit log: /vault/logs/audit.log
│
└── kind cluster  (vault-kube-kms, k8s v1.33.1)
    └── vault-kube-kms-control-plane  (Docker container)
        ├── /tmp/vault-kube-kms.socket          gRPC KMS v2 Unix socket
        ├── /tmp/approle-secret-id              mode 0400
        ├── /etc/kubernetes/encryption-config.yaml
        │     endpoint: unix:///tmp/vault-kube-kms.socket
        ├── /opt/kms/vault-kube-kms             Linux binary (cross-compiled from source)
        │     --vault-key-path=transit/keys/kms
        │     --vault-address=http://<docker-gateway>:8200
        │     --approle-role-id=lab-kube-kms
        │     --approle-secret-id-path=/tmp/approle-secret-id
        │     --tls-skip-verify  ← LAB ONLY, not for production
        │     --metrics-port=9090
        │     --health-port=8081
        └── kube-apiserver
              --encryption-provider-config=/etc/kubernetes/encryption-config.yaml
              --encryption-provider-config-automatic-reload=true
```

---

## Makefile reference

```
make bootstrap           Full one-shot startup (Vault + k8s + binary + plugin + encryption)

make enterprise          Start Vault Enterprise
make setup-k8s           Create kind cluster + detect Docker bridge gateway
make build-kms-binary    Clone vault-kube-kms source + cross-compile Linux amd64 binary
make deploy-kms          Copy binary into kind node + start plugin
make enable-encryption   Patch kube-apiserver manifest + wait for healthy restart

make verify-assumptions  Run checks against the compiled binary
make demo                Run all scenarios in sequence
make verify              kms-verify only
make rotate              kms-rotate only
make failover            kms-failover only
make telemetry           kms-telemetry only

make logs                Tail vault-kube-kms plugin log
make status              Vault + kind + plugin status summary
make clean               Tear down everything (kind cluster + Vault + lab state)
make enterprise-reset    Reset Vault storage and init state
```

---

## Troubleshooting

**`vault Community Edition detected` in plugin logs**
```bash
test -s License/vault.hclic && echo "License OK" || echo "MISSING"
vault status | grep -i enterprise
```

**Plugin socket not found after `make deploy-kms`**
```bash
make logs
# Look for: AppRole auth errors, Vault unreachable, policy permission denied
```

**API server not coming back after `make enable-encryption`**
```bash
docker exec vault-kube-kms-control-plane crictl logs \
  $(docker exec vault-kube-kms-control-plane crictl ps --name kube-apiserver -q 2>/dev/null) 2>/dev/null | tail -30
```

**Socket path mismatch**
```bash
# These two must match exactly:
grep endpoint k8s/encryption-config.yaml
docker exec vault-kube-kms-control-plane grep 'listen-addr' /var/log/kms.log
```

**Unseal fails after the failover scenario**
```bash
# init-vault.sh reads keys from .vault-init.json automatically and should self-heal.
# To unseal manually:
jq -r '.unseal_keys_b64[0]' .vault-init.json | xargs vault operator unseal
jq -r '.unseal_keys_b64[1]' .vault-init.json | xargs vault operator unseal
jq -r '.unseal_keys_b64[2]' .vault-init.json | xargs vault operator unseal
```

**Go version too old for build**
```bash
go version          # requires >= 1.21
brew upgrade go     # macOS
```

**Full reset**
```bash
make clean
make bootstrap
```

---

## What is not in this repo

| Item | Reason | How to obtain |
|---|---|---|
| `License/vault.hclic` | Secret — never committed | Your Vault Enterprise entitlement |
| `vault-kube-kms` binary | Built from source at runtime | `make build-kms-binary` (or provide a source archive) |
| `.lab-state/` contents | Generated at runtime | Created automatically during setup |
| `data/` | Vault storage — machine-specific | Created by `make enterprise` |

---

## Supported Kubernetes versions

Tested with: **1.32, 1.33, 1.34, 1.35, 1.36**. This lab pins to `kindest/node:v1.33.1`.

---

## Lab documentation

Three reference documents are in the `docs/` directory:

| File | Purpose |
|---|---|
| [`docs/overview.html`](docs/overview.html) | Scenario map with architecture diagram, setup steps, and quick command reference |
| [`docs/talk-track.html`](docs/talk-track.html) | Structured ~30-minute walkthrough — talking points, expected Q&A, best practices |
| [`docs/raw-commands.html`](docs/raw-commands.html) | Every command verbatim (no Makefile abstraction) — useful for understanding or auditing each step |

---

## Further reading

- [Vault KMS for Kubernetes — HashiCorp Developer docs](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/kms)
- [Kubernetes Encryption at Rest](https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/)
- [Vault Transit Secrets Engine](https://developer.hashicorp.com/vault/docs/secrets/transit)
- [KMS v2 KEP (Kubernetes Enhancement Proposal)](https://github.com/kubernetes/enhancements/tree/master/keps/sig-auth/3299-kms-v2-improvements)
