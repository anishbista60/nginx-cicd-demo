#!/usr/bin/env bash
# Bamboo build stage: wait until GitHub Actions has published the image for
# this commit, then write image.env as a shared artifact for the deployment.
#
# Env vars:
#   GIT_REVISION   full commit SHA (Bamboo: ${bamboo.planRepository.revision})
#   IMAGE_REPO     e.g. docker.io/anish60/nginx-cicd-demo
#   TIMEOUT_SEC    how long to wait for CI (default 900)
set -euo pipefail

: "${GIT_REVISION:?GIT_REVISION must be set}"
: "${IMAGE_REPO:?IMAGE_REPO must be set}"
TIMEOUT_SEC="${TIMEOUT_SEC:-900}"

TAG="sha-${GIT_REVISION:0:7}"
IMAGE="${IMAGE_REPO}:${TAG}"

echo "Waiting for CI to publish ${IMAGE} (timeout ${TIMEOUT_SEC}s)"
deadline=$(( $(date +%s) + TIMEOUT_SEC ))
until crane manifest "${IMAGE}" >/dev/null 2>&1; do
  if (( $(date +%s) > deadline )); then
    echo "Timed out: ${IMAGE} not found. Did the GitHub Actions CI run fail?"
    exit 1
  fi
  sleep 20
done

echo "Found ${IMAGE}"
mkdir -p release
printf 'IMAGE=%s\nTAG=%s\nGIT_REVISION=%s\n' "${IMAGE}" "${TAG}" "${GIT_REVISION}" > release/image.env
cat release/image.env
