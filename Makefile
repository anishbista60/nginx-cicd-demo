IMAGE          ?= nginx-cicd-demo:local
AGENT_IMAGE    ?= docker.io/anish60/bamboo-agent-k8s:11.0.7
BAMBOO_SERVER  ?=

.PHONY: build agent-image nkp-bootstrap nkp-agent nkp-status bamboo-up bamboo-down

build:              ## Build the app image locally
	docker build --build-arg APP_VERSION=local -t $(IMAGE) app

agent-image:        ## Build the Bamboo agent image locally (CI publishes it)
	docker build -t $(AGENT_IMAGE) nkp/bamboo-agent

nkp-bootstrap:      ## One-time, as NKP admin: namespaces + agent RBAC
	kubectl apply -f k8s/namespace.yaml -f nkp/bamboo-agent/namespace.yaml
	kubectl apply -f nkp/bamboo-agent/rbac.yaml

nkp-agent:          ## Run the Bamboo agent in NKP: make nkp-agent BAMBOO_SERVER=http://host:8085
	@test -n "$(BAMBOO_SERVER)" || { echo "BAMBOO_SERVER is required"; exit 1; }
	sed "s|BAMBOO_SERVER_URL|$(BAMBOO_SERVER)|" nkp/bamboo-agent/agent.yaml | kubectl apply -f -
	kubectl -n bamboo rollout status deployment/bamboo-agent --timeout=300s

nkp-status:         ## Show the app and the agent
	kubectl -n nginx-demo get deploy,pods,svc,ingress -o wide
	kubectl -n nginx-demo rollout history deployment/nginx-demo
	kubectl -n bamboo get pods -o wide

bamboo-up:          ## Start the Bamboo server with docker compose
	docker compose -f bamboo/docker-compose.yml up -d

bamboo-down:
	docker compose -f bamboo/docker-compose.yml down
