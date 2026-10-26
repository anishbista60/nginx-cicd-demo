# Bamboo CD to NKP

Deploy an image that an existing Bamboo CI plan pushes to Harbor onto an NKP
cluster, using a **Bamboo deployment project** configured in the Bamboo UI.

The target case: the HR Chatbot backend. Its CI already builds and pushes
`<harbor-uat>/ajb-hr/be:<commit-sha>` (and `:latest`). This repo adds the CD part
only:

| File | Who runs it | What it does |
|---|---|---|
| `nkp/setup.sh` + `nkp/rbac.yaml` | NKP admin, **once** | Namespace, service account `bamboo-deployer` limited to that namespace, Harbor pull secret, kubeconfig for Bamboo |
| `scripts/apply-app.sh` | Once, before the first Bamboo deploy | Deployment, Service (and optional Ingress) for the app |
| `scripts/bamboo-deploy.sh` | **Bamboo**, on every deployment | Pasted into a Script task: sets the new image, waits for the rollout, rolls back on failure |
| `Makefile` | You, locally | Runs the same three steps from any machine with kubectl, to rehearse before the call |

## How it works

```
 commit ─► Bitbucket ─► Bamboo build plan (existing CI)
                         └─ docker push <harbor-uat>/ajb-hr/be:<commit-sha>
                                    │ successful build = new release, named "<commit-sha>-<build no.>"
                                    ▼
                        Bamboo deployment project ─ environment "nkp" (trigger: after successful build)
                         └─ Script task: scripts/bamboo-deploy.sh   (runs on a Bamboo agent)
                              ├─ tag = commit SHA from the release name  →  image <harbor-uat>/ajb-hr/be:<sha>
                              ├─ kubectl set image deployment/<app>       (as bamboo-deployer, kubeconfig from a secret variable)
                              ├─ kubectl rollout status                   (readiness probe decides)
                              └─ kubectl rollout undo + job fails         if the new pods don't become ready
                                    ▼
                        NKP: namespace <ns>, Deployment <app>, pulls the image from Harbor
```

**How Bamboo finds the image:** Bamboo doesn't watch Harbor. Every successful build of
the CI plan creates a release, and the deployment project names it after the commit
(`${bamboo.planRepository.revision}-${bamboo.buildNumber}`). CI tagged the image with
that same commit SHA, so the deploy script builds the image reference from the release
name. Nothing in the CI plan has to change.

**Rollback:** in Bamboo, deploy an older release to the environment. Its name holds
the older SHA, so the older image is deployed.

Requirements on the Bamboo agent that runs the deployment: `sh`, `kubectl` (within one
minor version of the NKP Kubernetes version), `base64`, and network access to the NKP API
server (port 6443). The agent doesn't need Docker or Harbor access; the NKP nodes pull
the image.

## 0. Confirm before starting

| Item | Why |
|---|---|
| Is the Harbor tag the **full** commit SHA or a short one (7/8 chars)? Any prefix? | Sets `tag_length` / `tag_prefix` |
| Container port and health URL of the app (e.g. `8080`, `/health`) | Service and readiness probe (no health URL → TCP check) |
| Environment variables or secrets the app needs | Put into secret `<app>-env` (step 1) |
| Harbor robot account with pull on `ajb-hr` | Pull secret for NKP |
| Which Bamboo agent runs deployments; is `kubectl` on it | Script task runs there |
| Agent → NKP API `https://<nkp-api>:6443` reachable | `kubectl` from Bamboo |
| Namespace name (e.g. `hr-chatbot`) | Everything lives there |

## 1. NKP, one time (NKP admin)

```bash
git clone https://github.com/anishbista60/nginx-cicd-demo.git && cd nginx-cicd-demo
export KUBECONFIG=<nkp-admin-kubeconfig>
export HARBOR_HOST=<harbor-uat> HARBOR_USERNAME='robot$ajb-hr+nkp' HARBOR_PASSWORD='<token>'
make nkp-setup NAMESPACE=hr-chatbot
```

This creates the namespace, the service account `bamboo-deployer` (it can manage
deployments, services and ingresses in that namespace only, and can't create
namespaces or read secrets), the pull secret `harbor-pull`, and writes
**`bamboo-nkp.kubeconfig`**. The script checks the permissions at the end.

If the app needs environment variables or secrets, create them once, as admin:
```bash
kubectl -n hr-chatbot create secret generic hr-chatbot-be-env --from-env-file=app.env
```

## 2. First deployment of the app (once)

Uses the restricted kubeconfig from step 1:
```bash
unset KUBECONFIG
make app NAMESPACE=hr-chatbot APP=hr-chatbot-be \
  IMAGE=<harbor-uat>/ajb-hr/be:<current-commit-sha> PORT=<port> HEALTH_PATH=/<health> \
  INGRESS_HOST=<optional host on NKP Traefik>
```
It creates Deployment `hr-chatbot-be` (2 replicas, rolling update with
`maxUnavailable: 0`, probes, `envFrom` secret `hr-chatbot-be-env` if present) and
Service `hr-chatbot-be` (port 80 → `PORT`), plus an Ingress (class `kommander-traefik`)
if `INGRESS_HOST` is set. Re-running it also resets the image to `IMAGE`.

