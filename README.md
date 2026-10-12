# nginx CI/CD demo — GitHub Actions (CI) + Bamboo (CD) + kind

```
 git push ──► GitHub Actions (CI)                        Bamboo (CD, on your machine)
              ├─ lint: hadolint, kubeconform, shellcheck  ├─ Plan NGX-CICD (polls repo every 60s)
              ├─ build image                              │   └─ wait for docker.io/...:sha-<commit>
              ├─ Trivy scan (fail on HIGH/CRITICAL)       │      → shared artifact "release"
              ├─ smoke test on ephemeral kind cluster     └─ Deployment env "kind-local"
              └─ push docker.io/anish60/nginx-cicd-demo       ├─ docker pull + kind load
                   :sha-<commit> and :latest  ───────────►    ├─ kubectl apply + rollout status
                                                              ├─ curl smoke test (checks version)
                                                              └─ auto rollback on failure
                                                                        │
                                                         local kind cluster "cicd-demo"
                                                         http://localhost:8080
```

The image tag (`sha-<first 7 chars of commit>`) is the contract between the two
systems: GitHub publishes it, Bamboo waits for it and deploys exactly that tag.

## Repo layout

| Path | Purpose |
|---|---|
| `app/` | Dockerfile (non-root nginx on 8080), nginx.conf with `/healthz`, static page |
| `k8s/` | Namespace, Deployment (2 replicas, probes, rolling update), NodePort Service |
| `kind/kind-config.yaml` | 1 control-plane + 1 worker; NodePort 30080 → host 8080 |
| `.github/workflows/ci.yml` | CI pipeline |
| `bamboo-specs/bamboo.yml` | Bamboo plan + deployment project as code |
| `bamboo/docker-compose.yml` | Run Bamboo server locally |
| `scripts/deploy.sh` | Shared deploy + smoke test + rollback (used by CI and CD) |
| `scripts/wait-for-image.sh` | Bamboo build: wait for CI's image, emit `release/image.env` |
| `scripts/cd-deploy.sh` | Bamboo deployment task |

## Prerequisites (on the machine that runs Bamboo's agent)

Docker, [kind](https://kind.sigs.k8s.io/), kubectl, Java 17+ (for the Bamboo agent), git, curl.

## Setup

### 1. Push to GitHub & configure Docker Hub
```bash
git init && git add . && git commit -m "nginx CI/CD demo"
git remote add origin https://github.com/anishbista60/nginx-cicd-demo.git
git push -u origin main
```
Images are published to Docker Hub at
[`anish60/nginx-cicd-demo`](https://hub.docker.com/r/anish60/nginx-cicd-demo).
Add two repository secrets in **GitHub → Settings → Secrets and variables → Actions**:

| Secret | Value |
|---|---|
| `DOCKERHUB_USERNAME` | `anish60` |
| `DOCKERHUB_TOKEN` | a Docker Hub access token (Account settings → Personal access tokens, Read & Write) |

The Docker Hub repo is public, so Bamboo can pull without credentials.

### 2. Try it locally without any CI/CD (optional sanity check)
```bash
make deploy     # creates kind cluster, builds, deploys, smoke tests
make test       # → http://localhost:8080
```

### 3. Start Bamboo
```bash
make bamboo-up                      # http://localhost:8085
```
Finish the setup wizard (paste a trial license, create admin user, embedded DB is fine for a demo).

### 4. Install a remote agent on your host
The built-in agent lives inside the container and can't see your kind cluster,
so run a remote agent directly on your machine:

1. Bamboo → **⚙ → Agents → Install remote agent** → download the installer JAR.
2. `java -jar atlassian-bamboo-agent-installer-*.jar http://localhost:8085/agentServer/`
3. Approve the agent in **Agents → Agent authentication**.
4. On that agent, **Add capability → Custom**: `docker`, `kind`, `kubectl` (any value, e.g. `true`).
5. Optional: disable the server's local agents so jobs always land on your host agent.

### 5. Connect the repo and import the Specs
1. `bamboo-specs/bamboo.yml` already sets `image_repo: docker.io/anish60/nginx-cicd-demo` (change it if you fork).
2. Bamboo → **Create project** with key `NGX`.
3. **⚙ → Linked repositories → Add → GitHub** (or Git), name it **`nginx-cicd-demo`**,
   branch `main`, and in the **Bamboo Specs** tab enable **Scan for Bamboo Specs**
   and grant access to project `NGX`.
4. Click **Scan**. Bamboo creates plan **NGX-CICD** and deployment project
   **nginx-cicd-demo deploy** with environment **kind-local**.

### 6. Watch the whole flow
```bash
# change something visible
sed -i 's/Hello from nginx/Hello again from nginx/' app/html/index.html
git commit -am "update page" && git push
```
1. GitHub Actions: lint → build/scan/kind test → push `sha-xxxxxxx`.
2. Bamboo (≤60 s later) builds NGX-CICD, waits for that tag, publishes the release.
3. Deployment `kind-local` triggers automatically, rolls out, smoke-tests.
4. `curl localhost:8080` shows the new text and `Version: sha-xxxxxxx`.

```bash
kubectl -n nginx-demo rollout history deployment/nginx-demo   # one entry per release
```
Rollback: in Bamboo, open the deployment project → **kind-local** → redeploy any older release.

## Notes & tweaks
- **No polling / instant trigger:** expose Bamboo publicly (e.g. a tunnel) and add a GitHub
  webhook, or replace `polling` with a `remote` trigger in the Specs.
- **Manual approval for prod-like envs:** remove `build-success` from the environment's
  triggers and Bamboo will deploy only when you click *Deploy*.
- **Port 8080 busy?** Change `hostPort` in `kind/kind-config.yaml` and the curl URLs in `scripts/deploy.sh`.
