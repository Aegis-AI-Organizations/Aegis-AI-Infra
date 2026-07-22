.PHONY: setup-dns deploy-local-target delete-local-target e2e-local-loop validate-local-devops-loop

setup-dns:
	bash scripts/setup-dns.sh

deploy-local-target:
	kubectl apply -k kubernetes/local-target

delete-local-target:
	kubectl delete -k kubernetes/local-target --ignore-not-found=true

e2e-local-loop:
	bash scripts/e2e-local-loop.sh

validate-local-devops-loop:
	bash scripts/validate-local-devops-loop.sh
