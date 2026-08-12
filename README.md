# Vault KMS on Kubernetes Lab

> **Beta feature** — `vault-kube-kms` is stable but subject to change. Do not use in production Vault deployments.
> **Vault Enterprise required** — the plugin validates `sys/license/status` at startup and exits immediately against Community Edition.

This lab demonstrates Vault as a Kubernetes KMS v2 provider, encrypting Kubernetes secrets at rest in etcd. The [vault-kube-kms](https://github.com/hashicorp/vault-kube-kms) plugin bridges `kube-apiserver` ↔ Vault Transit so that key material never lives in the cluster.

---

## What this demo proves to the customer

| Customer question | Demo answer |
|---|---|
| Is my etcd actually encrypted? | Live `etcdctl` dump shows `k8s:enc:kms:v2:vault-kube-kms:` prefix — plaintext is absent |
| Who controls the keys? | Vault Transit only — Kubernetes holds encrypted DEK seeds, never raw key material |
| Can I rotate without downtime? | One `vault write -f transit/keys/kms/rotate` — plugin auto-detects, no API server restart |
| What if Vault goes down? | KMS v2 DEK-seed caching keeps reads alive; new writes fail — shows why Vault HA matters |
| How do I audit key usage? | Vault audit log + Prometheus `/metrics` on the plugin |

---

## First-time setup (fresh clone)

### Step 0 — Install dependencies

```bash
bash scripts/install-dependencies.sh
```

This script installs `kind`, `kubectl`, `go`, `vault` CLI, `jq`, `curl`, and `git` via Homebrew (macOS) or apt/dnf (Linux). Docker Desktop must be installed manually on macOS — the script will tell you if it is missing.

> **Note:** `etcdctl` does **not** need to be installed on your laptop. The setup script installs it inside the kind node automatically.

### Step 1 — Add your Vault Enterprise license

After cloning, you must place your Vault Enterprise license file at:

```
License/vault.hclic
```

The file must contain a single-line license string with no trailing newline. An example placeholder is at `License/vault.hclic.example`.

```bash
# Copy your license file into place:
cp /path/to/your/vault.hclic License/vault.hclic

# Verify it is non-empty:
test -s License/vault.hclic && echo "License OK" || echo "LICENSE MISSING OR EMPTY"
```

> ⚠️ `License/vault.hclic` is in `.gitignore` — it will never be committed. Do not export or share it.

Alternatively, export it as an environment variable before running any `make` target:

```bash
export VAULT_LICENSE="$(cat /path/to/vault.hclic)"
```

---

## Quick Start

```bash
# 1. Install tools (first time only)
bash scripts/install-dependencies.sh

# 2. Add license (first time only)
cp /path/to/vault.hclic License/vault.hclic

# 3. One-shot bootstrap (Vault + k8s + plugin + encryption — ~5 minutes)
make bootstrap

# 4. Run the demo scenes
./vault-demo kms-verify     # Prove etcd is encrypted
./vault-demo kms-rotate     # Zero-downtime key rotation
./vault-demo kms-failover   # Vault outage resilience
./vault-demo kms-telemetry  # Prometheus metrics + audit log
./vault-demo all            # All scenes in sequence
```

### Step-by-step alternative

```bash
make enterprise          # Start Vault Enterprise, init + unseal
./vault-demo kms-setup   # Configure Transit + AppRole (must run before setup-k8s)
make setup-k8s           # Create kind cluster (k8s v1.33.1), install etcdctl in node
make build-kms-binary    # Clone vault-kube-kms, cross-compile Linux amd64 binary
make deploy-kms          # Copy binary into kind node, start plugin, verify /readyz
make enable-encryption   # Patch kube-apiserver manifest, wait for healthy restart
./vault-demo kms-verify  # Prove it works
```

---

## Verify your setup is correct

```bash
make verify-assumptions
```

This checks four facts about the compiled binary that were verified against the source and in some cases **contradict the official HashiCorp docs** (which are stale):

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

If any check fails, the lab will tell you exactly what is wrong before you reach the customer session.

---

## Architecture

```
Customer Laptop
│
├── Docker Compose (host)
│   └── vault-enterprise              port 8200, Shamir unseal, file storage
│       ├── Transit engine: transit/
│       ├── Key: transit/keys/kms     AES-256-GCM96
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
        ├── /tmp/vault-kube-kms.socket          gRPC Unix socket
        ├── /tmp/approle-secret-id              mode 0400
        ├── /etc/kubernetes/encryption-config.yaml
        │     endpoint: unix:///tmp/vault-kube-kms.socket
        ├── /opt/kms/vault-kube-kms             Linux binary (built from source)
        │     --vault-key-path=transit/keys/kms
        │     --vault-address=http://<docker-gateway>:8200
        │     --approle-role-id=lab-kube-kms
        │     --approle-secret-id-path=/tmp/approle-secret-id
        │     --tls-skip-verify  ← LAB ONLY, never in production
        │     --metrics-port=9090
        │     --health-port=8081
        └── kube-apiserver
              --encryption-provider-config=/etc/kubernetes/encryption-config.yaml
              --encryption-provider-config-automatic-reload=true
```

---

## Demo talk track (30 minutes)

| Time | Segment |
|---|---|
| 0–3 min | **Why** — "etcd stores secrets as base64, not ciphertext. An etcd backup is a full credential dump." |
| 3–8 min | **Vault side** — show Transit key, minimum policy, AppRole in Vault UI |
| 8–14 min | **Proof** — `kms-verify`: etcdctl dump shows ciphertext prefix, plaintext absent, kubectl decrypts transparently |
| 14–20 min | **Rotation** — `kms-rotate`: one Vault command, plugin auto-detects, no restart |
| 20–25 min | **Resilience** — `kms-failover`: stop Vault, reads survive (KMS v2 cache), writes fail, recover |
| 25–28 min | **Observability** — `kms-telemetry`: Prometheus latency histograms + Vault audit log |
| 28–30 min | **Best practices** — 90-day rotation, secret-id 0400, short TTL, Vault HA = write availability |

---

## Makefile reference

```
make bootstrap           Full one-shot startup (Vault + k8s + binary + plugin + encryption)

make enterprise          Start Vault Enterprise
make setup-k8s           Create kind cluster + detect Docker bridge gateway
make build-kms-binary    Clone vault-kube-kms repo + cross-compile Linux amd64 binary
make deploy-kms          Copy binary into kind node + start plugin
make enable-encryption   Patch kube-apiserver manifest + wait for healthy restart

make verify-assumptions  Prove source-derived claims against compiled binary
make demo                Run all demo modules in sequence
make verify              kms-verify only
make rotate              kms-rotate only
make failover            kms-failover only
make telemetry           kms-telemetry only

make logs                Tail vault-kube-kms plugin log
make status              Vault + kind + plugin status summary
make clean               Tear down everything (kind cluster + Vault + lab state)
make enterprise-reset    Reset Vault raft storage and init state
```

---

## Troubleshooting

**`vault Community Edition detected` in plugin logs**
```bash
test -s License/vault.hclic && echo "License OK" || echo "MISSING"
# Or check: vault status | grep -i enterprise
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

**Socket path mismatch (API server can't reach plugin)**
```bash
# These two must match exactly:
grep endpoint k8s/encryption-config.yaml
docker exec vault-kube-kms-control-plane grep 'listen-addr' /var/log/kms.log
```

**Unseal fails after failover demo**
```bash
# init-vault.sh reads keys from .vault-init.json automatically — should self-heal
# If not, unseal manually:
jq -r '.unseal_keys_b64[0]' .vault-init.json | xargs vault operator unseal
jq -r '.unseal_keys_b64[1]' .vault-init.json | xargs vault operator unseal
jq -r '.unseal_keys_b64[2]' .vault-init.json | xargs vault operator unseal
```

**Go version too old for build**
```bash
go version          # need >= 1.21
brew upgrade go     # macOS
```

**Full reset**
```bash
make clean
make bootstrap
```

---

## What is NOT in this repo (intentionally)

| Item | Why excluded | Where to get it |
|---|---|---|
| `License/vault.hclic` | Secret — never committed | Your Vault Enterprise entitlement |
| `vault-kube-kms` binary | Built from source at runtime | `make build-kms-binary` clones and compiles |
| `.lab-state/` contents | Generated at runtime | Created by `make deploy-kms` |
| `data/` | Vault raft storage — machine-specific | Created by `make enterprise` |

---

## Supported Kubernetes versions

IBM-tested: **1.32, 1.33, 1.34, 1.35, 1.36**. This lab pins to `kindest/node:v1.33.1`.
