#!/usr/bin/env bash
# First deployment of the app: applies k8s/deployment.yaml and k8s/service.yaml.
# Run once before the first Bamboo deployment; after that Bamboo only changes
# the image (scripts/bamboo-deploy.sh). Safe to re-run, e.g. to change the port.
#
# Env vars:
#   NAMESPACE   namespace from nkp/setup.sh (required)
#   IMAGE       initial image (required), e.g. <harbor>/ajb-hr/be:<commit-sha>
#   PORT        container port (required)
set -euo pipefail

: "${NAMESPACE:?NAMESPACE must be set}"
: "${IMAGE:?IMAGE must be set}"
: "${PORT:?PORT must be set}"

cd "$(dirname "$0")/.."

sed -e "s|IMAGE_PLACEHOLDER|${IMAGE}|" -e "s|PORT_PLACEHOLDER|${PORT}|" k8s/deployment.yaml \
  | kubectl -n "${NAMESPACE}" apply -f -
kubectl -n "${NAMESPACE}" apply -f k8s/service.yaml
kubectl -n "${NAMESPACE}" rollout status deployment/chatbot-application --timeout="${ROLLOUT_TIMEOUT:-300s}"
