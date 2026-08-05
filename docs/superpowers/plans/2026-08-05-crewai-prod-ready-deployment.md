# CrewAI Prod-Ready Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Harden CrewAI image release and Kubernetes deployment so a fresh cluster can pull a pinned public GHCR image, deploy the Temporal worker through ArgoCD, and expose CI/security checks before release.

**Architecture:** Keep CrewAI as a Temporal activity worker on `CREWAI_TASK_QUEUE`. Harden `Aegis-AI-Agent-Crew` image/CI first, then extend the generic `aegis-service` Helm chart and CrewAI values in `Aegis-AI-Infra`. Brain/API orchestration is intentionally untouched in this plan.

**Tech Stack:** Python 3.12, uv, pytest, Docker, GitHub Actions, GHCR, Trivy, Syft, Helm, Kustomize, Kubernetes, ArgoCD, KEDA, CiliumNetworkPolicy, Graphify.

## Global Constraints

- Use Superpowers before implementation work; use TDD for bugfixes/features.
- Use Graphify before codebase questions and run `graphify update .` after code changes.
- Do not add destructive CrewAI capabilities.
- Do not add Kubernetes API permissions to the CrewAI pod.
- Do not deploy Ollama in-cluster for the MVP MacBook target.
- Do not replace the existing Pentest worker path in Brain.
- CrewAI GHCR package must be public for production pull simplicity.
- Kubernetes manifests must use pinned image tags and must not use `latest`.
- The worker must remain non-root and should not mount the Kubernetes ServiceAccount token.
- Keep changes minimal and scoped to `Aegis-AI-Agent-Crew` and `Aegis-AI-Infra`.

---

## File Structure

### Aegis-AI-Agent-Crew

- Modify `.github/workflows/build-and-test.yml`: add Docker build, container smoke test, Trivy scan, and SBOM generation to CI.
- Modify `.github/workflows/release.yml`: add release image hardening metadata and public GHCR visibility documentation comments where useful; keep immutable release tag and `latest` convenience tag.
- Modify `tests/test_ci_workflows.py`: add tests asserting CI contains Docker build, smoke test, Trivy, SBOM, and release tag behavior.
- Modify `README.md`: add deployment/release notes for public GHCR, smoke verification, and rollback pointer.
- Keep `Dockerfile`: already includes non-root user and writable `HOME`; only touch if tests reveal missing runtime hardening.

### Aegis-AI-Infra

- Modify `kubernetes/charts/aegis-service/values.yaml`: add defaults for `imagePullSecrets`, `command`, `args`, `podSecurityContext`, and pod labels/annotations.
- Modify `kubernetes/charts/aegis-service/templates/deployment.yaml`: render the new optional fields.
- Modify `kubernetes/charts/aegis-service/templates/serviceaccount.yaml`: render optional `imagePullSecrets` on created service accounts only when configured.
- Modify `kubernetes/charts/aegis-service/templates/scaledobject.yaml`: render `authenticationRef` when KEDA TriggerAuthentication is enabled.
- Modify `kubernetes/envs/mvp/crewai-worker/values.yaml`: document public GHCR, add `imagePullSecrets: []`, add `podSecurityContext`, keep token automount disabled.
- Create `scripts/validate-crewai-deployment.sh`: deterministic render validation for CrewAI pinned image, KEDA queue, Temporal/Ollama egress, and disabled token mount.
- Modify `.pre-commit-config.yaml` if repo hooks should run the new validation script.
- Modify `docs/superpowers/specs/2026-08-05-crewai-prod-ready-deployment-design.md` only if implementation reveals a design correction.

---

### Task 1: Agent-Crew CI Docker Security Gates

