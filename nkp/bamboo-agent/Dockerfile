# Bamboo remote agent that runs as a pod in the NKP cluster.
# Adds kubectl (deploy) and crane (check Docker Hub for CI's image) plus the
# matching Bamboo capabilities. BAMBOO_VERSION must match the Bamboo server.
ARG BAMBOO_VERSION=11.0.7
FROM atlassian/bamboo-agent-base:${BAMBOO_VERSION}

# kubectl must be within one minor version of the NKP cluster (kubectl version)
ARG KUBECTL_VERSION=v1.33.5
ARG CRANE_VERSION=v0.22.1

# Base image starts as root; its entrypoint drops to the bamboo user (uid 2005).
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
 && chmod +x /usr/local/bin/kubectl \
 && curl -fsSL "https://github.com/google/go-containerregistry/releases/download/${CRANE_VERSION}/go-containerregistry_Linux_x86_64.tar.gz" \
    | tar xz -C /usr/local/bin crane

# Capabilities live in the agent home, which is a PVC at runtime, so keep a
# copy outside it and install it on every start (see agent-entrypoint.sh).
RUN /bamboo-update-capability.sh kubectl /usr/local/bin/kubectl \
 && /bamboo-update-capability.sh crane /usr/local/bin/crane \
 && cp "${BAMBOO_AGENT_HOME}/bin/bamboo-capabilities.properties" /opt/bamboo-capabilities.properties
COPY agent-entrypoint.sh /agent-entrypoint.sh

ENTRYPOINT ["/agent-entrypoint.sh", "/pre-launch.sh"]
CMD ["/usr/bin/tini", "--", "/entrypoint.py"]
