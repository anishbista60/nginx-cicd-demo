#!/bin/bash
# Install the image's capabilities into the (persistent) agent home, then hand
# over to the stock entrypoint.
set -euo pipefail
mkdir -p "${BAMBOO_AGENT_HOME}/bin"
cp /opt/bamboo-capabilities.properties "${BAMBOO_AGENT_HOME}/bin/bamboo-capabilities.properties"
chown -R "${RUN_USER}:${RUN_GROUP}" "${BAMBOO_AGENT_HOME}"
exec "$@"
