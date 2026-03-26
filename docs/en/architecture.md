# Aegis AI Infrastructure MVP

This repository serves as the fundamental **GitOps** configuration core for Aegis AI. Powered by ArgoCD, `Aegis-AI-Infra` deploys the full suite of microservices out to the target Kubernetes cluster (`aegis-system`), establishing networking and access controls implicitly.

## Environment: MVP (Replaces Pre-Alpha)
We have officially deprecated the `pre-alpha` label to embrace the `mvp` release channel. The infrastructure leverages a baseline `aegis-service` Helm chart mapped iteratively to the microservice stack.

### Zero Trust Network Topology
To harden our internal cluster against compromised sandboxes and internal lateral movements, we utilize **Cilium Network Policies**:
- **Gateway Isolation**: Operates blindly. Cannot command PostgreSQL or Temporal workflows. Traffic egress allowed strictly toward the gRPC port on the `brain`.
- **Database & Queue Confinement**: Temporal and PostgreSQL (the primary state vectors) abide by `CiliumNetworkPolicy` defaults terminating all inbound traffic, explicitly accepting connections exclusively from the Brain namespace (`brain-mvp`).
- **Sandbox Containment**: A `CiliumClusterwideNetworkPolicy` traps any container spanning `app: vulnerable-target` inside a restrictive topology. Lateral cluster traffic is denied, allowing payload fetching solely towards the external internet.

## Continuous Delivery
ArgoCD orchestrates the `mvp` manifest tree located at `kubernetes/envs/mvp/kustomization.yaml`. Updates pushed to this repository sync instantly across the staging cluster.
