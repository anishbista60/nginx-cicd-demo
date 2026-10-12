# nginx CI/CD on Kubernetes — GitHub Actions + Bamboo

## Overview

A demo pipeline that builds a small nginx web app and deploys it to a Kubernetes cluster.

- **CI — GitHub Actions:** on every push to `main`, build the Docker image and push it to Docker Hub.
- **CD — Bamboo:** detects the new commit, waits for that exact image tag, deploys it to Kubernetes, smoke-tests it, and rolls back automatically on failure.
- **Contract between CI and CD:** the image tag `sha-<first 7 chars of commit>`.
- **Bamboo agent:** runs as a pod inside the cluster and deploys using its own service account (no kubeconfig stored anywhere).

| What | Link |
|---|---|
| GitHub repo | https://github.com/anishbista60/nginx-cicd-demo |
| GitHub Actions runs | https://github.com/anishbista60/nginx-cicd-demo/actions |
| Docker Hub image | https://hub.docker.com/r/anish60/nginx-cicd-demo |
| Bamboo agent image (official) | https://hub.docker.com/r/atlassian/bamboo-agent-base |

## Status

**Where we are**

- [x] The repo is public: https://github.com/anishbista60/nginx-cicd-demo
- [x] CI with GitHub Actions is working. Every push to `main` builds the image and pushes it to Docker Hub as `anish60/nginx-cicd-demo:sha-<commit>`.
- [x] The Kubernetes cluster is ready (4 nodes, v1.33.5).
- [x] The Bamboo agent runs as a pod in the cluster and can reach the Bamboo server. Its deploy permissions are limited to the app's namespace.
- [ ] **Bamboo license — blocked**
- [ ] Approve the agent, import the Bamboo Specs, end-to-end test

**Blocker: Bamboo license**

We can't activate the Bamboo server without a license. Atlassian stopped issuing self-service Data Center trial licenses on March 30, 2026. Bamboo itself is not being retired: Atlassian says it will continue beyond 2029 through the Bitbucket Hybrid License. That means we would need to get a license through Atlassian sales or a partner.

- Trial licenses: https://confluence.atlassian.com/display/BAMBOO/Get+a+Bamboo+Data+Center+trial+license
- Bamboo licensing: https://www.atlassian.com/licensing/bamboo
- Data Center end of life (Bamboo excluded): https://www.atlassian.com/licensing/data-center-end-of-life

> **Until we have a license, we can't move forward.** The Bamboo server stays on the license setup page, so the agent can't register and no deployments can run. Everything up to that point is built and ready.

**Next steps**

1. **Check internally.** Do we, or the client, already have a Bamboo Data Center license, or any Atlassian Data Center product? If we do, we may count as an existing customer, which makes buying easier.
2. **If not, contact Atlassian sales or an Atlassian Solution Partner** (pending approval). Ask them:
   - Can we buy Bamboo Data Center today, either standalone or through the Bitbucket Hybrid License?
   - Can we get an evaluation license for this demo?
3. **Once we have the license:** activate the server, approve the agent, import the pipeline and run the end-to-end test (push → build → deploy). That should take about a day.
4. **If we can't get a license in reasonable time:** move the CD part to a free tool that runs inside the cluster, such as Argo CD. The CI side stays as it is.

**Decision needed:** contact Atlassian or a partner about a Bamboo license (step 2), or use an existing license if one is available.

## Architecture

```
git push ──► GitHub Actions (CI)
             └─ build image ─► push docker.io/anish60/nginx-cicd-demo:sha-<commit> + :latest
                                            │
Bamboo server                               │
 ├─ Plan NGX-CICD: polls repo every 60s, waits for the image tag
 └─ Deployment environment ─────────────────┘
       runs on: Bamboo agent pod (namespace bamboo)
       ├─ kubectl apply Deployment + Service (+ Ingress)
       ├─ kubectl rollout status
       ├─ smoke test: /healthz + page shows the deployed version
       └─ automatic rollback on failure
                    │
          Kubernetes, namespace nginx-demo
```

## Prerequisites

- A Kubernetes cluster and `kubectl` with cluster-admin access (only needed for the one-time setup).
- A default StorageClass (the Bamboo agent uses a 5Gi volume).
- Cluster nodes can pull from Docker Hub and reach `dl.k8s.io` and `github.com`.
- A host with Docker for the Bamboo server, reachable from the cluster on ports **8085** and **54663**.
- A **Bamboo Data Center license** (self-service trial licenses are no longer issued since 30 Mar 2026 — get one via Atlassian sales or a partner).
- Docker Hub account and a Docker Hub access token.