**Files:**
- Modify: `/Users/enzogaggiotti/Library/CloudStorage/SynologyDrive-Projets/Epitech/EIP/Aegis AI/Repository/Aegis-AI-Agent-Crew/.worktrees/agent-crew-deployable-image/tests/test_ci_workflows.py`
- Modify: `/Users/enzogaggiotti/Library/CloudStorage/SynologyDrive-Projets/Epitech/EIP/Aegis AI/Repository/Aegis-AI-Agent-Crew/.worktrees/agent-crew-deployable-image/.github/workflows/build-and-test.yml`

**Interfaces:**
- Consumes: existing reusable workflow `Module - Build & Test`.
- Produces: CI steps named `Build Docker image`, `Smoke test Docker image`, `Scan Docker image`, and `Generate SBOM`.

- [ ] **Step 1: Write failing workflow tests**

Add these tests to `tests/test_ci_workflows.py` after `test_dockerfile_sets_writable_home_for_non_root_user`:

```python
def test_build_and_test_validates_docker_image_path():
    workflow = read_workflow("build-and-test.yml")

    assert "docker build -t aegis-ai-agent-crew:ci ." in workflow
    assert "docker run --rm aegis-ai-agent-crew:ci" in workflow
    assert "python -c \"import src.worker; print('worker import ok')\"" in workflow


def test_build_and_test_scans_image_and_generates_sbom():
    workflow = read_workflow("build-and-test.yml")

    assert "aquasecurity/trivy-action" in workflow
    assert "image-ref: aegis-ai-agent-crew:ci" in workflow
    assert "severity: CRITICAL,HIGH" in workflow
    assert "anchore/sbom-action" in workflow
    assert "image: aegis-ai-agent-crew:ci" in workflow
```

- [ ] **Step 2: Run tests and verify they fail**

Run:

```bash
PYTHONPATH=. uv run pytest -q tests/test_ci_workflows.py::test_build_and_test_validates_docker_image_path tests/test_ci_workflows.py::test_build_and_test_scans_image_and_generates_sbom
```

Expected: both tests fail because the workflow does not yet build/smoke/scan the image.

- [ ] **Step 3: Add Docker build, smoke test, Trivy, and SBOM steps**

Append this block to `.github/workflows/build-and-test.yml` after the existing `Run tests` step:

```yaml
      - name: Build Docker image
        run: docker build -t aegis-ai-agent-crew:ci .

      - name: Smoke test Docker image
        run: >-
          docker run --rm aegis-ai-agent-crew:ci
          python -c "import src.worker; print('worker import ok')"

      - name: Scan Docker image
        uses: aquasecurity/trivy-action@0.28.0
        with:
          image-ref: aegis-ai-agent-crew:ci
          format: table
          severity: CRITICAL,HIGH
          ignore-unfixed: true
          exit-code: '1'

      - name: Generate SBOM
        uses: anchore/sbom-action@v0
        with:
          image: aegis-ai-agent-crew:ci
          format: spdx-json
          output-file: sbom.spdx.json
```

- [ ] **Step 4: Run targeted workflow tests and verify they pass**

Run:

```bash
PYTHONPATH=. uv run pytest -q tests/test_ci_workflows.py
```

Expected: workflow tests pass.

- [ ] **Step 5: Run full Agent-Crew verification**

Run:

```bash
uv run python -m compileall src
PYTHONPATH=. uv run pytest -q
docker build -t aegis-ai-agent-crew:ci .
docker run --rm aegis-ai-agent-crew:ci python -c "import src.worker; print('worker import ok')"
git diff --check
graphify update .
```

Expected: compile succeeds, tests pass, Docker build succeeds, smoke test prints `worker import ok`, diff check succeeds, graph updates.

- [ ] **Step 6: Commit Agent-Crew CI gates**

Run:

```bash
git add .github/workflows/build-and-test.yml tests/test_ci_workflows.py
git commit -m "[CI] Add CrewAI image security gates"
```

Expected: one commit containing only the workflow and workflow tests. Do not add `graphify-out/`.

---

### Task 2: Agent-Crew Release and Operator Docs

