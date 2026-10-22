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

Bamboo itself also runs in NKP (namespace `bamboo`): the server and its agent are
installed with Atlassian's Helm charts, with PostgreSQL next to them, and the UI is
served by NKP's Traefik at `https://bamboo.<traefik-lb-ip>.nip.io`.

The image tag (`sha-<first 7 chars of commit>`) is the contract between the two
systems: GitHub publishes it, Bamboo waits for it and deploys exactly that tag.

Bamboo jobs run on a **remote agent that is a pod inside NKP**. It reaches the server
through in-cluster Services (HTTP and the JMS broker on 54663), not through the ingress. kubectl in that pod
uses the pod's service account (`bamboo/bamboo-agent`), which is only allowed to
manage the app in namespace `nginx-demo` — no kubeconfig is stored anywhere.

## Repo layout

| Path | Purpose |
|---|---|
| `app/` | Dockerfile (non-root nginx on 8080), nginx.conf with `/healthz`, static page |
| `k8s/` | Namespace, Deployment (2 replicas, probes, rolling update), ClusterIP Service, optional Ingress |
| `nkp/bamboo-server/` | Helm values for the Bamboo server chart, PostgreSQL StatefulSet |
| `nkp/bamboo-agent/` | Helm values for the agent chart (kubectl/crane init container), namespace, RBAC |
| `.github/workflows/ci.yml` | CI: build and push the app image |
| `bamboo-specs/bamboo.yml` | Bamboo plan + deployment project as code |
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

### 2. NKP cluster (as cluster admin)
```bash
export KUBECONFIG=~/.kube/nkp.conf          # from NKP UI → cluster → Download kubeconfig
kubectl version                             # the agent's kubectl must be within ±1 minor
kubectl -n kommander get svc kommander-traefik   # EXTERNAL-IP = Traefik LB IP
make nkp-bootstrap                          # namespaces nginx-demo + bamboo, agent RBAC
```

### 3. Bamboo server and agent
```bash
make nkp-bamboo BAMBOO_HOST=bamboo.<traefik-lb-ip>.nip.io
```
This creates the secrets `bamboo-db` (DB password) and `bamboo-security-token` once,
starts PostgreSQL, and installs the `atlassian-data-center/bamboo` chart (version
`CHART_VERSION` in the Makefile) with an Ingress of class `kommander-traefik`. Traefik
redirects HTTP to HTTPS and serves its default self-signed certificate, so accept the
browser warning (or set `ingress.tlsSecretName` to a real certificate).

Open `https://<BAMBOO_HOST>` and finish the setup wizard: trial license from
my.atlassian.com and the admin user (the database is preconfigured). Then:
```bash
make nkp-agent
```
The agent registers with the security token, so no manual approval is needed. On each
start an init container downloads kubectl and crane and registers them as agent
capabilities; its home is not persistent, so a restarted pod shows up as a new agent
(remove offline ones in **⚙ → Agents**). If the cluster's minor version differs by more
than one from `v1.33`, change the kubectl version in `nkp/bamboo-agent/values.yaml`.
Optionally disable the server's local agents so every job lands on the NKP agent.

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
  both values files at it (`image.repository`), or add an `imagePullSecret`. The init container
  also needs to reach dl.k8s.io and github.com.
- **Upgrading Bamboo:** bump `CHART_VERSION` in the Makefile, update the init
  container image in `nkp/bamboo-agent/values.yaml` to the chart's appVersion, then
  run `make nkp-bamboo nkp-agent`.
