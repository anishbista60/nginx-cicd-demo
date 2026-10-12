#!/usr/bin/env bash
# Bamboo deployment task: read the release metadata produced by the build
# plan and deploy that exact image to the local kind cluster.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${1:-release/image.env}"

[[ -f "${ENV_FILE}" ]] || { echo "Missing ${ENV_FILE} (artifact not downloaded?)"; exit 1; }
# shellcheck disable=SC1090
source "${ENV_FILE}"

echo "Deploying ${IMAGE} (commit ${GIT_REVISION}) to kind"
IMAGE="${IMAGE}" PULL_IMAGE=true CLUSTER_NAME="${CLUSTER_NAME:-cicd-demo}" \
  "${SCRIPT_DIR}/deploy.sh"