**Files:**
- Modify: `/Users/enzogaggiotti/Library/CloudStorage/SynologyDrive-Projets/Epitech/EIP/Aegis AI/Repository/Aegis-AI-Agent-Crew/.worktrees/agent-crew-deployable-image/tests/test_ci_workflows.py`
- Modify: `/Users/enzogaggiotti/Library/CloudStorage/SynologyDrive-Projets/Epitech/EIP/Aegis AI/Repository/Aegis-AI-Agent-Crew/.worktrees/agent-crew-deployable-image/.github/workflows/release.yml`
- Modify: `/Users/enzogaggiotti/Library/CloudStorage/SynologyDrive-Projets/Epitech/EIP/Aegis AI/Repository/Aegis-AI-Agent-Crew/.worktrees/agent-crew-deployable-image/README.md`

**Interfaces:**
- Consumes: Docker image tags from release workflow.
- Produces: documented public GHCR requirement and immutable tag usage instructions.

- [ ] **Step 1: Write failing release/doc tests**

Add these tests to `tests/test_ci_workflows.py`:

```python
def test_release_keeps_pinned_tag_and_latest_convenience_tag():
    release = read_workflow("release.yml")

    assert "${{ steps.prep.outputs.image_name }}:${{ steps.tag_gen.outputs.tag }}" in release
    assert "${{ steps.prep.outputs.image_name }}:latest" in release
    assert "Public GHCR package visibility is required" in release


def test_readme_documents_public_ghcr_and_rollback():
    readme = (ROOT / "README.md").read_text(encoding="utf-8")

    assert "ghcr.io/aegis-ai-organizations/aegis-ai-agent-crew" in readme
    assert "public GHCR package" in readme
    assert "Rollback" in readme
    assert "CREWAI_TASK_QUEUE" in readme
```

- [ ] **Step 2: Run tests and verify they fail**

Run:

```bash
PYTHONPATH=. uv run pytest -q tests/test_ci_workflows.py::test_release_keeps_pinned_tag_and_latest_convenience_tag tests/test_ci_workflows.py::test_readme_documents_public_ghcr_and_rollback
```

Expected: fail because release comments/docs are missing.

- [ ] **Step 3: Add release visibility note**

Add this comment before `Build and push Docker image` in `.github/workflows/release.yml`:

```yaml
      # Public GHCR package visibility is required for production clusters to pull
      # pinned images without imagePullSecrets. Configure package visibility in
      # GitHub Packages after the first push; this workflow keeps publishing both
      # immutable release tags and latest as a convenience tag.
```

- [ ] **Step 4: Add README deployment section**

Append this section to `README.md`:

```markdown

## Production Deployment Notes

The deployable image is published to `ghcr.io/aegis-ai-organizations/aegis-ai-agent-crew`.
Production Kubernetes manifests must pin an immutable release tag such as `v2.0.8`; do not deploy `latest`.

The GHCR package must be configured as a public GHCR package so fresh clusters can pull the image without relying on node-local image cache or `imagePullSecrets`.

Runtime defaults:

- `CREWAI_MODE=worker`
- `CREWAI_TASK_QUEUE=CREWAI_TASK_QUEUE`
- `TEMPORAL_HOST=aegis-temporal-mvp-frontend.aegis-system.svc.cluster.local:7233`

Verify deployment with:

```bash
kubectl get deployment crewai-worker-mvp -n aegis-system -o wide
kubectl logs -n aegis-system deployment/crewai-worker-mvp
```

Successful startup logs include `Agent Crew worker started`.

### Rollback

Rollback is performed by changing the pinned image tag in the Infra repository at `kubernetes/envs/mvp/crewai-worker/values.yaml`, then letting ArgoCD sync the previous release tag.
```

- [ ] **Step 5: Run Agent-Crew verification**

Run:

```bash
PYTHONPATH=. uv run pytest -q tests/test_ci_workflows.py
PYTHONPATH=. uv run pytest -q
git diff --check
graphify update .
```

