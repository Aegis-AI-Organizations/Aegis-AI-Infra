# ☁️ Aegis AI - Infrastructure (Core K8s & IaC)

**Project ID:** AEGIS-CORE-2026

## 🏗️ System Architecture & Role
The **Aegis AI Infra** repository codifies the entire production topology. Our global infrastructure is built upon an Event-Driven Microservices pattern on Kubernetes 1.28+.

* **Tech Stack & Tooling:**
  * **Kubernetes 1.28+** with **Cilium CNI** for L3/L4/L7 policy awareness.
  * **Ingress:** Nginx Ingress enforcing mTLS (Client Certificate Authentication) and WAF.
  * **Databases:** PostgreSQL 16 (State), ClickHouse 23.8 (Logs), Neo4j 5.15 (Topology Graph), Redis 7.2 (Hot Cache).

## 🔐 Security & DevSecOps Mandates
This repository represents our defense-in-depth posture:
* **Network Zoning (Deny-All Default):** Strict namespace segmentation (`aegis-gateway`, `aegis-core`, `aegis-data`, `sandbox-xyz`). No direct internet access for standard namespaces.
* **Runtime Sandbox Isolation:** For Digital Twins within `sandbox-*`, we exclusively use **gVisor (`runsc`)**. Standard `runc` is forbidden.
* **Secrets:** Injected strictly via Infisical/KV. Git-committed variables (`.tfvars`, Kube manifests) are structurally audited to forbid secrets.

## 🐳 Infrastructure Deployment Execution
All deployments are controlled via strictly audited IaC automation.

```bash
# Secure Infrastructure initialization
terraform init

# Plan using Infisical dynamic secrets
infisical run --env=prod -- terraform plan

# The Core databases and microservices are heavily containerized and managed via K8s.
```
