#!/usr/bin/env bash
# Deploy the nginx demo to a kind cluster, smoke-test it, roll back on failure.
# Used by both GitHub Actions (CI smoke test) and Bamboo (CD).
#
# Env vars:
#   IMAGE                 full image ref (required), e.g. docker.io/anish60/nginx-cicd-demo:sha-abc1234
#   CLUSTER_NAME          kind cluster name (default: cicd-demo)
#   SKIP_CLUSTER_CREATE   "true" if the cluster already exists (CI)
#   PULL_IMAGE            "true" to docker pull IMAGE before loading it into kind (CD)
set -euo pipefail

: "${IMAGE:?IMAGE must be set}"
CLUSTER_NAME="${CLUSTER_NAME:-cicd-demo}"
NAMESPACE="nginx-demo"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

log() { echo -e "\033[1;34m[deploy]\033[0m $*"; }

# 1. Ensure the kind cluster exists
if [[ "${SKIP_CLUSTER_CREATE:-false}" != "true" ]]; then
  if ! kind get clusters | grep -qx "${CLUSTER_NAME}"; then
    log "Creating kind cluster '${CLUSTER_NAME}'"
    kind create cluster --name "${CLUSTER_NAME}" --config "${ROOT_DIR}/kind/kind-config.yaml" --wait 120s
  fi
fi
kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null

# 2. Make the image available inside the cluster nodes
if [[ "${PULL_IMAGE:-false}" == "true" ]]; then
  log "Pulling ${IMAGE}"
  docker pull "${IMAGE}"
fi
log "Loading ${IMAGE} into kind"
kind load docker-image "${IMAGE}" --name "${CLUSTER_NAME}"

# 3. Apply manifests
log "Applying manifests"
kubectl apply -f "${ROOT_DIR}/k8s/namespace.yaml"
kubectl apply -f "${ROOT_DIR}/k8s/service.yaml"
sed "s|IMAGE_PLACEHOLDER|${IMAGE}|" "${ROOT_DIR}/k8s/deployment.yaml" | kubectl apply -f -
kubectl -n "${NAMESPACE}" annotate deployment/nginx-demo \
  kubernetes.io/change-cause="deploy ${IMAGE}" --overwrite >/dev/null

# 4. Wait for rollout; roll back if it doesn't become healthy
if ! kubectl -n "${NAMESPACE}" rollout status deployment/nginx-demo --timeout=120s; then
  log "Rollout failed — rolling back"
  kubectl -n "${NAMESPACE}" rollout undo deployment/nginx-demo || true
  exit 1
fi

# 5. Smoke test from the host via the kind port mapping (localhost:8080)
log "Smoke testing http://localhost:8080"
for i in $(seq 1 20); do
  if curl -fsS http://localhost:8080/healthz >/dev/null 2>&1; then
    tag="${IMAGE##*:}"
    if curl -fsS http://localhost:8080/ | grep -q "${tag}"; then
      log "✅ Healthy and serving version ${tag}"
      exit 0
    fi
  fi
  sleep 3
  log "waiting for service... (${i}/20)"
done

log "❌ Smoke test failed — rolling back"
kubectl -n "${NAMESPACE}" rollout undo deployment/nginx-demo || true
exit 1