Expected: all tests pass, diff check succeeds, graph updates.

- [ ] **Step 6: Commit release/docs updates**

Run:

```bash
git add .github/workflows/release.yml README.md tests/test_ci_workflows.py
git commit -m "[CHORE] Document CrewAI production image release"
```

Expected: one commit containing release note, README docs, and tests. Do not add `graphify-out/`.

---

### Task 3: Infra Helm Chart Deployment Controls

**Files:**
- Modify: `/Users/enzogaggiotti/Library/CloudStorage/SynologyDrive-Projets/Epitech/EIP/Aegis AI/Repository/Aegis-AI-Infra/.worktrees/crewai-worker-external-ollama/kubernetes/charts/aegis-service/values.yaml`
- Modify: `/Users/enzogaggiotti/Library/CloudStorage/SynologyDrive-Projets/Epitech/EIP/Aegis AI/Repository/Aegis-AI-Infra/.worktrees/crewai-worker-external-ollama/kubernetes/charts/aegis-service/templates/deployment.yaml`
- Modify: `/Users/enzogaggiotti/Library/CloudStorage/SynologyDrive-Projets/Epitech/EIP/Aegis AI/Repository/Aegis-AI-Infra/.worktrees/crewai-worker-external-ollama/kubernetes/charts/aegis-service/templates/serviceaccount.yaml`
- Modify: `/Users/enzogaggiotti/Library/CloudStorage/SynologyDrive-Projets/Epitech/EIP/Aegis AI/Repository/Aegis-AI-Infra/.worktrees/crewai-worker-external-ollama/kubernetes/charts/aegis-service/templates/scaledobject.yaml`

**Interfaces:**
- Consumes: Helm values under `imagePullSecrets`, `command`, `args`, `podSecurityContext`, `podLabels`, `podAnnotations`, and `keda.triggerAuthentication`.
- Produces: rendered Deployment, ServiceAccount, and ScaledObject with optional production controls.

- [ ] **Step 1: Write failing render assertions with shell checks**

Create a temporary values file under `/var/folders/n_/s1s5rqc927s837p4x6n0_g340000gn/T/opencode/aegis-service-render-values.yaml` with:

```yaml
nameOverride: chart-render-test
image:
  repository: example.com/aegis/test
  tag: "v1.2.3"
  pullPolicy: IfNotPresent
imagePullSecrets:
  - name: registry-creds
command:
  - /bin/sh
args:
  - -c
  - sleep 1
podLabels:
  hardening: enabled
podAnnotations:
  checksum/config: abc123
podSecurityContext:
  runAsNonRoot: true
  seccompProfile:
    type: RuntimeDefault
service:
  port: 8080
resources: {}
securityContext: {}
serviceAccount:
  create: true
  automountToken: false
keda:
  enabled: true
  triggerAuthentication:
    enabled: true
    name: chart-render-auth
    spec:
      secretTargetRef: []
  triggers:
    - type: temporal
      metadata:
        taskQueue: TEST_QUEUE
```

Run:

```bash
helm template chart-render-test kubernetes/charts/aegis-service -f /var/folders/n_/s1s5rqc927s837p4x6n0_g340000gn/T/opencode/aegis-service-render-values.yaml > /var/folders/n_/s1s5rqc927s837p4x6n0_g340000gn/T/opencode/aegis-service-render.yaml
rg "imagePullSecrets:|registry-creds|command:|args:|runAsNonRoot: true|hardening: enabled|checksum/config: abc123|authenticationRef:|chart-render-auth" /var/folders/n_/s1s5rqc927s837p4x6n0_g340000gn/T/opencode/aegis-service-render.yaml
```

Expected before implementation: `rg` does not find all required fields.

- [ ] **Step 2: Extend default chart values**

Add these defaults to `kubernetes/charts/aegis-service/values.yaml` after the `image` block:

```yaml
imagePullSecrets: []

command: []
args: []

podLabels: {}
podAnnotations: {}
podSecurityContext: {}
```

- [ ] **Step 3: Render pod labels, annotations, pull secrets, command, args, and pod security context**

Update `kubernetes/charts/aegis-service/templates/deployment.yaml` so the pod template area contains:

```yaml
    template:
      metadata:
        labels:
          app: {{ .Values.nameOverride | default .Release.Name }}
          {{- if .Values.podLabels }}
{{ toYaml .Values.podLabels | indent 10 }}
          {{- end }}
        {{- if or .Values.annotations .Values.podAnnotations }}
        annotations:
          {{- if .Values.annotations }}
{{ toYaml .Values.annotations | indent 10 }}
          {{- end }}
          {{- if .Values.podAnnotations }}
{{ toYaml .Values.podAnnotations | indent 10 }}
          {{- end }}
        {{- end }}
      spec:
        {{- if .Values.podSecurityContext }}
        securityContext:
{{ toYaml .Values.podSecurityContext | indent 10 }}
        {{- end }}
        {{- if .Values.imagePullSecrets }}
        imagePullSecrets:
{{ toYaml .Values.imagePullSecrets | indent 10 }}
        {{- end }}
```

In the container block after `imagePullPolicy`, add:

```yaml
          {{- if .Values.command }}
          command:
{{ toYaml .Values.command | indent 12 }}
          {{- end }}
          {{- if .Values.args }}
          args:
{{ toYaml .Values.args | indent 12 }}
          {{- end }}
```

Ensure the old bottom-level `securityContext: {}` under pod spec is not duplicated when `podSecurityContext` renders.

- [ ] **Step 4: Render imagePullSecrets on created service accounts**

Update `kubernetes/charts/aegis-service/templates/serviceaccount.yaml` to include:

```yaml
{{- if .Values.imagePullSecrets }}
imagePullSecrets:
{{ toYaml .Values.imagePullSecrets | indent 2 }}
{{- end }}
```

Place it after `automountServiceAccountToken`.

- [ ] **Step 5: Wire KEDA authenticationRef**

Update `kubernetes/charts/aegis-service/templates/scaledobject.yaml` after `scaleTargetRef`:

```yaml
  {{- if .Values.keda.triggerAuthentication.enabled }}
  authenticationRef:
    name: {{ .Values.keda.triggerAuthentication.name | default (printf "%s-trigger-auth" (.Values.nameOverride | default .Release.Name)) }}
  {{- end }}
```

- [ ] **Step 6: Verify chart render assertions pass**

Run the same Helm and `rg` commands from Step 1.

Expected: all fields are found in the rendered YAML.

- [ ] **Step 7: Run Infra chart verification**

Run:

```bash
helm template crewai-worker-mvp kubernetes/charts/aegis-service -f kubernetes/envs/mvp/crewai-worker/values.yaml
kubectl kustomize kubernetes/envs/mvp
bash scripts/validate-predictable-deployments.sh
git diff --check
graphify update .
```

Expected: all commands succeed.

- [ ] **Step 8: Commit chart controls**

Run:

```bash
git add kubernetes/charts/aegis-service/values.yaml kubernetes/charts/aegis-service/templates/deployment.yaml kubernetes/charts/aegis-service/templates/serviceaccount.yaml kubernetes/charts/aegis-service/templates/scaledobject.yaml
git commit -m "[FEAT] Add deployment controls to service chart"
```

Expected: one Infra commit containing only generic chart enhancements. Do not add `graphify-out/`.

---

### Task 4: Infra CrewAI Values and Render Validation

