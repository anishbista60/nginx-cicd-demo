#!/bin/sh
# Bamboo deployment Script task: deploy the image of this release to NKP.
# Paste the whole file into the task (Interpreter: Shell), or run it from a
# checkout. Plain POSIX sh, so it works whichever shell Bamboo uses.
#
# The release name is the commit SHA (release naming:
# ${bamboo.planRepository.revision}-${bamboo.buildNumber}), and CI tags the
# image with that SHA, so the tag is derived from the release name.
#
# Bamboo variables (environment variables of the deployment environment):
#   nkp_kubeconfig_secret  base64 kubeconfig for bamboo-deployer (nkp/setup.sh)
#   image_repo             e.g. harbor-uat.example.com/ajb-hr/be
#   namespace              e.g. hr-chatbot
#   app                    Deployment and container name (default chatbot-application)
#   tag_length             characters of the SHA used in the tag (0 = full SHA)
#   tag_prefix             text before the SHA in the tag, or "none"
#   image_tag              deploy this tag instead of the release's, or "none"
#   rollout_timeout        e.g. 300s
# deploy.release is set by Bamboo.
set -eu

release="${bamboo_deploy_release:?no release (run as a Bamboo deployment)}"
repo="${bamboo_image_repo:?set variable image_repo}"
ns="${bamboo_namespace:?set variable namespace}"
app="${bamboo_app:-chatbot-application}"
tag_length="${bamboo_tag_length:-0}"
tag_prefix="${bamboo_tag_prefix:-none}"
image_tag="${bamboo_image_tag:-none}"
timeout="${bamboo_rollout_timeout:-300s}"

# Tag: explicit image_tag, else the SHA from the release name ("<sha>-<build>").
if [ "${image_tag}" != none ]; then
  tag="${image_tag}"
else
  sha="${release%%-*}"
  if [ "${tag_length}" -gt 0 ]; then
    sha="$(printf '%s' "${sha}" | cut -c1-"${tag_length}")"
  fi
  [ "${tag_prefix}" = none ] && tag_prefix=""
  tag="${tag_prefix}${sha}"
fi
image="${repo}:${tag}"

# Kubeconfig from the secret variable; without it, the agent's own is used.
if [ -n "${bamboo_nkp_kubeconfig_secret:-}" ]; then
  KUBECONFIG="$(mktemp)"
  export KUBECONFIG
  trap 'rm -f "${KUBECONFIG}"' EXIT
  printf '%s' "${bamboo_nkp_kubeconfig_secret}" | base64 -d > "${KUBECONFIG}"
fi

echo "Release ${release}: deploying ${image} to ${ns}/${app}"
kubectl -n "${ns}" get "deployment/${app}" >/dev/null
kubectl -n "${ns}" set image "deployment/${app}" "${app}=${image}"
kubectl -n "${ns}" annotate "deployment/${app}" --overwrite \
  kubernetes.io/change-cause="Bamboo release ${release}: ${image}" >/dev/null

if ! kubectl -n "${ns}" rollout status "deployment/${app}" --timeout="${timeout}"; then
  echo "Rollout of ${image} failed, rolling back"
  kubectl -n "${ns}" get pods -l "app=${app}" -o wide || true
  kubectl -n "${ns}" get events --sort-by=.lastTimestamp | tail -15 || true
  kubectl -n "${ns}" rollout undo "deployment/${app}"
  kubectl -n "${ns}" rollout status "deployment/${app}" --timeout="${timeout}" || true
  exit 1
fi

echo "Deployed ${image}"
kubectl -n "${ns}" get pods -l "app=${app}" -o wide
