# Bamboo CD to NKP

This repo deploys an application image from Harbor to an NKP cluster, using a
Bamboo deployment project.

The build side (CI) already exists: a Bamboo build plan builds the image and pushes it
to Harbor, tagged with the commit SHA. This repo only adds the deployment side (CD).

![Architecture](docs/architecture.svg)

1. A developer pushes code to Bitbucket.
2. Bamboo starts the existing build plan.
3. The build pushes the image to Harbor, for example `ajb-hr/be:<commit-sha>`.
4. When the build succeeds, Bamboo creates a release. We name the release after the
   commit SHA, which is how Bamboo knows which image to deploy.
5. The deployment project runs `scripts/bamboo-deploy.sh` on a Bamboo agent. The
   script runs `kubectl set image` against the NKP cluster and waits until the new
   pods are ready. If they don't become ready, it rolls back and the deployment fails.
6. NKP pulls the image from Harbor and starts the new pods.

To roll back, deploy an older release from Bamboo.

## Files

| File | Used by | Purpose |
|---|---|---|
| `nkp/setup.sh`, `nkp/rbac.yaml` | NKP admin, once | Creates the namespace, a service account for Bamboo, the Harbor pull secret, and a kubeconfig for Bamboo |
| `k8s/deployment.yaml`, `k8s/service.yaml` | `scripts/deploy-app.sh` | The app `chatbot-application` |
| `k8s/ingress.yaml` | You, optional | Exposes the app on NKP's Traefik |
| `scripts/deploy-app.sh` | Once | Applies the Deployment and Service the first time |
| `scripts/bamboo-deploy.sh` | Bamboo, every deployment | Pasted into the Bamboo Script task |
| `Makefile` | You | Runs the same steps from your own machine for testing |

## Information to collect from the customer

Fill this in at deployment time:

| Item | Example | Value |
|---|---|---|
| Namespace on NKP | `hr-chatbot` | |
| Image repository in Harbor | `harbor-uat.example.com/ajb-hr/be` | |
| Tag format: full SHA, short SHA (7 or 8 chars), any prefix | full SHA | |
| Container port | `8080` | |
| Environment variables or secrets the app needs | `DB_URL`, `API_KEY` | |
| Harbor robot account (pull) for NKP | `robot$ajb-hr+nkp` | |
| Does Harbor use a private CA? Do the NKP nodes trust it? | yes / yes | |
| Bamboo agent that runs deployments; is `kubectl` installed? | local agent on the Bamboo VM | |
| NKP API address, reachable from that agent | `https://10.0.0.10:6443` | |
| Hostname for the app (optional) | `hr-be.apps.example.com` | |

## Steps

### 1. Prepare NKP (NKP admin, once)

```bash
git clone https://github.com/anishbista60/nginx-cicd-demo.git
cd nginx-cicd-demo
export KUBECONFIG=<nkp-admin-kubeconfig>
export HARBOR_HOST=<harbor> HARBOR_USERNAME='<robot-account>' HARBOR_PASSWORD='<robot-token>'
make nkp-setup NAMESPACE=<namespace>
```

This creates:
- the namespace
- service account `bamboo-deployer`, which can only manage apps in this namespace
- pull secret `harbor-pull`
- the file `bamboo-nkp.kubeconfig`, which Bamboo will use

If the app needs environment variables, put them in the secret `chatbot-application-env`:
```bash
kubectl -n <namespace> create secret generic chatbot-application-env --from-env-file=app.env
```

### 2. Deploy the app the first time (once)

```bash
unset KUBECONFIG
make app NAMESPACE=<namespace> IMAGE=<image-repo>:<current-tag> PORT=<port>
```

This applies `k8s/deployment.yaml` (2 pods, rolling update) and `k8s/service.yaml`.

To expose the app with a hostname (optional):
```bash
sed 's/HOST_PLACEHOLDER/<hostname>/' k8s/ingress.yaml | kubectl -n <namespace> apply -f -
```

### 3. Test the deploy script without Bamboo

This sets the same variables Bamboo sets and runs the same script:
```bash
make deploy NAMESPACE=<namespace> IMAGE_REPO=<image-repo> TAG_LENGTH=0 RELEASE=<commit-sha>-1
make status NAMESPACE=<namespace>
```

### 4. Configure Bamboo (in the UI)

1. **Create → Create deployment project.** Link it to the existing build plan of the app.
2. **Release versioning** (Edit project → Release versioning). Set the name to:
   ```
   ${bamboo.planRepository.revision}-${bamboo.buildNumber}
   ```
   Releases are then named like `a1b2c3d…-42`: the commit SHA, then the build number.