**Files:**
- Modify: `/Users/enzogaggiotti/Library/CloudStorage/SynologyDrive-Projets/Epitech/EIP/Aegis AI/Repository/Aegis-AI-Infra/.worktrees/crewai-worker-external-ollama/kubernetes/envs/mvp/crewai-worker/values.yaml`
- Create: `/Users/enzogaggiotti/Library/CloudStorage/SynologyDrive-Projets/Epitech/EIP/Aegis AI/Repository/Aegis-AI-Infra/.worktrees/crewai-worker-external-ollama/scripts/validate-crewai-deployment.sh`
- Modify: `/Users/enzogaggiotti/Library/CloudStorage/SynologyDrive-Projets/Epitech/EIP/Aegis AI/Repository/Aegis-AI-Infra/.worktrees/crewai-worker-external-ollama/.pre-commit-config.yaml` if repository hooks already run local validation scripts.

**Interfaces:**
- Consumes: chart fields from Task 3.
- Produces: CrewAI values with explicit hardening defaults and a deterministic validation script.

- [ ] **Step 1: Write failing validation script call**

Run:

```bash
bash scripts/validate-crewai-deployment.sh
```

Expected before implementation: fails because the script does not exist.

- [ ] **Step 2: Add hardening values**

Add this block to `kubernetes/envs/mvp/crewai-worker/values.yaml` after the `image` block:

```yaml
# GHCR package is expected to be public; imagePullSecrets stays available for
# private registry deployments but is intentionally empty for MVP/prod parity.
imagePullSecrets: []

podSecurityContext:
  runAsNonRoot: true
  seccompProfile:
    type: RuntimeDefault
```

Keep `serviceAccount.automountToken: false` unchanged.

- [ ] **Step 3: Create CrewAI deployment validation script**

Create `scripts/validate-crewai-deployment.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RENDERED="$(mktemp)"
trap 'rm -f "${RENDERED}"' EXIT

helm template crewai-worker-mvp \
  "${ROOT_DIR}/kubernetes/charts/aegis-service" \
  -f "${ROOT_DIR}/kubernetes/envs/mvp/crewai-worker/values.yaml" \
  > "${RENDERED}"

require() {
  local pattern="$1"
  local description="$2"
  if ! grep -Fq "${pattern}" "${RENDERED}"; then
    echo "CrewAI deployment validation failed: missing ${description}" >&2
    echo "Pattern: ${pattern}" >&2
    exit 1
  fi
}

reject() {
  local pattern="$1"
  local description="$2"
  if grep -Fq "${pattern}" "${RENDERED}"; then
    echo "CrewAI deployment validation failed: forbidden ${description}" >&2
    echo "Pattern: ${pattern}" >&2
    exit 1
  fi
}

require "image: \"ghcr.io/aegis-ai-organizations/aegis-ai-agent-crew:v" "pinned CrewAI GHCR image"
reject "aegis-ai-agent-crew:latest" "latest CrewAI image tag"
require "automountServiceAccountToken: false" "disabled service account token mount"
require "runAsNonRoot: true" "non-root pod security context"
require "type: RuntimeDefault" "RuntimeDefault seccomp profile"
require "kind: ScaledObject" "KEDA ScaledObject"
require "taskQueue: CREWAI_TASK_QUEUE" "CrewAI Temporal task queue scaler"
require "serviceName: aegis-temporal-mvp-frontend" "Temporal egress service"
require "matchName: host.docker.internal" "external Ollama FQDN egress"
require "port: 11434" "Ollama TCP egress port"
require "port: 7233" "Temporal TCP egress port"

echo "CrewAI deployment validation passed"
```

- [ ] **Step 4: Make script executable**

Run:

```bash
chmod +x scripts/validate-crewai-deployment.sh
```

Expected: file mode is executable.

- [ ] **Step 5: Add pre-commit hook if local validation hooks exist**

If `.pre-commit-config.yaml` already contains local validation hooks, add:

```yaml
      - id: validate-crewai-deployment
        name: Validate CrewAI deployment render
        entry: bash scripts/validate-crewai-deployment.sh
        language: system
        pass_filenames: false
```

If no local hook section exists, skip this step and rely on direct script invocation.

