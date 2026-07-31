# CrewAI Worker External Ollama Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy the CrewAI Temporal worker in the MVP Kubernetes environment and configure it to use host-managed external Ollama.

**Architecture:** Reuse the existing `aegis-service` Helm chart for the worker. Extend the chart's CiliumNetworkPolicy template just enough to express external DNS egress for `host.docker.internal`, then add an ArgoCD app and values for `crewai-worker-mvp`.

**Tech Stack:** Kubernetes, ArgoCD, Helm, Kustomize, CiliumNetworkPolicy, KEDA Temporal scaler, GHCR, Temporal, Ollama.

## Global Constraints

- Preserve existing uncommitted Infra changes in worker values and scripts; stage only files touched by this plan.
- Do not deploy Ollama into Kubernetes for the MacBook MVP.
- Default external Ollama URL is `http://host.docker.internal:11434`.
- If `host.docker.internal` is not reachable from pods, use the Mac LAN IP consistently in all three CrewAI `*_API_BASE` values.
- Do not expose Ollama through ingress, NodePort, Cloudflare, or public networking.
- CrewAI V1 must not receive Kubernetes write RBAC.
- CrewAI listens to Temporal task queue `CREWAI_TASK_QUEUE`.
- CrewAI image repository is `ghcr.io/aegis-ai-organizations/aegis-ai-agent-crew`.
- CrewAI image tag is immutable `v2.0.8`; `latest` is forbidden by `scripts/validate-predictable-deployments.sh`.

---

## File Structure

- `kubernetes/charts/aegis-service/templates/networkpolicy.yaml`: add optional support for Cilium `toFQDNs` egress entries so worker values can allow `host.docker.internal` without broad external egress.
- `kubernetes/charts/aegis-service/values.yaml`: document the new optional `networkPolicy.egress[].toFQDNs` shape with an empty default.
- `kubernetes/envs/mvp/crewai-worker/application.yaml`: new ArgoCD Application for the CrewAI worker.
- `kubernetes/envs/mvp/crewai-worker/values.yaml`: worker image, runtime env, resources, KEDA Temporal scaler, and network policy.
- `kubernetes/envs/mvp/kustomization.yaml`: add the CrewAI worker ArgoCD application to the MVP app-of-apps resource list.
- `docs/superpowers/specs/2026-07-31-crewai-worker-kubernetes-design.md`: already updated; no implementation change needed unless verification reveals a mismatch.
- `docs/superpowers/specs/2026-07-31-external-ollama-mvp-design.md`: already added; no implementation change needed unless verification reveals a mismatch.

---

### Task 1: Add External DNS Egress Support To aegis-service

**Files:**
- Modify: `kubernetes/charts/aegis-service/templates/networkpolicy.yaml`
- Modify: `kubernetes/charts/aegis-service/values.yaml`

**Interfaces:**
- Consumes: existing `networkPolicy.egress` list in Helm values.
- Produces: optional `networkPolicy.egress[].toFQDNs` list rendered as Cilium `toFQDNs` entries.

- [ ] **Step 1: Add a minimal failing fixture mentally through Helm values**

Use this values fragment as the target behavior for the template:

```yaml
nameOverride: "fqdn-egress-test"
networkPolicy:
  enabled: true
  allowDNS: true
  egress:
    - toFQDNs:
        - matchName: host.docker.internal
      ports:
        - port: 11434
          protocol: TCP
```

Expected rendered Cilium policy must include:

```yaml
toFQDNs:
  - matchName: host.docker.internal
toPorts:
  - ports:
      - port: "11434"
        protocol: TCP
```

- [ ] **Step 2: Verify current template does not support the target behavior**

Run:

```bash
helm template fqdn-egress-test kubernetes/charts/aegis-service \
  --set nameOverride=fqdn-egress-test \
  --set networkPolicy.enabled=true \
  --set networkPolicy.egress[0].toFQDNs[0].matchName=host.docker.internal \
  --set networkPolicy.egress[0].ports[0].port=11434 \
  --set networkPolicy.egress[0].ports[0].protocol=TCP | grep -n "toFQDNs"
```

Expected before implementation: no `toFQDNs` output or command exits non-zero from grep.

- [ ] **Step 3: Update the network policy template**

In `kubernetes/charts/aegis-service/templates/networkpolicy.yaml`, add this block inside each egress item after the existing `toServices` block and before the `ports` block:

```yaml
      {{- if .toFQDNs }}
      toFQDNs:
        {{- range .toFQDNs }}
        - {{ toYaml . | nindent 10 | trim }}
        {{- end }}
      {{- end }}
```

The resulting egress loop must support all existing keys plus `toFQDNs`:

```yaml
  egress:
    {{- range .Values.networkPolicy.egress }}
    - {{- if .toEndpoints }}
      toEndpoints:
        {{- range .toEndpoints }}
        - {{ toYaml . | nindent 10 | trim }}
        {{- end }}
      {{- end }}
      {{- if .toEntities }}
      toEntities:
        {{- range .toEntities }}
        - {{ . }}
        {{- end }}
      {{- end }}
      {{- if .toServices }}
      toServices:
        {{- range .toServices }}
        - k8sService:
            {{- toYaml . | nindent 12 }}
        {{- end }}
      {{- end }}
      {{- if .toFQDNs }}
      toFQDNs:
        {{- range .toFQDNs }}
        - {{ toYaml . | nindent 10 | trim }}
        {{- end }}
      {{- end }}
      {{- if .ports }}
      toPorts:
        {{- range .ports }}
        - ports:
            - port: "{{ .port }}"
              protocol: {{ .protocol | default "TCP" }}
        {{- end }}
      {{- end }}
    {{- end }}
```

- [ ] **Step 4: Document the default values shape**

In `kubernetes/charts/aegis-service/values.yaml`, update the `networkPolicy` example block from:

```yaml
  egress: []
```

to this valid YAML comment shape:

```yaml
  # egress supports toEndpoints, toEntities, toServices, and toFQDNs.
  # Example:
  # egress:
  #   - toFQDNs:
  #       - matchName: host.docker.internal
  #     ports:
  #       - port: 11434
  #         protocol: TCP
  egress: []
```

- [ ] **Step 5: Verify the rendered policy now includes toFQDNs**

Run:

```bash
helm template fqdn-egress-test kubernetes/charts/aegis-service \
  --set nameOverride=fqdn-egress-test \
  --set networkPolicy.enabled=true \
  --set networkPolicy.egress[0].toFQDNs[0].matchName=host.docker.internal \
  --set networkPolicy.egress[0].ports[0].port=11434 \
  --set networkPolicy.egress[0].ports[0].protocol=TCP
```

Expected: output contains `toFQDNs`, `matchName: host.docker.internal`, and port `"11434"`.

- [ ] **Step 6: Commit Task 1**

Run:

```bash
git add kubernetes/charts/aegis-service/templates/networkpolicy.yaml kubernetes/charts/aegis-service/values.yaml
git commit -m "[FEAT] Support external FQDN egress policies"
```

---

### Task 2: Add CrewAI Worker ArgoCD Application

**Files:**
- Create: `kubernetes/envs/mvp/crewai-worker/application.yaml`
- Create: `kubernetes/envs/mvp/crewai-worker/values.yaml`
- Modify: `kubernetes/envs/mvp/kustomization.yaml`

**Interfaces:**
- Consumes: `aegis-service` chart support for `networkPolicy.egress[].toFQDNs` from Task 1.
- Produces: ArgoCD app `aegis-crewai-worker-mvp`, Helm release name override `crewai-worker-mvp`, and Deployment label `app=crewai-worker-mvp`.

- [ ] **Step 1: Create the CrewAI ArgoCD application**

Create `kubernetes/envs/mvp/crewai-worker/application.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: aegis-crewai-worker-mvp
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "3"
spec:
  project: default
  source:
    repoURL: https://github.com/Aegis-AI-Organizations/Aegis-AI-Infra.git
    targetRevision: main
    path: kubernetes/charts/aegis-service
    helm:
      valueFiles:
        - ../../envs/mvp/crewai-worker/values.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: aegis-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

- [ ] **Step 2: Create CrewAI worker values**

Create `kubernetes/envs/mvp/crewai-worker/values.yaml`:

```yaml
nameOverride: "crewai-worker-mvp"

replicaCount: 0
terminationGracePeriodSeconds: 900

image:
  repository: ghcr.io/aegis-ai-organizations/aegis-ai-agent-crew
  tag: "v2.0.8"
  pullPolicy: IfNotPresent

service:
  type: ClusterIP
  port: 8080
  targetPort: 8080

