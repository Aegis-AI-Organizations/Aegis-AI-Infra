# External Ollama MVP Design

## Goal

Use Ollama running directly on the MacBook Pro as the MVP LLM runtime for CrewAI, instead of deploying Ollama inside Kubernetes.

This lets local development benefit from Apple Metal acceleration while keeping the Kubernetes side simple enough for Sprint 2.

## Decision

Ollama is external to the cluster for the current MVP.

The Kubernetes cluster does not own an Ollama Deployment, PVC, model pull Job, GPU resource, or node selector. The cluster only runs CrewAI and allows it to reach an externally hosted Ollama HTTP endpoint on port `11434`.

## Local Host Runtime

Ollama runs on macOS using the native runtime so it can use Apple Metal acceleration where supported.

The required models are pulled and maintained on the host:

- `llama3.1:8b`
- `whiterabbitneo`
- `deepseek-coder-v2`

Host setup commands:

```bash
ollama pull llama3.1:8b
ollama pull whiterabbitneo
ollama pull deepseek-coder-v2
ollama list
```

The Ollama server must listen on an address reachable from pods in the local Kubernetes runtime. For OrbStack, the first endpoint to validate is usually:

```text
http://host.docker.internal:11434
```

If that is not reachable from pods, use the Mac LAN IP instead:

```text
http://<mac-lan-ip>:11434
```

## CrewAI Configuration

CrewAI keeps its LLM endpoints configurable through environment variables:

- `PLANNER_API_BASE=<external-ollama-url>`
- `GUIDER_API_BASE=<external-ollama-url>`
- `EXECUTOR_API_BASE=<external-ollama-url>`

For the MVP local profile, use one shared value for all three roles.

The CrewAI worker values should also set the models explicitly:

- `PLANNER_MODEL=llama3.1:8b`
- `GUIDER_MODEL=whiterabbitneo`
- `EXECUTOR_MODEL=deepseek-coder-v2`

## Kubernetes Networking

CrewAI must egress to Temporal on TCP `7233`, external Ollama on TCP `11434`, and DNS.

If the external Ollama endpoint is `host.docker.internal`, the implementation must verify how Cilium resolves and enforces that target in the current cluster. If Cilium network policy cannot express the host endpoint cleanly, Sprint 2 should start with the narrowest working external TCP egress and document the future VM/production policy.

No ingress is added for Ollama from Kubernetes. Ollama is not exposed publicly by Infra.

## Security Constraints

Ollama must remain local/private for MVP development.

Do not expose port `11434` publicly through Cloudflare, ingress, or NodePort.

If using a LAN IP, restrict usage to trusted local network development. This is acceptable for the MVP but not a production deployment pattern.

## Verification

Host-side verification:

```bash
ollama list
curl http://127.0.0.1:11434/api/tags
```

Cluster-side verification from an ephemeral pod:

```bash
kubectl run ollama-probe --rm -i --restart=Never --image=curlimages/curl -- \
  curl -fsS http://host.docker.internal:11434/api/tags
```

If `host.docker.internal` fails, retry with the Mac LAN IP.

CrewAI verification:

- CrewAI worker logs should not return `OLLAMA_UNREACHABLE`.
- `run_crew_pentest` should pass the Ollama probe stage when called in Sprint 3.

## Future GPU/Production Path

When a proper VM or GPU-capable Kubernetes cluster exists, replace this external endpoint with an in-cluster Ollama or model-serving deployment.

That future design can add GPU node selectors, `nvidia.com/gpu` resource requests, model PVCs, a model preloading Job, and a dedicated internal service such as `ollama-mvp.aegis-system.svc.cluster.local:11434`.

Do not add these GPU/in-cluster resources in the current MacBook MVP.

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

## Self-Review

No placeholders remain. The design explicitly chooses external Ollama, defines required host models, gives candidate endpoints, preserves CrewAI configurability, and calls out the network policy caveat around host endpoints. It intentionally avoids adding Kubernetes Ollama resources until a real VM or GPU-capable cluster exists.
