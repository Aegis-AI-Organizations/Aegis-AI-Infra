# Local DevOps Loop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Provide a reproducible local E2E loop for Aegis: DNS setup, vulnerable target deployment, scan trigger, completion polling, and flag assertion.

**Architecture:** Keep the feature in `Aegis-AI-Infra` as local-dev tooling. Shell scripts own host/cluster orchestration, Kustomize owns the local vulnerable target, and `make` exposes stable developer commands.

**Tech Stack:** Bash, kubectl, Kustomize, Make, curl, POSIX tools, Kubernetes manifests.

## Global Constraints

- Do not require `curl --resolve` after DNS setup.
- The local target must expose a deterministic SQLi flag: `aegis-flag-1234`.
- The E2E script exits 0 only when a scan completes and vulnerability/evidence output contains `aegis-flag-1234`.
- Runtime E2E depends on a local Kubernetes MVP stack and is not executed in CI.
- CI validates scripts and manifests statically.

---

### Task 1: Local DNS Setup

**Files:**
- Create: `scripts/setup-dns.sh`
- Modify: `Makefile`

**Interfaces:**
- Produces: `make setup-dns`, `scripts/setup-dns.sh`.

- [ ] Write script that detects ingress IP/hostname from `ingress-nginx` LoadBalancer, falls back to NodePort node IP, and updates `/etc/hosts` with `app.aegis.mvp.local` and `api.aegis.mvp.local`.
- [ ] Add `make setup-dns` target.
- [ ] Verify with `bash -n scripts/setup-dns.sh` and `make -n setup-dns`.

### Task 2: Local Vulnerable Target

**Files:**
- Create: `kubernetes/local-target/kustomization.yaml`
- Create: `kubernetes/local-target/namespace.yaml`
- Create: `kubernetes/local-target/configmap.yaml`
- Create: `kubernetes/local-target/deployment.yaml`
- Create: `kubernetes/local-target/service.yaml`
- Modify: `Makefile`

**Interfaces:**
- Produces: `make deploy-local-target`, service `aegis-target.aegis-local-target.svc.cluster.local:8080`.

- [ ] Add Kustomize manifest for a Python HTTP target with intentionally vulnerable SQLi behavior and flag `aegis-flag-1234`.
- [ ] Add `make deploy-local-target` and `make delete-local-target`.
- [ ] Verify with `kubectl kustomize kubernetes/local-target`.

### Task 3: E2E Local Loop Assertion

**Files:**
- Create: `scripts/e2e-local-loop.sh`
- Modify: `Makefile`

**Interfaces:**
- Consumes: `.env` credentials `AEGIS_SEED_USER_EMAIL`, `AEGIS_SEED_USER_PASSWORD`; API base `https://api.aegis.mvp.local/api`; local target service URL.
- Produces: `make e2e-local-loop`, exit 0 on `aegis-flag-1234` discovery.

- [ ] Add script that logs in, creates a scan, polls `/scans/:id`, then checks vulnerabilities/evidences/report data for `aegis-flag-1234`.
- [ ] Add clear timeouts and diagnostic output.
- [ ] Verify with `bash -n scripts/e2e-local-loop.sh` and static pre-commit.

### Task 4: Documentation, CI, Push, Issues

**Files:**
- Modify: `README.md`
- Modify: `.github/workflows/build-and-test.yml`

**Interfaces:**
- Produces documented commands and CI static validation.

- [ ] Document `make setup-dns`, `make deploy-local-target`, `make e2e-local-loop`.
- [ ] Ensure CI syntax/Kustomize checks cover new files.
- [ ] Run `pre-commit run --all-files`, Helm/Kustomize checks, `graphify update .`.
- [ ] Commit, push, watch CI, and close issues `#63`, `#64`, `#65`, `#66` when green.

## Self-Review

- Covers DNS setup issue `#64`.
- Covers local vulnerable target issue `#65`.
- Covers E2E assertion issue `#66`.
- Covers parent validation issue `#63` through the combined loop and CI evidence.
