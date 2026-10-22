IMAGE          ?= nginx-cicd-demo:local
# nip.io resolves this name to NKP's Traefik load balancer IP.
BAMBOO_HOST    ?= bamboo.190.170.21.35.nip.io
# Atlassian chart 2.0.17 = Bamboo 12.1.12, for both the server and the agent.
CHART_REPO     := https://atlassian.github.io/data-center-helm-charts
CHART_VERSION  ?= 2.0.17

.PHONY: build nkp-bootstrap nkp-bamboo nkp-agent nkp-status

build:              ## Build the app image locally
	docker build --build-arg APP_VERSION=local -t $(IMAGE) app

nkp-bootstrap:      ## One-time, as NKP admin: namespaces + agent RBAC
	kubectl apply -f k8s/namespace.yaml -f nkp/bamboo-agent/namespace.yaml
	kubectl apply -f nkp/bamboo-agent/rbac.yaml

nkp-bamboo:         ## Bamboo server + PostgreSQL in NKP, behind Traefik at BAMBOO_HOST
	kubectl -n bamboo get secret bamboo-db >/dev/null 2>&1 || \
	  kubectl -n bamboo create secret generic bamboo-db \
	    --from-literal=username=bamboo --from-literal=password=$$(openssl rand -hex 16)
	kubectl -n bamboo get secret bamboo-security-token >/dev/null 2>&1 || \
	  kubectl -n bamboo create secret generic bamboo-security-token \
	    --from-literal=security-token=$$(openssl rand -hex 20)
	kubectl apply -f nkp/bamboo-server/postgres.yaml
	kubectl -n bamboo rollout status statefulset/bamboo-db --timeout=300s
	helm upgrade --install bamboo bamboo --repo $(CHART_REPO) --version $(CHART_VERSION) \
	  -n bamboo -f nkp/bamboo-server/values.yaml --set ingress.host=$(BAMBOO_HOST)
	kubectl -n bamboo rollout status statefulset/bamboo --timeout=600s
	@echo "Bamboo: https://$(BAMBOO_HOST)"

nkp-agent:          ## Bamboo agent in NKP (after the server's setup wizard is done)
	helm upgrade --install bamboo-agent bamboo-agent --repo $(CHART_REPO) --version $(CHART_VERSION) \
	  -n bamboo -f nkp/bamboo-agent/values.yaml
	kubectl -n bamboo rollout status deployment/bamboo-agent --timeout=300s

nkp-status:         ## Show the app, Bamboo and the agent
	kubectl -n nginx-demo get deploy,pods,svc,ingress -o wide
	kubectl -n nginx-demo rollout history deployment/nginx-demo
	kubectl -n bamboo get pods,svc,ingress -o wide
