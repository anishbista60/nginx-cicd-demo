# nginx CI/CD demo — GitHub Actions (CI) + Bamboo (CD) + NKP

```
 git push ──► GitHub Actions (CI)                        Bamboo (CD)
              ├─ build image                              ├─ Plan NGX-CICD (polls repo every 60s)
              └─ push docker.io/anish60/nginx-cicd-demo   │   └─ wait for docker.io/...:sha-<commit>
                   :sha-<commit> and :latest              │      → shared artifact "release"
                                                          └─ Deployment env "nkp"
                                                              ├─ kubectl apply + rollout status
                                                              ├─ curl smoke test (checks version)
                                                              └─ auto rollback on failure
                                                                        │
                                          Bamboo agent pod (namespace bamboo) in the NKP cluster
                                          deploys to namespace nginx-demo via its service account
```

The image tag (`sha-<first 7 chars of commit>`) is the contract between the two
systems: GitHub publishes it, Bamboo waits for it and deploys exactly that tag.

Bamboo jobs run on a **remote agent that is a pod inside NKP**. kubectl in that pod
uses the pod's service account (`bamboo/bamboo-agent`), which is only allowed to
manage the app in namespace `nginx-demo` — no kubeconfig is stored anywhere.

## Repo layout

| Path | Purpose |
|---|---|
| `app/` | Dockerfile (non-root nginx on 8080), nginx.conf with `/healthz`, static page |
| `k8s/` | Namespace, Deployment (2 replicas, probes, rolling update), ClusterIP Service, optional Ingress |
| `nkp/bamboo-agent/` | Agent Deployment (official Atlassian image + kubectl/crane init container), PVC, namespace, RBAC |
| `.github/workflows/ci.yml` | CI: build and push the app image |
| `bamboo-specs/bamboo.yml` | Bamboo plan + deployment project as code |
| `bamboo/docker-compose.yml` | Run the Bamboo server with Docker |
| `scripts/deploy.sh` | Deploy + smoke test + rollback |
| `scripts/wait-for-image.sh` | Bamboo build: wait for CI's image, emit `release/image.env` |
| `scripts/cd-deploy.sh` | Bamboo deployment task |

## Setup

### 1. GitHub and Docker Hub
The app image is published to Docker Hub as
[`anish60/nginx-cicd-demo`](https://hub.docker.com/r/anish60/nginx-cicd-demo).
Add two repository secrets in **GitHub → Settings → Secrets and variables → Actions**:

| Secret | Value |
|---|---|
| `DOCKERHUB_USERNAME` | `anish60` |
| `DOCKERHUB_TOKEN` | a Docker Hub access token (Account settings → Personal access tokens, Read & Write) |

The Docker Hub repo must be public so NKP can pull it without credentials. The agent
uses Atlassian's official `atlassian/bamboo-agent-base` image, so there is no agent
image to build.

### 2. Bamboo server
```bash
make bamboo-up                      # http://<this-host>:8085
```
Finish the setup wizard (trial license, admin user, embedded DB is fine for a demo).
The agent pod in NKP connects **to** the server, so the NKP nodes must reach this
host on ports **8085** and **54663**. In **⚙ → General configuration**, set the
Base URL to that reachable address (not `localhost`).

### 3. NKP cluster (as cluster admin)
```bash
export KUBECONFIG=~/.kube/nkp.conf          # from NKP UI → cluster → Download kubeconfig
kubectl version                             # the agent's kubectl must be within ±1 minor
make nkp-bootstrap                          # namespaces nginx-demo + bamboo, agent RBAC
make nkp-agent BAMBOO_SERVER=http://<bamboo-host>:8085
```
`nkp-agent` creates a 5Gi PVC with the default StorageClass (it keeps the agent's
identity across restarts) and the agent Deployment. On each start, an init container
downloads kubectl and crane and registers them as agent capabilities. If the cluster's
minor version differs by more than one from `v1.33`, change the kubectl version in
`nkp/bamboo-agent/agent.yaml`.

Then in Bamboo → **⚙ → Agents → Agent authentication**, approve the new agent. Its
capabilities include `kubectl` and `crane`. Optionally disable the server's local
agents so every job lands on the NKP agent.

### 4. Connect the repo and import the Specs
1. Bamboo → **Create project** with key `NGX`.
2. **⚙ → Linked repositories → Add → GitHub** (or Git), name it **`nginx-cicd-demo`**,
   URL `https://github.com/anishbista60/nginx-cicd-demo.git`, branch `main`, and in the
   **Bamboo Specs** tab enable **Scan for Bamboo Specs** and grant access to project `NGX`.
3. Click **Scan**. Bamboo creates plan **NGX-CICD** and deployment project
   **nginx-cicd-demo deploy** with environment **nkp**.

### 5. Expose the app (optional)
CD smoke-tests the Service from inside the cluster, so no Ingress is needed for the
pipeline. To reach the app from a browser, add a variable `ingress_host`
(e.g. `nginx-demo.apps.example.com`) to the `nkp` environment in
`bamboo-specs/bamboo.yml`; the deploy then also creates an Ingress on NKP's Traefik
(class `kommander-traefik` — check with `kubectl get ingressclass`). Quick look without DNS:
```bash
kubectl -n nginx-demo port-forward svc/nginx-demo 8080:80   # http://localhost:8080
```

### 6. Watch the whole flow
```bash
sed -i 's/Hello from nginx/Hello again from nginx/' app/html/index.html
git commit -am "update page" && git push
```
1. GitHub Actions: build → push `sha-xxxxxxx`.
2. Bamboo (≤60 s later) builds NGX-CICD on the NKP agent, waits for that tag, publishes the release.
3. Deployment `nkp` triggers automatically, rolls out, smoke-tests, rolls back on failure.
4. `make nkp-status` shows the new pods; the page shows `Version: sha-xxxxxxx`.

Rollback: in Bamboo, open the deployment project → **nkp** → redeploy any older release.

## Notes & tweaks
- **No polling / instant trigger:** expose Bamboo publicly and add a GitHub webhook,
  or replace `polling` with a `remote` trigger in the Specs.
- **Manual approval:** remove `build-success` from the environment's triggers and
  Bamboo will deploy only when you click *Deploy*.
- **Air-gapped NKP / Docker Hub rate limits:** mirror the app and agent images into
  your registry (e.g. Harbor) and point `image_repo` in the Specs and the images in
  `nkp/bamboo-agent/agent.yaml` at it, or add an `imagePullSecret`. The init container
  also needs to reach dl.k8s.io and github.com.
- **Upgrading Bamboo:** bump the version in `bamboo/docker-compose.yml` and both
  images in `nkp/bamboo-agent/agent.yaml` together.