---

## Step 1 — Application image

Three files under `app/`.

**`app/Dockerfile`** — non-root nginx on port 8080; the version is baked into the page at build time.

```dockerfile
# Non-root nginx image listening on 8080
FROM nginxinc/nginx-unprivileged:1.27-alpine

ARG APP_VERSION=dev
LABEL org.opencontainers.image.title="nginx-cicd-demo" \
      org.opencontainers.image.version="${APP_VERSION}"

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY html/ /usr/share/nginx/html/

USER root
RUN sed -i "s/__APP_VERSION__/${APP_VERSION}/g" /usr/share/nginx/html/index.html
USER 101

EXPOSE 8080
```

**`app/nginx.conf`** — serves the page and a `/healthz` endpoint for probes.

```nginx
server {
    listen       8080;
    server_name  _;

    root   /usr/share/nginx/html;
    index  index.html;

    # Liveness / readiness probe endpoint
    location = /healthz {
        access_log off;
        default_type text/plain;
        return 200 "ok\n";
    }

    location / {
        try_files $uri $uri/ =404;
    }
}
```

**`app/html/index.html`** — `__APP_VERSION__` is replaced with the image tag, so the smoke test can verify which version is live.

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>nginx CI/CD demo</title>
  <style>
    body { font-family: system-ui, sans-serif; background:#0f172a; color:#e2e8f0;
           display:flex; align-items:center; justify-content:center; height:100vh; margin:0; }
    .card { background:#1e293b; padding:2rem 3rem; border-radius:12px; text-align:center; }
    code { color:#38bdf8; }
  </style>
</head>
<body>
  <div class="card">
    <h1>Hello from nginx on kind 🚀</h1>
    <p>CI: GitHub Actions &nbsp;|&nbsp; CD: Bamboo</p>
    <p>Version: <code>__APP_VERSION__</code></p>
  </div>
</body>
</html>
```

Optional local check:

```bash
docker build --build-arg APP_VERSION=local -t nginx-cicd-demo:local app
docker run --rm -p 8080:8080 nginx-cicd-demo:local
curl localhost:8080/healthz     # ok
```

---

## Step 2 — CI: GitHub Actions

**2.1 Add repository secrets** in GitHub → Settings → Secrets and variables → Actions:

| Secret | Value |
|---|---|
| `DOCKERHUB_USERNAME` | `anish60` |
| `DOCKERHUB_TOKEN` | Docker Hub access token (Read & Write), starts with `dckr_pat_` |

**2.2 Create `.github/workflows/ci.yml`:**

```yaml
name: CI

on:
  push:
    branches: [main]
    paths-ignore: ["**.md"]
  workflow_dispatch:

env:
  REGISTRY: docker.io
  IMAGE_NAME: anish60/nginx-cicd-demo

permissions:
  contents: read

jobs:
  # Build the image and push it to Docker Hub — Bamboo picks it up from here
  build-push:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Compute image tag
        id: vars
        run: echo "tag=sha-${GITHUB_SHA::7}" >> "$GITHUB_OUTPUT"

      - uses: docker/setup-buildx-action@v3

      - uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ secrets.DOCKERHUB_USERNAME }}
          password: ${{ secrets.DOCKERHUB_TOKEN }}

      - name: Build & push
        uses: docker/build-push-action@v6
        with:
          context: app
          push: true
          build-args: APP_VERSION=${{ steps.vars.outputs.tag }}
          tags: |
            ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:${{ steps.vars.outputs.tag }}
            ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:latest
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

**2.3 Verify:** push to `main` → the **CI** workflow goes green → Docker Hub shows tags `sha-<commit>` and `latest`. Make sure the Docker Hub repo is **public** so the cluster can pull without credentials.

---

## Step 3 — Kubernetes: application namespace