- [ ] **Step 6: Verify validation passes**

Run:

```bash
bash scripts/validate-crewai-deployment.sh
helm template crewai-worker-mvp kubernetes/charts/aegis-service -f kubernetes/envs/mvp/crewai-worker/values.yaml
kubectl kustomize kubernetes/envs/mvp
bash scripts/validate-predictable-deployments.sh
pre-commit run --all-files
git diff --check
graphify update .
```

Expected: validation prints `CrewAI deployment validation passed`; all existing checks pass.

- [ ] **Step 7: Commit CrewAI values and validation**

Run:

```bash
git add kubernetes/envs/mvp/crewai-worker/values.yaml scripts/validate-crewai-deployment.sh .pre-commit-config.yaml
git commit -m "[CHORE] Validate CrewAI deployment hardening"
```

Expected: one Infra commit containing CrewAI values hardening and validation. If `.pre-commit-config.yaml` was not changed, omit it from `git add`.

---

### Task 5: Runtime Verification and Push

**Files:**
- No required file changes.
- Optional docs correction only if verification reveals an inaccurate instruction.

**Interfaces:**
- Consumes: Agent-Crew pushed image workflow changes and Infra deployment hardening commits.
- Produces: verified local cluster state and pushed branches.

- [ ] **Step 1: Verify Agent-Crew branch state**

Run in Agent-Crew worktree:

```bash
git status --short --branch
git log --oneline -5
```

Expected: only intentional untracked `graphify-out/` or known mode-only changes remain unstaged; new commits are visible.

- [ ] **Step 2: Push Agent-Crew branch**

Run:

```bash
git push
```

Expected: `origin/agent-crew-deployable-image` receives the Agent-Crew commits.

- [ ] **Step 3: Verify Infra branch state**

Run in Infra worktree:

```bash
git status --short --branch
git log --oneline -5
```

Expected: only `.superpowers/` and `graphify-out/` remain untracked.

- [ ] **Step 4: Push Infra branch**

Run:

```bash
git push
```

Expected: `origin/crewai-worker-external-ollama` receives the Infra commits.

- [ ] **Step 5: Verify current cluster deployment**

Run:

```bash
kubectl get deployment crewai-worker-mvp -n aegis-system -o wide
kubectl get pods -n aegis-system -l app=crewai-worker-mvp -o wide
kubectl logs -n aegis-system deployment/crewai-worker-mvp
```

Expected: deployment is `1/1`, pod is `Running`, logs include `Agent Crew worker started`.

- [ ] **Step 6: Verify Ollama reachability from cluster**

Run:

```bash
kubectl run ollama-probe --rm -i --restart=Never --image=curlimages/curl -- curl -fsS http://host.docker.internal:11434/api/tags
```

Expected: command exits 0 and returns Ollama tags JSON.

- [ ] **Step 7: Final status summary**

Run:

```bash
git status --short --branch
```

Expected: report exact remaining untracked/generated files and pushed branch names.

---

## Self-Review

### Spec Coverage

- Public GHCR and pinned tags: Tasks 2 and 4.
- Agent-Crew Docker CI, smoke test, scanner, SBOM: Task 1.
- Agent-Crew release/docs: Task 2.
- Helm `imagePullSecrets`, `command`, `args`, `podSecurityContext`, pod metadata, KEDA auth: Task 3.
- CrewAI values hardening and render validation: Task 4.
- Runtime verification and push: Task 5.
- Brain integration deferred: captured in global constraints and intentionally absent from tasks.

### Placeholder Scan

No placeholder markers or undefined implementation placeholders are present. Optional pre-commit wiring is conditional because it depends on the existing file structure and has an explicit skip path.

### Type and Name Consistency

The plan consistently uses `CREWAI_TASK_QUEUE`, `crewai-worker-mvp`, `aegis-ai-agent-crew:ci`, `imagePullSecrets`, `podSecurityContext`, and `authenticationRef` across tasks.