probes:
  enabled: false

env:
  - name: CREWAI_MODE
    value: "worker"
  - name: TEMPORAL_HOST
    value: "aegis-temporal-mvp-frontend.aegis-system.svc.cluster.local:7233"
  - name: TEMPORAL_NAMESPACE
    valueFrom:
      secretKeyRef:
        name: aegis-env
        key: TEMPORAL_NAMESPACE
  - name: CREWAI_TASK_QUEUE
    value: "CREWAI_TASK_QUEUE"
  - name: TEMPORAL_TLS_ENABLE
    value: "false"
  - name: PLANNER_PROVIDER
    value: "ollama"
  - name: PLANNER_MODEL
    value: "llama3.1:8b"
  - name: PLANNER_API_BASE
    value: "http://host.docker.internal:11434"
  - name: GUIDER_PROVIDER
    value: "ollama"
  - name: GUIDER_MODEL
    value: "whiterabbitneo"
  - name: GUIDER_API_BASE
    value: "http://host.docker.internal:11434"
  - name: EXECUTOR_PROVIDER
    value: "ollama"
  - name: EXECUTOR_MODEL
    value: "deepseek-coder-v2"
  - name: EXECUTOR_API_BASE
    value: "http://host.docker.internal:11434"

resources:
  limits:
    cpu: 1000m
    memory: 2Gi
  requests:
    cpu: 250m
    memory: 512Mi

serviceAccount:
  create: false
  automountToken: false

rbac:
  create: false
  clusterRole: false
  rules: []

networkPolicy:
  enabled: true
  allowDNS: true
  egress:
    - toServices:
        - serviceName: aegis-temporal-mvp-frontend
          namespace: aegis-system
      ports:
        - port: 7233
          protocol: TCP
    - toFQDNs:
        - matchName: host.docker.internal
      ports:
        - port: 11434
          protocol: TCP

keda:
  enabled: true
  minReplicaCount: 1
  maxReplicaCount: 5
  pollingInterval: 15
  cooldownPeriod: 900
  triggers:
    - type: temporal
      metadata:
        namespace: "default"
        taskQueue: "CREWAI_TASK_QUEUE"
        useTLS: "false"
        queueTypes: "workflow,activity"
        targetQueueSize: "1"
        activationTargetQueueSize: "0"
        endpoint: "aegis-temporal-mvp-frontend.aegis-system.svc.cluster.local:7233"
```

- [ ] **Step 3: Wire the app into the MVP kustomization**

In `kubernetes/envs/mvp/kustomization.yaml`, add the CrewAI application after the other worker apps:

```yaml
  - pentest-worker/application.yaml
  - ingest-worker/application.yaml
  - deployer-worker/application.yaml
  - crewai-worker/application.yaml
```

- [ ] **Step 4: Render the CrewAI worker chart**

Run:

```bash
helm template crewai-worker-mvp kubernetes/charts/aegis-service -f kubernetes/envs/mvp/crewai-worker/values.yaml
```

Expected: output includes `Deployment`, `Service`, `CiliumNetworkPolicy`, `ScaledObject`, image `ghcr.io/aegis-ai-organizations/aegis-ai-agent-crew:v2.0.8`, `CREWAI_MODE`, `CREWAI_TASK_QUEUE`, and `toFQDNs` for `host.docker.internal`.

- [ ] **Step 5: Render the MVP app-of-apps**

Run:

```bash
kubectl kustomize kubernetes/envs/mvp
```

Expected: output includes `kind: Application` and `name: aegis-crewai-worker-mvp`.

- [ ] **Step 6: Commit Task 2**

Run:

```bash
git add kubernetes/envs/mvp/crewai-worker/application.yaml kubernetes/envs/mvp/crewai-worker/values.yaml kubernetes/envs/mvp/kustomization.yaml
git commit -m "[FEAT] Add CrewAI worker MVP deployment"
```

---

### Task 3: Host Ollama And Cluster Reachability Verification Notes

**Files:**
- Modify: `docs/superpowers/specs/2026-07-31-external-ollama-mvp-design.md`
- Modify: `docs/superpowers/specs/2026-07-31-crewai-worker-kubernetes-design.md`

**Interfaces:**
- Consumes: external Ollama endpoint selected in Task 2.
- Produces: explicit operator commands for host model setup and pod-level reachability validation.

- [ ] **Step 1: Add a concise operator checklist to the external Ollama spec**

Append this section before `## Self-Review` in `docs/superpowers/specs/2026-07-31-external-ollama-mvp-design.md`:

````markdown
## Operator Checklist

Before syncing `aegis-crewai-worker-mvp`, run on the Mac host:

```bash
ollama serve
ollama pull llama3.1:8b
ollama pull whiterabbitneo
ollama pull deepseek-coder-v2
curl -fsS http://127.0.0.1:11434/api/tags
```

Then verify from the cluster:

```bash
kubectl run ollama-probe --rm -i --restart=Never --image=curlimages/curl -- \
  curl -fsS http://host.docker.internal:11434/api/tags
```

If this fails, replace `host.docker.internal` in `kubernetes/envs/mvp/crewai-worker/values.yaml` with the Mac LAN IP and rerun the probe.
````

- [ ] **Step 2: Add the same operational warning to the CrewAI Kubernetes spec**

Append this sentence to the `## Verification` section in `docs/superpowers/specs/2026-07-31-crewai-worker-kubernetes-design.md` after the `OLLAMA_UNREACHABLE` bullet:

```markdown
- if the worker reports `OLLAMA_UNREACHABLE`, verify `ollama serve` is running on the Mac host and probe `http://host.docker.internal:11434/api/tags` from an ephemeral pod before changing CrewAI code.
```

- [ ] **Step 3: Run markdown whitespace verification**

Run:

```bash
git diff --check -- docs/superpowers/specs/2026-07-31-external-ollama-mvp-design.md docs/superpowers/specs/2026-07-31-crewai-worker-kubernetes-design.md
```

Expected: no output and exit code `0`.

- [ ] **Step 4: Commit Task 3**

Run:

```bash
git add docs/superpowers/specs/2026-07-31-external-ollama-mvp-design.md docs/superpowers/specs/2026-07-31-crewai-worker-kubernetes-design.md
git commit -m "[CHORE] Add external Ollama operator checklist"
```

---

### Task 4: Final Verification And Graph Update

**Files:**
- Generated locally only: `graphify-out/`

**Interfaces:**
- Consumes: Tasks 1-3.
- Produces: verified branch ready for PR.

- [ ] **Step 1: Render CrewAI worker Helm chart**

Run:

```bash
helm template crewai-worker-mvp kubernetes/charts/aegis-service -f kubernetes/envs/mvp/crewai-worker/values.yaml
```

Expected: output renders successfully and contains `crewai-worker-mvp`, `CREWAI_TASK_QUEUE`, `host.docker.internal`, `toFQDNs`, and `ScaledObject`.

- [ ] **Step 2: Render MVP app-of-apps**

Run:

```bash
kubectl kustomize kubernetes/envs/mvp
```

Expected: output renders successfully and contains `aegis-crewai-worker-mvp`.

- [ ] **Step 3: Run repository whitespace check**

Run:

```bash
git diff --check
```

Expected: no output and exit code `0`.

- [ ] **Step 4: Run pre-commit**

Run:

```bash
pre-commit run --all-files
```

Expected: all hooks pass. If hooks modify unrelated existing local files, stop and inspect before staging anything.

- [ ] **Step 5: Update the graph**

Run:

```bash
graphify update .
```

Expected: graph update completes. Keep `graphify-out/` untracked unless the repo already tracks those files.

- [ ] **Step 6: Inspect final state**

Run:

```bash
git status --short --branch
git log --oneline -10
```

Expected: only intentional commits from this plan are ahead of `origin/main`; existing unrelated local modifications are still unstaged and untouched.

---

## Self-Review

- Spec coverage: Task 1 covers external Ollama network policy support. Task 2 covers the CrewAI ArgoCD app, values, Temporal queue, KEDA, no RBAC, external Ollama env, and kustomization wiring. Task 3 covers host-managed Ollama setup and operational verification. Task 4 covers Helm, Kustomize, pre-commit, graphify, and final state verification.
- Placeholder scan: No unfinished placeholders, vague error handling, or unspecified file paths remain. Commands include expected outcomes.
- Type and field consistency: `networkPolicy.egress[].toFQDNs`, `CREWAI_TASK_QUEUE`, `host.docker.internal`, `aegis-crewai-worker-mvp`, and `crewai-worker-mvp` are used consistently across tasks.
