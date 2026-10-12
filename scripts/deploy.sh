#!/usr/bin/env bash
# Deploy the nginx demo to the current Kubernetes cluster, smoke-test it, and
# roll back on failure. Used by Bamboo (agent pod inside NKP, in-cluster
# service account); also works from a workstation with a kubeconfig.
#
# The namespace must already exist (k8s/namespace.yaml, applied by an admin).
#
# Env vars:
#   IMAGE           full image ref (required), e.g. docker.io/anish60/nginx-cicd-demo:sha-abc1234
#   SMOKE_URL       base URL to test, e.g. http://nginx-demo.nginx-demo.svc.cluster.local
#                   (default: kubectl port-forward to the Service)
#   INGRESS_HOST    if set, also apply k8s/ingress.yaml for this host
#   INGRESS_CLASS   ingress class (default: kommander-traefik)
set -euo pipefail

: "${IMAGE:?IMAGE must be set}"
NAMESPACE="nginx-demo"
INGRESS_CLASS="${INGRESS_CLASS:-kommander-traefik}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

log() { echo -e "\033[1;34m[deploy]\033[0m $*"; }

rollback() {
  log "$1 — rolling back"
  kubectl -n "${NAMESPACE}" rollout undo deployment/nginx-demo || true
  exit 1
}

# 1. Apply manifests
log "Applying manifests for ${IMAGE}"
kubectl apply -f "${ROOT_DIR}/k8s/service.yaml"
sed "s|IMAGE_PLACEHOLDER|${IMAGE}|" "${ROOT_DIR}/k8s/deployment.yaml" | kubectl apply -f -
kubectl -n "${NAMESPACE}" annotate deployment/nginx-demo \
  kubernetes.io/change-cause="deploy ${IMAGE}" --overwrite >/dev/null
if [[ -n "${INGRESS_HOST:-}" ]]; then
  sed -e "s|INGRESS_HOST_PLACEHOLDER|${INGRESS_HOST}|" \
      -e "s|INGRESS_CLASS_PLACEHOLDER|${INGRESS_CLASS}|" \
      "${ROOT_DIR}/k8s/ingress.yaml" | kubectl apply -f -
fi

# 2. Wait for rollout
if ! kubectl -n "${NAMESPACE}" rollout status deployment/nginx-demo --timeout=180s; then
  kubectl -n "${NAMESPACE}" get pods -o wide || true
  rollback "Rollout failed"
fi

# 3. Smoke test: healthy and serving the version we just deployed
if [[ -z "${SMOKE_URL:-}" ]]; then
  pf_log="$(mktemp)"
  kubectl -n "${NAMESPACE}" port-forward svc/nginx-demo 18080:80 >"${pf_log}" 2>&1 &
  pf_pid=$!
  trap 'kill ${pf_pid} 2>/dev/null || true; rm -f "${pf_log}"' EXIT
  SMOKE_URL="http://127.0.0.1:18080"
  sleep 2
  kill -0 "${pf_pid}" 2>/dev/null || { cat "${pf_log}"; rollback "port-forward failed (set SMOKE_URL?)"; }
fi

tag="${IMAGE##*:}"
log "Smoke testing ${SMOKE_URL} (expecting version ${tag})"
for i in $(seq 1 20); do
  if curl -fsS "${SMOKE_URL}/healthz" >/dev/null 2>&1 \
     && curl -fsS "${SMOKE_URL}/" | grep -q "${tag}"; then
    log "✅ Healthy and serving version ${tag}"
    exit 0
  fi
  sleep 3
  log "waiting for service... (${i}/20)"
done

rollback "❌ Smoke test failed"
