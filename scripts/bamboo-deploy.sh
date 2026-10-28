#!/bin/sh
# Bamboo deployment Script task: deploy the image of this release to NKP.
# Paste the whole file into the task (Interpreter: Shell), or run it from a
# checkout. Plain POSIX sh, so it works whichever shell Bamboo uses.
#
# The image tag comes from the Bamboo release name, in one of two ways:
#   tag_from=sha      CI tags images with the commit SHA; the release is named
#                     ${bamboo.planRepository.revision}-${bamboo.buildNumber},
#                     and the tag is the SHA part of it (default)
#   tag_from=release  the release name is the image tag itself, e.g. 1.27.3
#
# Bamboo variables (environment variables of the deployment environment):
#   nkp_kubeconfig_secret  base64 kubeconfig for bamboo-deployer (nkp/setup.sh)
#   image_repo             e.g. harbor-uat.example.com/ajb-hr/be
#   namespace              e.g. hr-chatbot
#   app                    Deployment and container name (default chatbot-application)
#   tag_from               sha or release (see above)
#   tag_length             tag_from=sha: characters of the SHA (0 = full SHA)
#   tag_prefix             tag_from=sha: text before the SHA in the tag, or "none"
#   image_tag              deploy this tag instead of the release's, or "none"
#   rollout_timeout        e.g. 300s
# deploy.release is set by Bamboo.
set -eu

release="${bamboo_deploy_release:?no release (run as a Bamboo deployment)}"
repo="${bamboo_image_repo:?set variable image_repo}"
ns="${bamboo_namespace:?set variable namespace}"
app="${bamboo_app:-chatbot-application}"
tag_from="${bamboo_tag_from:-sha}"
tag_length="${bamboo_tag_length:-0}"
tag_prefix="${bamboo_tag_prefix:-none}"
image_tag="${bamboo_image_tag:-none}"
timeout="${bamboo_rollout_timeout:-300s}"

# Tag: explicit image_tag, else from the release name.
if [ "${image_tag}" != none ]; then
  tag="${image_tag}"
elif [ "${tag_from}" = release ]; then
  tag="${release}"
elif [ "${tag_from}" = sha ]; then
  sha="${release%%-*}"
  if [ "${tag_length}" -gt 0 ]; then
    sha="$(printf '%s' "${sha}" | cut -c1-"${tag_length}")"
  fi
  [ "${tag_prefix}" = none ] && tag_prefix=""
  tag="${tag_prefix}${sha}"
else
  echo "tag_from must be sha or release, not '${tag_from}'" >&2
  exit 1
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
