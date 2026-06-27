# Makefile
# Convenience targets for common tasks.
# Usage: make <target>

HELM_CHART   := helm/vllm-stack
RELEASE      := vllm-stack
NAMESPACE    := llm-inference

.PHONY: help bootstrap deps lint test validate deploy-dev deploy-staging deploy-prod rollback status smoke

help:
	@echo "LLM Inference Platform"
	@echo ""
	@echo "Setup:"
	@echo "  make bootstrap         Install cluster dependencies (one-time)"
	@echo "  make deps              Pull Helm chart dependencies"
	@echo ""
	@echo "Development:"
	@echo "  make lint              Lint Helm chart against all environments"
	@echo "  make test              Run Helm unit tests"
	@echo "  make validate          Validate rendered YAML with kubeconform"
	@echo ""
	@echo "Deploy:"
	@echo "  make deploy-dev        Deploy to dev"
	@echo "  make deploy-staging    Deploy to staging"
	@echo "  make deploy-prod       Deploy to prod (requires approval)"
	@echo "  make rollback          Roll back last release"
	@echo ""
	@echo "Operations:"
	@echo "  make status            Show platform health"
	@echo "  make smoke ENV=dev     Run smoke tests"
	@echo "  make logs              Tail engine logs"

bootstrap:
	bash scripts/bootstrap.sh

deps:
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
	helm repo update
	helm dependency build $(HELM_CHART)/

lint: deps
	helm lint $(HELM_CHART)/
	helm lint $(HELM_CHART)/ -f environments/dev/values.yaml
	helm lint $(HELM_CHART)/ -f environments/staging/values.yaml
	helm lint $(HELM_CHART)/ -f environments/prod/values.yaml
	@echo "✅ All lint checks passed"

test: deps
	helm unittest $(HELM_CHART)/ --file tests/helm-unit-tests/*.yaml

validate: deps
	@for env in dev staging prod; do \
		echo "Validating $$env..."; \
		helm template $(RELEASE) $(HELM_CHART)/ \
			-f environments/$$env/values.yaml \
			--namespace $(NAMESPACE) \
		| kubeconform \
			-kubernetes-version 1.29.0 \
			-schema-location default \
			-ignore-missing-schemas \
			-summary; \
	done
	@echo "✅ All manifests valid"

deploy-dev: lint
	bash scripts/helpers.sh deploy dev

deploy-staging: lint test
	bash scripts/helpers.sh deploy staging

deploy-prod: lint test validate
	@echo "⚠️  Deploying to PRODUCTION. This requires a second approval."
	@read -rp "Type 'yes-deploy-prod' to continue: " confirm; \
	[ "$$confirm" = "yes-deploy-prod" ] || (echo "Aborted." && exit 1)
	bash scripts/helpers.sh deploy prod

rollback:
	bash scripts/helpers.sh rollback

status:
	bash scripts/helpers.sh status

smoke:
	bash scripts/smoke-test.sh $(ENV)

logs:
	bash scripts/helpers.sh logs
