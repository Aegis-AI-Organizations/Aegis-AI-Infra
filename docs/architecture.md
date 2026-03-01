# Architecture — Aegis AI Platform

This document describes the **target architecture** of the Aegis AI platform — the full system design that the project aims to achieve by end of development.

---

## 🗺️ Full System Diagram

```mermaid
graph TD
    %% --- STYLE DEFINITIONS ---
    classDef rust fill:#7f1d1d,stroke:#ef4444,stroke-width:2px,color:#fff,rx:5,ry:5;
    classDef python fill:#064e3b,stroke:#10b981,stroke-width:2px,color:#fff,rx:5,ry:5;
    classDef go fill:#0f172a,stroke:#38bdf8,stroke-width:2px,color:#fff,rx:5,ry:5;
    classDef react fill:#1e3a8a,stroke:#60a5fa,stroke-width:2px,color:#fff,rx:5,ry:5;
    classDef web fill:#172554,stroke:#3b82f6,stroke-width:2px,color:#fff,rx:5,ry:5;
    classDef db fill:#1e293b,stroke:#38bdf8,stroke-width:2px,color:#fff,rx:5,ry:5;
    classDef boundary fill:none,stroke:#475569,stroke-width:1px,stroke-dasharray: 5 5,color:#94a3b8;

    %% --- 1. USERS & PRESENTATION LAYER ---
    User("👤 DevSecOps Client")
    Visitor("🌍 Public Visitor")

    subgraph Web ["Presentation Layer (Frontend)"]
        Landing[("🌐 Landing Site<br/>(Vite / SSG)")]
        Admin[("🕹️ Admin Console<br/>(React / SPA)")]
    end

    %% --- 2. CLIENT INFRASTRUCTURE ---
    subgraph Client ["🏭 Client Infrastructure (Target)"]
        Agent[("🦀 Aegis Agent<br/>(Rust Module)")]
    end

    %% --- 3. AEGIS CORE CLOUD ---
    subgraph K8s ["☁️ Kubernetes Cluster (Aegis Core)"]

        Ingress{{"🛡️ Nginx Ingress<br/>(mTLS / WAF)"}}

        %% COMPUTE LAYER
        subgraph Compute ["Compute Layer"]
            W_API[("🐹 API Gateway<br/>(Go/Gin)")]

            subgraph BrainCluster ["🧠 DECISION CENTER (HA Mode)"]
                TemporalServ[("Temporal Server<br/>(Orchestrator)")]
                Brain[("🐍 Brain AI Logic<br/>(Python)")]
            end

            subgraph WorkerPools ["⚡ INFINITE WORKER POOLS (Autoscaling)"]
                direction TB
                W_Ingest[("🦀 POOL: INGEST<br/>(Rust)")]
                W_Deployer[("🏗️ POOL: DEPLOYER<br/>(Go)")]
                W_Pentest[("⚔️ POOL: PENTEST<br/>(Python)")]
                W_Fixer[("🚑 POOL: FIXER<br/>(Go)")]
            end
        end

        %% DATA LAYER
        subgraph Data ["Data Layer"]
            PG[("PostgreSQL<br/>State")]
            CH[("ClickHouse<br/>Logs")]
            Neo[("Neo4j<br/>Graph")]
            Redis[("Redis<br/>Hot Cache")]
        end
    end

    %% --- 4. SANDBOX ---
    subgraph Sandbox ["Isolated Runtime (gVisor)"]
        Twin["🏭 Digital Twin Pods"]
    end

    %% --- WEB FLOWS ---
    Visitor --> Landing
    Landing -. "Auth / Signup" .-> Ingress

    User --> Admin
    Admin -- "REST / gRPC Web" --> Ingress
    Ingress --> W_API

    %% API to Data
    W_API --> PG & CH & BrainCluster & Neo & Redis

    %% --- AGENT FLOW ---
    Agent == "Stream" ==> Ingress
    Ingress --> W_Ingest
    W_Ingest -- "1. Buffer" --> Redis
    W_Ingest -- "2. Batch Write" --> CH

    %% --- BUSINESS LOGIC ---
    BrainCluster --> Neo
    BrainCluster --> W_Deployer & W_Pentest & W_Fixer
    W_Deployer & W_Pentest & W_Fixer --> Twin

    %% --- STYLES ---
    class Agent,W_Ingest rust
    class Brain,W_Pentest python
    class TemporalServ,W_Deployer,W_Fixer,W_API go
    class Admin react
    class Landing web
    class PG,CH,Neo,Redis db
    class Client,K8s,Compute,Data,Sandbox,Web,BrainCluster,WorkerPools boundary
```

---

## 🏛️ Layers Overview

### Presentation Layer (Frontend)

| Service | Tech | Role |
|---|---|---|
| **Landing Site** | Vite / SSG | Public-facing marketing site. Handles auth/signup flows redirected to the API Gateway. |
| **Admin Console** | React / SPA | Internal DevSecOps dashboard. Full management interface communicating with the API Gateway via REST/gRPC-Web. |