**`k8s/namespace.yaml`**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: nginx-demo
```

```bash
kubectl apply -f k8s/namespace.yaml
```

> The namespace is created once by an admin. The Bamboo agent is not allowed to create namespaces.

---

## Step 4 — Kubernetes: application manifests

These are applied by Bamboo on every deployment. You can apply them by hand once to test.

**`k8s/deployment.yaml`** — 2 replicas, zero-downtime rolling update, probes, resource limits, hardened security context. `IMAGE_PLACEHOLDER` is replaced with the real image at deploy time.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-demo
  namespace: nginx-demo
  labels:
    app: nginx-demo
spec:
  replicas: 2
  revisionHistoryLimit: 5
  selector:
    matchLabels:
      app: nginx-demo
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app: nginx-demo
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 101
      containers:
        - name: nginx
          image: IMAGE_PLACEHOLDER          # replaced at deploy time
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
          readinessProbe:
            httpGet: { path: /healthz, port: http }
            initialDelaySeconds: 2
            periodSeconds: 5
          livenessProbe:
            httpGet: { path: /healthz, port: http }
            initialDelaySeconds: 5
            periodSeconds: 10
          resources:
            requests: { cpu: 50m, memory: 32Mi }
            limits:   { cpu: 200m, memory: 128Mi }
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: { drop: ["ALL"] }
```

**`k8s/service.yaml`**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: nginx-demo
  namespace: nginx-demo
spec:
  type: ClusterIP
  selector:
    app: nginx-demo
  ports:
    - name: http
      port: 80
      targetPort: http
```

**`k8s/ingress.yaml`** (optional — only for browser access). `INGRESS_CLASS_PLACEHOLDER` and `INGRESS_HOST_PLACEHOLDER` are replaced at deploy time; check available classes with `kubectl get ingressclass`.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: nginx-demo
  namespace: nginx-demo
spec:
  ingressClassName: INGRESS_CLASS_PLACEHOLDER
  rules:
    - host: INGRESS_HOST_PLACEHOLDER
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: nginx-demo
                port:
                  name: http
```

**Manual test deploy:**

```bash
kubectl apply -f k8s/service.yaml
sed "s|IMAGE_PLACEHOLDER|docker.io/anish60/nginx-cicd-demo:latest|" k8s/deployment.yaml | kubectl apply -f -
kubectl -n nginx-demo rollout status deployment/nginx-demo
kubectl -n nginx-demo port-forward svc/nginx-demo 8080:80     # open http://localhost:8080
```

---

## Step 5 — Kubernetes: Bamboo agent namespace and RBAC

**`nkp/bamboo-agent/namespace.yaml`**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: bamboo
```

**`nkp/bamboo-agent/rbac.yaml`** — the agent's identity. It can only manage the app in `nginx-demo`; it cannot list nodes, create namespaces, or touch anything else.

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: bamboo-agent
  namespace: bamboo
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: nginx-demo-deployer
  namespace: nginx-demo
rules:
  - apiGroups: ["apps"]
    resources: [deployments]
    verbs: [get, list, watch, create, update, patch]
  - apiGroups: ["apps"]
    resources: [replicasets]
    verbs: [get, list, watch]                  # rollout status / undo
  - apiGroups: [""]
    resources: [services]
    verbs: [get, list, watch, create, update, patch]
  - apiGroups: [""]
    resources: [pods, pods/log, events]
    verbs: [get, list, watch]                  # debugging failed rollouts
  - apiGroups: ["networking.k8s.io"]
    resources: [ingresses]
    verbs: [get, list, watch, create, update, patch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: bamboo-agent-deployer
  namespace: nginx-demo
subjects:
  - kind: ServiceAccount
    name: bamboo-agent
    namespace: bamboo
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: nginx-demo-deployer
```

```bash
kubectl apply -f nkp/bamboo-agent/namespace.yaml
kubectl apply -f nkp/bamboo-agent/rbac.yaml

# Verify the permissions
kubectl auth can-i create deployments -n nginx-demo --as=system:serviceaccount:bamboo:bamboo-agent   # yes
kubectl auth can-i list nodes --as=system:serviceaccount:bamboo:bamboo-agent                         # no
```

---

## Step 6 — Bamboo server

**`bamboo/docker-compose.yml`** — run on a host the cluster can reach. The version must match the agent image (11.0.7).

```yaml
services:
  bamboo:
    image: atlassian/bamboo:11.0.7
    container_name: bamboo
    ports:
      - "8085:8085"     # web UI + agent HTTP
      - "54663:54663"   # remote agent broker
    environment:
      - JVM_MAXIMUM_MEMORY=2048m
    volumes:
      - bamboo-data:/var/atlassian/application-data/bamboo
    restart: unless-stopped

volumes:
  bamboo-data:
```

```bash
docker compose -f bamboo/docker-compose.yml up -d
docker logs -f bamboo        # wait until Bamboo has started (~2–3 min)
```

Then open `http://<BAMBOO_SERVER>:8085` and complete the setup wizard:

1. Enter the license.
2. Choose the embedded database (fine for a demo).
3. Create the admin user.
4. ⚙ → General configuration → set **Base URL** to `http://<BAMBOO_SERVER>:8085` (not `localhost`).

Check the cluster can reach the server:

```bash
kubectl run nettest --rm -i --restart=Never --image=curlimages/curl -- \
  curl -sS -o /dev/null -w '%{http_code}\n' --max-time 10 http://<BAMBOO_SERVER>:8085/
# expect 200 or 302
```

---

## Step 7 — Bamboo agent in Kubernetes

**`nkp/bamboo-agent/agent.yaml`** — official Atlassian agent image. An init container downloads `kubectl` and `crane` and registers them as agent capabilities. The PVC keeps the agent's identity across restarts. Replace `BAMBOO_SERVER_URL` with your server URL.

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: bamboo-agent-home
  namespace: bamboo
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 5Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: bamboo-agent
  namespace: bamboo
  labels:
    app: bamboo-agent
spec:
  replicas: 1
  strategy:
    type: Recreate                      # RWO volume holds the agent's identity
  selector:
    matchLabels:
      app: bamboo-agent
  template:
    metadata:
      labels:
        app: bamboo-agent
    spec:
      serviceAccountName: bamboo-agent
      securityContext:
        fsGroup: 2005                   # bamboo user in the agent image
      initContainers:
        - name: tools
          image: docker.io/atlassian/bamboo-agent-base:11.0.7   # must match the Bamboo server
          command: ["bash", "-euo", "pipefail", "-c"]
          args:
            - |
              # kubectl must be within one minor version of the cluster
              curl -fsSLo /tools/kubectl "https://dl.k8s.io/release/v1.33.5/bin/linux/amd64/kubectl"
              curl -fsSL "https://github.com/google/go-containerregistry/releases/download/v0.22.1/go-containerregistry_Linux_x86_64.tar.gz" \
                | tar xz -C /tools crane
              chmod +x /tools/kubectl /tools/crane
              # The PVC hides the image's capabilities file: start from the
              # image's copy and add ours.
              caps=/agent-home/bin/bamboo-capabilities.properties
              mkdir -p /agent-home/bin
              cp "${BAMBOO_AGENT_HOME}/bin/bamboo-capabilities.properties" "${caps}"
              /bamboo-update-capability.sh kubectl /usr/local/bin/kubectl "${caps}"
              /bamboo-update-capability.sh crane /usr/local/bin/crane "${caps}"
              chown -R 2005:2005 /agent-home
          volumeMounts:
            - name: tools
              mountPath: /tools
            - name: home
              mountPath: /agent-home
      containers:
        - name: agent
          image: docker.io/atlassian/bamboo-agent-base:11.0.7
          imagePullPolicy: IfNotPresent
          env:
            - name: BAMBOO_SERVER
              value: BAMBOO_SERVER_URL
          resources:
            requests: { cpu: 250m, memory: 1Gi }
            limits:   { cpu: "1",  memory: 2Gi }
          volumeMounts:
            - name: home
              mountPath: /var/atlassian/application-data/bamboo-agent
            - name: tools
              mountPath: /usr/local/bin/kubectl
              subPath: kubectl
            - name: tools
              mountPath: /usr/local/bin/crane
              subPath: crane
      volumes:
        - name: tools
          emptyDir: {}
        - name: home
          persistentVolumeClaim:
            claimName: bamboo-agent-home
```

```bash
sed "s|BAMBOO_SERVER_URL|http://<BAMBOO_SERVER>:8085|" nkp/bamboo-agent/agent.yaml | kubectl apply -f -
kubectl -n bamboo rollout status deployment/bamboo-agent --timeout=300s
kubectl -n bamboo logs deploy/bamboo-agent -f
```

Then in Bamboo → ⚙ → **Agents → Agent authentication**, approve the new agent. Under **Remote agents**, its capabilities should include `kubectl` and `crane`.

---

## Step 8 — Bamboo plan and deployment (Bamboo Specs)

**`bamboo-specs/bamboo.yml`** — the plan waits for CI's image and publishes a release; the deployment environment deploys it with the agent pod.

```yaml
---
version: 2
plan:
  project-key: NGX
  key: CICD
  name: nginx-cicd-demo

repositories:
  - nginx-cicd-demo:
      scope: global          # linked repository created in Bamboo UI

branches:
  create: manually

triggers:
  - polling:
      period: 60

variables:
  image_repo: docker.io/anish60/nginx-cicd-demo
  wait_timeout: 900

