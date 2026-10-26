# Rehearse the Bamboo → NKP deployment from any machine with kubectl.
# Override on the command line, e.g. make deploy RELEASE=<commit-sha>-1
NAMESPACE      ?= hr-chatbot
APP            ?= hr-chatbot-be
IMAGE_REPO     ?= harbor-uat.example.com/ajb-hr/be
TAG_LENGTH     ?= 0
TAG_PREFIX     ?= none
PORT           ?= 8080
HEALTH_PATH    ?=
INGRESS_HOST   ?=
KUBECONFIG_OUT ?= bamboo-nkp.kubeconfig

.PHONY: nkp-setup app deploy status

nkp-setup:          ## One-time, as NKP admin: namespace, bamboo-deployer, pull secret, kubeconfig
	NAMESPACE=$(NAMESPACE) OUT=$(KUBECONFIG_OUT) ./nkp/setup.sh

app:                ## First-time app manifests: make app IMAGE=<repo>:<tag> [PORT= HEALTH_PATH= INGRESS_HOST=]
	@test -n "$(IMAGE)" || { echo "IMAGE is required"; exit 1; }
	KUBECONFIG=$(KUBECONFIG_OUT) NAMESPACE=$(NAMESPACE) APP=$(APP) IMAGE=$(IMAGE) PORT=$(PORT) \
	  HEALTH_PATH=$(HEALTH_PATH) INGRESS_HOST=$(INGRESS_HOST) ./scripts/apply-app.sh

deploy:             ## Exactly what Bamboo runs: make deploy RELEASE=<commit-sha>-<build>
	@test -n "$(RELEASE)" || { echo "RELEASE is required"; exit 1; }
	bamboo_deploy_release=$(RELEASE) \
	bamboo_nkp_kubeconfig_secret=$$(base64 -w0 $(KUBECONFIG_OUT)) \
	bamboo_image_repo=$(IMAGE_REPO) bamboo_namespace=$(NAMESPACE) bamboo_app=$(APP) \
	bamboo_tag_length=$(TAG_LENGTH) bamboo_tag_prefix=$(TAG_PREFIX) \
	  sh ./scripts/bamboo-deploy.sh

status:             ## Pods and rollout history
	KUBECONFIG=$(KUBECONFIG_OUT) kubectl -n $(NAMESPACE) get deploy,pods,svc,ingress -o wide
	KUBECONFIG=$(KUBECONFIG_OUT) kubectl -n $(NAMESPACE) rollout history deployment/$(APP)