3. **Add environment** `nkp`. Under *Set up tasks*, keep *Clean working directory* and
   add a **Script** task:
   - Interpreter: Shell
   - Script location: Inline
   - Script body: paste the whole of `scripts/bamboo-deploy.sh`
4. **Variables** (environment `nkp` → Variables):

   | Variable | Value |
   |---|---|
   | `nkp_kubeconfig_secret` | output of `base64 -w0 bamboo-nkp.kubeconfig` (hidden in logs because the name contains `secret`) |
   | `image_repo` | image repository, e.g. `harbor-uat.example.com/ajb-hr/be` |
   | `namespace` | the namespace |
   | `app` | `chatbot-application` |
   | `tag_length` | `0` for the full SHA, or `7` / `8` |
   | `tag_prefix` | `none`, or the text before the SHA in the tag |
   | `image_tag` | `none` (set a tag here only to force a specific image) |
   | `rollout_timeout` | `300s` |
5. **Agents assignment.** Pick the agent that has `kubectl`.
6. **Triggers.** Add *After successful build plan* to deploy automatically. Without
   it, you deploy by clicking *Deploy*.

### 5. Test together

1. Run the build plan, or push a commit.
2. A new release appears in the deployment project and is deployed to `nkp`.
3. Check the pods: `kubectl -n <namespace> get pods`. They should run the new tag.
4. Rollback: environment `nkp` → *Deploy* → choose an older release.
5. Failure test: set `image_tag` to `does-not-exist` and deploy. The script rolls
   back and the deployment shows as failed. Set `image_tag` back to `none`.

## Harbor certificate

If Harbor uses a certificate from a private CA, only one place has to trust it: **the
NKP nodes**, because they pull the image.

- The Bamboo agent never connects to Harbor during deployment, so it doesn't need
  the CA.
- `kubectl` connects to the NKP API, and the kubeconfig from step 1 already contains
  the NKP CA.

**Check whether the nodes trust Harbor (NKP admin):**
```bash
kubectl -n <namespace> run harbor-test --restart=Never \
  --image=<image-repo>:<existing-tag> --overrides='{"spec":{"imagePullSecrets":[{"name":"harbor-pull"}]}}'
kubectl -n <namespace> get pod harbor-test      # Running or Completed = OK
kubectl -n <namespace> describe pod harbor-test | grep -i x509   # x509 error = CA not trusted
kubectl -n <namespace> delete pod harbor-test
```

**If you get an x509 error**, the NKP admin has to add the Harbor CA to the cluster's
registry configuration. That is the permanent fix, and it survives node replacement.
For a quick test in a lab you can add it by hand on each node:
```bash
mkdir -p /etc/containerd/certs.d/<harbor>
cp harbor-ca.crt /etc/containerd/certs.d/<harbor>/ca.crt
cat > /etc/containerd/certs.d/<harbor>/hosts.toml <<EOF
server = "https://<harbor>"
[host."https://<harbor>"]
  ca = "/etc/containerd/certs.d/<harbor>/ca.crt"
EOF
```

## Troubleshooting

| Problem | Fix |
|---|---|
| `kubectl: not found` | Install kubectl in `/usr/local/bin` on the agent. Bamboo running under systemd has a short PATH. |
| `Unable to connect to the server` | The agent can't reach the NKP API on port 6443 (firewall or proxy), or the kubeconfig variable is incomplete. Copy the `base64 -w0` output again. |
| `deployments.apps "chatbot-application" not found` | Step 2 wasn't run, or the `namespace` variable doesn't match it. |
| `forbidden` | Step 1 was run for a different namespace. |
| `ImagePullBackOff` with `not found` | The tag doesn't exist in Harbor. Check `tag_length` and `tag_prefix`, and that the release name starts with the commit SHA. |
| `ImagePullBackOff` with `x509` | The NKP nodes don't trust the Harbor CA. See [Harbor certificate](#harbor-certificate). |
| `ImagePullBackOff` with `unauthorized` | The pull secret is wrong. Run step 1 again with the right robot account. |
| Pods restart (`CrashLoopBackOff`) | Check `kubectl logs`: usually missing environment variables. |

## Cleanup

```bash
export KUBECONFIG=<nkp-admin-kubeconfig>
kubectl delete namespace <namespace>
```
Then delete the deployment project in Bamboo.