---

### Client Infrastructure

| Service | Tech | Role |
|---|---|---|
| **Aegis Agent** | Rust | Lightweight module deployed **on the client's own infrastructure** (the target being analyzed). Streams telemetry data (network events, syscalls, process activity) to the Aegis cluster via a persistent authenticated stream. |

The Agent is the sole data collection point on the client side. It operates under a strictly minimal footprint and communicates exclusively with the cluster Ingress over mTLS.

---

### Kubernetes Cluster — Compute Layer

#### 🛡️ Nginx Ingress (mTLS / WAF)

Single entry point for all inbound traffic. Enforces:
- **mTLS** — mutual TLS client certificate authentication for the Agent stream
- **WAF** — web application firewall rules for HTTP traffic
- No internal service is reachable without going through the Ingress

#### 🐹 API Gateway (Go / Gin)

Central hub of the platform. Exposes the REST and gRPC-Web API consumed by the Admin Console and the Landing Site. Routes requests to:
- PostgreSQL (persistent state)
- ClickHouse (log queries)
- Neo4j (topology graph queries)
- Redis (hot cache reads)
- Brain Cluster (triggering analysis workflows)

#### 🧠 Decision Center — Brain + Temporal (HA Mode)

The cognitive core of Aegis:

| Component | Tech | Role |
|---|---|---|
| **Temporal Server** | Go | Durable workflow orchestrator. Schedules and tracks all long-running analysis and remediation workflows. Guarantees at-least-once execution. |
| **Brain AI Logic** | Python | Consumes topology data from Neo4j, applies AI/ML reasoning, and dispatches tasks to the Worker Pools via Temporal workflows. |

The Brain Cluster runs in **High Availability mode** — multiple replicas ensure no single point of failure in the decision pipeline.

#### ⚡ Worker Pools (Autoscaling)

All workers consume tasks from Temporal. Each pool scales independently based on queue depth.

| Pool | Tech | Role |
|---|---|---|
| **Ingest** | Rust | Receives the raw telemetry stream from the Agent. Buffers events into Redis (hot path) and batch-writes to ClickHouse (cold path). High-throughput, zero-copy pipeline. |
| **Deployer** | Go | Provisions and configures **Digital Twin** environments in the gVisor sandbox in response to Brain decisions. |
| **Pentest** | Python | Executes attack simulations against Digital Twin pods. Leverages offensive security tooling under controlled, sandboxed conditions. |
| **Fixer** | Go | Applies remediation actions based on Brain analysis — generates patches, configuration fixes, and hardening recommendations. |

---

### Data Layer

| Store | Tech | Role |
|---|---|---|
| **PostgreSQL** | PostgreSQL 16 | Primary relational store. Holds platform state: users, tenants, scan results, configurations. |
| **ClickHouse** | ClickHouse 23.8 | Columnar store for high-volume telemetry logs. Optimized for time-series analytical queries over agent-streamed events. |
| **Neo4j** | Neo4j 5.15 | Graph database storing the **topology map** of the client infrastructure — nodes, relationships, attack paths, blast radius. Core input to Brain reasoning. |
| **Redis** | Redis 7.2 | In-memory hot cache. Used by the Ingest worker as a real-time event buffer and by the API Gateway for low-latency reads. |

---

### Isolated Runtime — Digital Twin (gVisor)

Digital Twin pods run in dedicated `sandbox-*` namespaces under the **gVisor (`runsc`)** runtime. They represent a faithful replica of the client's infrastructure used as the attack target for the Pentest Worker.

Security guarantees:
- **gVisor** sandboxes all syscalls at the kernel level
- **Cilium deny-all** network policy — no ingress, no egress
- All interaction is mediated exclusively by the Worker Pools

See [gVisor Sandbox Runtime](gvisor-sandbox.md) for detailed configuration.

---

## 🔁 Key Data Flows

### 1. Agent Telemetry Ingestion
```
Aegis Agent (client infra)
  → [mTLS Stream] → Nginx Ingress
  → Ingest Worker (Rust)
  → Redis (real-time buffer) + ClickHouse (batch write)
```

### 2. DevSecOps Operation
```
Admin Console (React)
  → [REST/gRPC-Web] → Nginx Ingress → API Gateway (Go)
  → PostgreSQL / ClickHouse / Neo4j / Redis / Brain Cluster
```

### 3. AI Analysis & Attack Simulation
```
Brain (Python) reads Neo4j topology graph
  → Dispatches Temporal workflow
  → Deployer Worker spins up Digital Twin (gVisor sandbox)
  → Pentest Worker executes attack simulation against Twin
  → Fixer Worker generates remediation report
  → Results written to PostgreSQL + Neo4j
```

---

## 📖 Further Reading

- [Getting Started — Run locally](getting-started.md)
- [Kubernetes Deployment Patterns](kubernetes.md)
- [Cilium Network Policies](cilium-network.md)
- [gVisor Sandbox Runtime](gvisor-sandbox.md)
