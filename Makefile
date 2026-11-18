.PHONY: setup-dns deploy-local-target delete-local-target build-local-mvp-images e2e-local-loop e2e-local-loop-port-forward verify-demo-readiness verify-mvp-pipeline verify-mvp-redeploy-resilience verify-mvp-fresh-cluster temporal-list-graph-pentest-workflows temporal-cleanup-stale-graph-pentest-workflows validate-local-devops-loop validate dev-create dev-build dev-deploy dev-deploy-argocd dev-status dev-logs dev-destroy render-dev render-prod prod-render

PROFILE ?= dev-core

# --- dev/prod split (see docs/en/kubernetes.md and docs/fr/kubernetes.md) ---

validate:
	bash scripts/validate-envs.sh

dev-create:
	bash scripts/dev-create.sh

dev-build:
	PROFILE=$(PROFILE) bash scripts/dev-build-images.sh

dev-deploy:
	PROFILE=$(PROFILE) bash scripts/dev-deploy.sh

dev-deploy-argocd:
	bash scripts/dev-deploy-argocd.sh

dev-status:
	bash scripts/dev-status.sh

dev-logs:
	bash scripts/dev-logs.sh

dev-destroy:
	bash scripts/dev-destroy.sh

render-dev:
	bash scripts/render-env.sh dev/$(PROFILE)

render-prod:
	bash scripts/render-env.sh prod

# Kept distinct from render-prod for discoverability under the "prod-*" name
# operators will reach for.
prod-render: render-prod

setup-dns:
	bash scripts/setup-dns.sh

deploy-local-target:
	kubectl apply -k kubernetes/local-target

delete-local-target:
	kubectl delete -k kubernetes/local-target --ignore-not-found=true

build-local-mvp-images:
	bash scripts/build-local-mvp-images.sh

e2e-local-loop:
	bash scripts/e2e-local-loop.sh

e2e-local-loop-port-forward:
	bash scripts/e2e-local-loop-port-forward.sh

verify-demo-readiness:
	bash scripts/verify-demo-readiness.sh

verify-mvp-pipeline:
	bash scripts/verify-mvp-pipeline.sh

verify-mvp-redeploy-resilience:
	bash scripts/verify-mvp-redeploy-resilience.sh

verify-mvp-fresh-cluster:
	bash scripts/verify-mvp-fresh-cluster.sh

temporal-list-graph-pentest-workflows:
	bash scripts/temporal-list-graph-pentest-workflows.sh

temporal-cleanup-stale-graph-pentest-workflows:
	bash scripts/temporal-cleanup-stale-graph-pentest-workflows.sh

validate-local-devops-loop:
	bash scripts/validate-local-devops-loop.sh
