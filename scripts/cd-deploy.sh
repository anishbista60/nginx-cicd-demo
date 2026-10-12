#!/usr/bin/env bash
# Bamboo deployment task: read the release metadata produced by the build
# plan and deploy that exact image to the NKP cluster the agent runs in.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${1:-release/image.env}"

[[ -f "${ENV_FILE}" ]] || { echo "Missing ${ENV_FILE} (artifact not downloaded?)"; exit 1; }
# shellcheck disable=SC1090
source "${ENV_FILE}"

echo "Deploying ${IMAGE} (commit ${GIT_REVISION}) to NKP"
IMAGE="${IMAGE}" \
SMOKE_URL="${SMOKE_URL:-http://nginx-demo.nginx-demo.svc.cluster.local}" \
  "${SCRIPT_DIR}/deploy.sh"