## 3. Rehearse what Bamboo will run

`make deploy` sets the same environment variables Bamboo sets and runs
`scripts/bamboo-deploy.sh`:
```bash
make deploy NAMESPACE=hr-chatbot APP=hr-chatbot-be IMAGE_REPO=<harbor-uat>/ajb-hr/be \
  TAG_LENGTH=0 RELEASE=<commit-sha>-1
make status NAMESPACE=hr-chatbot APP=hr-chatbot-be
```
To test with a stand-in app on another cluster, any image works. For example, the
images of this repo's earlier demo, `docker.io/anish60/nginx-cicd-demo:sha-<7 chars>`,
with `PORT=8080 HEALTH_PATH=/healthz TAG_PREFIX=sha- TAG_LENGTH=7`.

## 4. Bamboo configuration (UI)

1. **Create the deployment project:** Create → *Create deployment project*.
   Name `HR Chatbot BE`, linked build plan = the existing HR Chatbot CI plan, branch
   = the plan's main branch.
2. **Release versioning:** deployment project → *Edit project* → *Release versioning*:
   `${bamboo.planRepository.revision}-${bamboo.buildNumber}`. Leave "applies to
   branches" off. After the first build, check that the release name starts with the
   full commit SHA. The build number keeps names unique when the same commit is built
   twice.
3. **Add the environment** `nkp` (*Add environment*, then *Set up tasks*):
   - Keep the default *Clean working directory* task. No artifact download is needed.
   - Add a **Script** task: Interpreter *Shell*, Script location *Inline*. Paste the
     whole of `scripts/bamboo-deploy.sh`.
4. **Variables** (environment `nkp` → *Variables*):

   | Variable | Example | Notes |
   |---|---|---|
   | `nkp_kubeconfig_secret` | output of `base64 -w0 bamboo-nkp.kubeconfig` | Masked (name contains `secret`) |
   | `image_repo` | `<harbor-uat>/ajb-hr/be` | |
   | `namespace` | `hr-chatbot` | |
   | `app` | `hr-chatbot-be` | Deployment and container name |
   | `tag_length` | `0` | `0` = full SHA, or `7`/`8` |
   | `tag_prefix` | `none` | Text before the SHA in the tag, if any |
   | `image_tag` | `none` | Set a tag here to force a specific image, e.g. `latest` |
   | `rollout_timeout` | `300s` | |
5. **Agent:** environment `nkp` → *Agents assignment*: dedicate it to the agent that has
   `kubectl` (or add a requirement on a `kubectl` capability).
6. **Trigger:** environment `nkp` → *Triggers* → *After successful build plan*.
   Leave it off to deploy only by clicking *Deploy*.

## 5. Test it together

1. Run the CI plan (or push a commit). A new release `<sha>-<n>` appears in the
   deployment project, and environment `nkp` deploys it. The log shows
   `Release …: deploying <harbor-uat>/ajb-hr/be:<sha>` and ends with
   `Deployed …` and the pod list.
2. Check: `make status` (or `kubectl -n hr-chatbot get pods`); the pods run the new tag.
3. **Rollback:** environment `nkp` → *Deploy* → choose the previous release.
4. **Failure handling:** set `image_tag` to `does-not-exist`, deploy any release, and
   it rolls back and turns red. Set `image_tag` back to `none` afterwards.

Every Bamboo deployment is recorded in
`kubectl -n <ns> rollout history deployment/<app>` as `Bamboo release <name>: <image>`.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `kubectl: not found` | Not installed on the agent that ran the job, or not on the PATH of the Bamboo service user (systemd uses a minimal PATH: put it in `/usr/local/bin`) |
| `Unable to connect to the server` | Agent can't reach the NKP API on 6443 (firewall, proxy: add the API host to `no_proxy`), or the variable holds an incomplete kubeconfig: re-copy `base64 -w0` |
| `deployments.apps "<app>" not found` | Step 2 not done, or `namespace`/`app` variables differ from it |
| `forbidden` | Step 1 run for a different namespace |
| Pods `ImagePullBackOff`, `not found` | The tag doesn't exist: check `tag_length`/`tag_prefix` against Harbor, and that the release name starts with the SHA |
| Pods `ImagePullBackOff`, `unauthorized` / `x509` | Pull secret missing or wrong (re-run step 1 with `HARBOR_*`), or NKP nodes don't trust the Harbor CA |
| Rollout times out, pods `Running` but not ready | Health path or port wrong (step 2), or the app needs env vars (`<app>-env` secret) |
| Release name doesn't contain the SHA | Release versioning not set as in step 4.2. Meanwhile, deploy with `image_tag` set |

## Cleanup

```bash
export KUBECONFIG=<nkp-admin-kubeconfig>
kubectl delete namespace hr-chatbot
```
In Bamboo, delete the deployment project.
