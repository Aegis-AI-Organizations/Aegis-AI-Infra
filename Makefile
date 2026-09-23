.PHONY: setup-dns deploy-local-target delete-local-target build-local-mvp-images e2e-local-loop e2e-local-loop-port-forward temporal-list-graph-pentest-workflows temporal-cleanup-stale-graph-pentest-workflows validate-local-devops-loop

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

temporal-list-graph-pentest-workflows:
	bash scripts/temporal-list-graph-pentest-workflows.sh

temporal-cleanup-stale-graph-pentest-workflows:
	bash scripts/temporal-cleanup-stale-graph-pentest-workflows.sh

validate-local-devops-loop:
	bash scripts/validate-local-devops-loop.sh