stages:
  - Verify CI image:
      manual: false
      final: false
      jobs:
        - Wait for image

Wait for image:
  requirements:
    - crane                  # capability of the agent pod
  tasks:
    - checkout:
        force-clean-build: true
    - script:
        interpreter: SHELL
        scripts:
          - |-
            set -euo pipefail
            export GIT_REVISION="${bamboo_planRepository_revision}"
            export IMAGE_REPO="${bamboo_image_repo}"
            export TIMEOUT_SEC="${bamboo_wait_timeout}"
            bash scripts/wait-for-image.sh
  artifacts:
    - name: release
      location: .
      pattern: 'release/**,k8s/**,scripts/**'
      shared: true
      required: true

---
version: 2
deployment:
  name: nginx-cicd-demo deploy
  source-plan: NGX-CICD

release-naming:
  next-version-name: ${bamboo.planRepository.revision}
  applies-to-branches: false

environments:
  - nkp

nkp:
  description: Kubernetes cluster, namespace nginx-demo (deployed by the in-cluster agent)
  triggers:
    - build-success           # auto-deploy after every green plan build
  variables:
    smoke_url: http://nginx-demo.nginx-demo.svc.cluster.local
    ingress_class: kommander-traefik
    # Add ingress_host (e.g. nginx-demo.apps.example.com) to also create an Ingress.
  requirements:
    - kubectl
  tasks:
    - clean
    - artifact-download:
        destination: .
    - script:
        interpreter: SHELL
        scripts:
          - |-
            set -euo pipefail
            chmod +x scripts/*.sh
            export SMOKE_URL="${bamboo_smoke_url}"
            export INGRESS_HOST="${bamboo_ingress_host:-}"
            export INGRESS_CLASS="${bamboo_ingress_class}"
            ./scripts/cd-deploy.sh release/image.env
```

The scripts it calls live in the repo under `scripts/`:

| Script | What it does |
|---|---|
| `wait-for-image.sh` | Polls Docker Hub (with `crane`) until `sha-<commit>` exists, then writes `release/image.env` |
| `cd-deploy.sh` | Reads `release/image.env` and calls `deploy.sh` with the in-cluster smoke-test URL |
| `deploy.sh` | Applies the Service, Deployment (image filled in) and optional Ingress → waits for rollout → curls `/healthz` and checks the page shows the new version → `kubectl rollout undo` on any failure |

**Import into Bamboo:**

1. **Create project** with key `NGX`.
2. ⚙ → **Linked repositories → Add → Git**: name `nginx-cicd-demo`, URL `https://github.com/anishbista60/nginx-cicd-demo.git`, branch `main`.
3. In its **Bamboo Specs** tab, enable **Scan for Bamboo Specs** and grant access to project `NGX`.
4. Click **Scan** → Bamboo creates plan **NGX-CICD** and deployment project **nginx-cicd-demo deploy**.

---

## Step 9 — End-to-end test

```bash
sed -i 's/Hello from nginx/Hello again from nginx/' app/html/index.html
git commit -s -am "update page" && git push
```

1. GitHub Actions builds and pushes `sha-xxxxxxx`.
2. Bamboo (≤60 s later) runs plan NGX-CICD, waits for that tag, publishes the release.
3. The deployment environment triggers automatically, rolls out, smoke-tests.

```bash
kubectl -n nginx-demo get deploy,pods,svc -o wide
kubectl -n nginx-demo rollout history deployment/nginx-demo
```

**Rollback:** in Bamboo, open the deployment project → environment → redeploy any older release.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Docker Hub login fails in GitHub Actions | Wrong secret (e.g. a GitHub `ghp_` token) | Put a Docker Hub access token (`dckr_pat_…`) in `DOCKERHUB_TOKEN` |
| Pod `ImagePullBackOff`, `dial tcp [2600:…]:443: network is unreachable` | Node tried Docker's CDN over IPv6 without an IPv6 route | Usually succeeds on retry; otherwise disable IPv6 on nodes or mirror images to a private registry |
| Agent log: 404 on `/setup/setupLicense.action/GetFingerprint.action` | Bamboo setup wizard not finished (no license) | Complete the setup wizard with a valid license |
| `kubectl run nettest` prints nothing / times out | Cluster can't reach the Bamboo server | Open ports 8085 and 54663 on the server's firewall |
| Deployment fails with `forbidden` | Agent RBAC missing | Re-apply `rbac.yaml`; check with `kubectl auth can-i … --as=system:serviceaccount:bamboo:bamboo-agent` |
