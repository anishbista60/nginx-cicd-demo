#!/usr/bin/env bash
# One-time NKP setup, run by a cluster admin (current kubeconfig = NKP admin):
#   - the namespace and the bamboo-deployer service account (nkp/rbac.yaml)
#   - optional Harbor pull secret harbor-pull (for a private Harbor project)
#   - a kubeconfig for Bamboo that authenticates as bamboo-deployer
#
# Env vars:
#   NAMESPACE   namespace the app runs in (required)
#   HARBOR_HOST, HARBOR_USERNAME, HARBOR_PASSWORD
#               set all three to create the pull secret (robot account with pull)
#   OUT         kubeconfig to write (default: bamboo-nkp.kubeconfig)
set -euo pipefail

: "${NAMESPACE:?NAMESPACE must be set}"
SA="bamboo-deployer"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT:-bamboo-nkp.kubeconfig}"

log() { echo -e "\033[1;34m[setup]\033[0m $*"; }

log "Creating namespace ${NAMESPACE} and service account ${SA}"
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
sed "s|NAMESPACE_PLACEHOLDER|${NAMESPACE}|g" "${ROOT_DIR}/nkp/rbac.yaml" | kubectl apply -f -

if [[ -n "${HARBOR_HOST:-}" ]]; then
  : "${HARBOR_USERNAME:?HARBOR_USERNAME must be set with HARBOR_HOST}"
  : "${HARBOR_PASSWORD:?HARBOR_PASSWORD must be set with HARBOR_HOST}"
  log "Creating pull secret harbor-pull for ${HARBOR_HOST}"
  kubectl -n "${NAMESPACE}" create secret docker-registry harbor-pull \
    --docker-server="${HARBOR_HOST}" \
    --docker-username="${HARBOR_USERNAME}" \
    --docker-password="${HARBOR_PASSWORD}" \
    --dry-run=client -o yaml | kubectl apply -f -
fi

log "Waiting for the service account token"
token=""
for _ in $(seq 1 30); do
  token="$(kubectl -n "${NAMESPACE}" get secret "${SA}-token" -o jsonpath='{.data.token}' 2>/dev/null || true)"
  [[ -n "${token}" ]] && break
  sleep 1
done
[[ -n "${token}" ]] || { echo "Token for ${SA} was not created"; exit 1; }
ca="$(kubectl -n "${NAMESPACE}" get secret "${SA}-token" -o jsonpath='{.data.ca\.crt}')"
server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"

umask 077
cat > "${OUT}" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: nkp
    cluster:
      server: ${server}
      certificate-authority-data: ${ca}
users:
  - name: ${SA}
    user:
      token: $(echo "${token}" | base64 -d)
contexts:
  - name: ${SA}@nkp
    context:
      cluster: nkp
      user: ${SA}
      namespace: ${NAMESPACE}
current-context: ${SA}@nkp
EOF

log "Checking the new kubeconfig"
KUBECONFIG="${OUT}" kubectl auth can-i patch deployments -n "${NAMESPACE}" >/dev/null
if KUBECONFIG="${OUT}" kubectl auth can-i create namespaces >/dev/null 2>&1; then
  echo "Unexpected: ${SA} can create namespaces"; exit 1
fi

log "Wrote ${OUT} (API server ${server})"
echo
echo "Value for the Bamboo variable nkp_kubeconfig_secret:"
echo "  base64 -w0 ${OUT}"
