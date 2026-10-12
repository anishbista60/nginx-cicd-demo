CLUSTER ?= cicd-demo
IMAGE   ?= nginx-cicd-demo:local

.PHONY: cluster build deploy test clean bamboo-up bamboo-down

cluster:            ## Create the local kind cluster
	kind get clusters | grep -qx $(CLUSTER) || \
	  kind create cluster --name $(CLUSTER) --config kind/kind-config.yaml --wait 120s

build:              ## Build the image locally
	docker build --build-arg APP_VERSION=local -t $(IMAGE) app

deploy: cluster build   ## Deploy a local build (no CI/CD) to kind
	IMAGE=$(IMAGE) CLUSTER_NAME=$(CLUSTER) ./scripts/deploy.sh

test:               ## Hit the app
	curl -fsS http://localhost:8080/healthz && curl -s http://localhost:8080 | grep -o 'Version: <code>[^<]*'

bamboo-up:          ## Start local Bamboo server
	docker compose -f bamboo/docker-compose.yml up -d

bamboo-down:
	docker compose -f bamboo/docker-compose.yml down

clean:              ## Delete the kind cluster
	kind delete cluster --name $(CLUSTER)
