# ARC on a single-node k3s builder

Reproducible bootstrap: **Ubuntu 24.04 → k3s → Helm → ARC scale set → custom
runner image**. Aimed at a small office/VPS builder; adapt hostnames and paths.

Replace placeholders (`YOUR_ORG`, SSH host, Wi‑Fi iface, cache path) for your
environment.


| Piece         | Example in this repo                                                                         |
| ------------- | -------------------------------------------------------------------------------------------- |
| Charts        | `gha-runner-scale-set-controller` / `gha-runner-scale-set` **0.14.2**                        |
| Namespaces    | `arc-systems` (controller), `arc-runners` (scale set)                                        |
| Helm releases | `arc`, `ellexis-runners`                                                                     |
| Image         | `ghcr.io/ellexistech/arc-runner:<VERSION>` (see `[VERSION](VERSION)`; also tagged `:latest`) |
| Shared cache  | host `/cache/columbus` → pod `/cache/columbus` (must match Columbus `setup-pnpm-node`)       |


```text
Workstation
   │  docker build / push
   ▼
ghcr.io/ellexistech/arc-runner:<VERSION>
   │  public pull
   ▼
k3s node ── arc-systems (controller)
         └── arc-runners (ephemeral runner pods)
                │
                └── GitHub App secret → your org or repo
```

---



## 1. Host prep

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y \
  curl wget git unzip jq ca-certificates gnupg lsb-release apt-transport-https iw

sudo hostnamectl set-hostname YOUR_BUILDER_HOSTNAME
```

Use a normal sudo user for day-to-day kubectl/helm. **Docker Engine is not
required** on the builder — k3s ships containerd. Build the runner image on a
machine that has Docker (e.g. a laptop), then push to GHCR.

---



## 2. Install k3s

```bash
curl -sfL https://get.k3s.io | sh -
sudo systemctl enable --now k3s
sudo systemctl status k3s --no-pager
```

Kubeconfig for your user:

```bash
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown "$(id -u):$(id -g)" ~/.kube/config
chmod 600 ~/.kube/config
kubectl get nodes
```

### 2b. Extra agent (worker) nodes

Join a second host as a **k3s agent** so runner pods can schedule there.
Control-plane + ARC controller stay on the first node; agents only run workloads.

**4GB RAM nodes:** reserve kube/system memory so allocatable ≈ 2Gi and only
**one** DinD runner (≈1Gi request) fits. Use
[`scripts/join-agent.sh`](scripts/join-agent.sh):

```bash
# On the control plane (needs sudo once):
sudo cat /var/lib/rancher/k3s/server/node-token

# On the new host (example: zee.elx / elx-zee):
export K3S_URL="https://192.168.1.9:6443"   # control-plane LAN IP
export K3S_TOKEN="…"                         # from node-token above
# optional: NODE_NAME=elx-zee KUBE_RESERVED_MEM=1Gi SYSTEM_RESERVED_MEM=512Mi
sudo -E bash scripts/join-agent.sh
```

From a workstation (after copying the script):

```bash
scp scripts/join-agent.sh zee.elx:~/
ssh -t zee.elx "sudo K3S_URL=https://192.168.1.9:6443 K3S_TOKEN='…' bash ~/join-agent.sh"
```

Then on the control plane:

```bash
kubectl get nodes -o wide
kubectl label node elx-zee arc.ellexis.io/capacity=small --overwrite
kubectl describe node elx-zee | grep -A8 Allocatable
```

Raise `maxRunners` if you want the extra capacity in the shared pool
(e.g. `bash ./set-runner-max.sh 4`). Scheduling still cannot place two runners on
the small node when allocatable < 2× request.

Each agent needs its own hostPath cache dir (`/cache/columbus`); stores are
**not** shared across nodes unless you add RWX storage.

---



## 3. Install Helm 3

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version
```

---



## 4. Namespaces

```bash
kubectl create namespace arc-systems
kubectl create namespace arc-runners
```

---



## 5. ARC controller (pin 0.14.2)

```bash
helm install arc \
  --namespace arc-systems \
  --version 0.14.2 \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller

kubectl get pods -n arc-systems
```

---



## 6. GitHub App

Create an **organization-owned** GitHub App (or user-owned if you only need
repo scope).

- Homepage URL: `https://github.com/actions/actions-runner-controller`
- Repository permissions: **Metadata: Read-only**
(**Administration: Read and write** only if registering at **repository** scope)
- Organization permissions (org-level runners): **Self-hosted runners: Read and write**

Install the app on the target org (or repo). Record App ID, Installation ID,
and the private key `.pem`.

Official guide:
[Authenticating ARC to the GitHub API](https://docs.github.com/en/actions/how-tos/manage-runners/use-actions-runner-controller/authenticate-to-the-api).

```bash
sudo mkdir -p /etc/github-arc
sudo mv ~/YOUR-APP.private-key.pem /etc/github-arc/github-app-private-key.pem
sudo chmod 600 /etc/github-arc/github-app-private-key.pem
sudo chown root:root /etc/github-arc/github-app-private-key.pem
```

---



## 7. Kubernetes secret

```bash
export GITHUB_APP_ID="…"
export GITHUB_APP_INSTALLATION_ID="…"

kubectl create secret generic github-app-secret \
  --namespace arc-runners \
  --from-literal=github_app_id="$GITHUB_APP_ID" \
  --from-literal=github_app_installation_id="$GITHUB_APP_INSTALLATION_ID" \
  --from-file=github_app_private_key=/etc/github-arc/github-app-private-key.pem

kubectl get secret github-app-secret -n arc-runners
```

Key names must be exactly: `github_app_id`, `github_app_installation_id`,
`github_app_private_key`.

---



## 8. Shared CI cache directory

Optional but recommended for monorepo package managers (pnpm/npm/yarn stores,
Turbo local cache, etc.):

```bash
sudo mkdir -p /cache/columbus/pnpm-store /cache/columbus/turbo /cache/columbus/bin
sudo chmod -R 777 /cache/columbus
```

Tighten ownership later if you pin a known runner UID. Path must match
`[values.example.yaml](values.example.yaml)` (`hostPath` + `mountPath`) and the
Columbus default `COLUMBUS_CACHE_ROOT` / `/cache/columbus`.

**8GB host capacity:** `maxRunners: 4` is fine for queue depth, but keep
concurrent Node monorepo installs ≈2 (Columbus PR `meta` ∥ `gates`). Example
values set memory limits so four pods cannot allocate the whole machine.

---



## 9. Runner scale set

```bash
cp values.example.yaml ~/arc-runners-values.yaml
# Set githubConfigUrl to https://github.com/YOUR_ORG (or a single repo URL)
# Adjust maxRunners / image / cache paths as needed
```

Install:

```bash
helm install ellexis-runners \
  --namespace arc-runners \
  --version 0.14.2 \
  -f ~/arc-runners-values.yaml \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set
```

Upgrade later with the same chart version and values file:

```bash
helm upgrade ellexis-runners \
  --namespace arc-runners \
  --version 0.14.2 \
  -f ~/arc-runners-values.yaml \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set
```

With `minRunners: 0` you should still see a **listener** pod; runner pods
appear when GitHub dispatches matching jobs.

```bash
kubectl get pods -n arc-runners
kubectl get autoscalingrunnersets -n arc-runners
```

The Helm release / `runnerScaleSetName` becomes the workflow `runs-on` label
(here: `ellexis-runners`).

---



## 10. Headless laptop (optional)

If the builder **or an agent** is a laptop that must stay online with the lid
closed (and keep k3s/ARC ready across reboot), apply the host units once:

```bash
# Auto-detects Wi‑Fi iface; override with WIFI_IFACE=wlp0s12f0 if needed.
sudo bash scripts/apply-headless-host.sh
```

That installs [`host/99-headless-ci.conf`](host/99-headless-ci.conf) (ignore lid /
suspend keys), masks `sleep`/`suspend`/`hibernate`/`hybrid-sleep`, enables
[`host/wifi-no-powersave.service`](host/wifi-no-powersave.service) for the local
iface, and ensures `k3s` or `k3s-agent` is enabled on boot.

Manual equivalent:

```bash
sudo cp host/99-headless-ci.conf /etc/systemd/logind.conf.d/99-headless-ci.conf
sudo systemctl restart systemd-logind

sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

# Edit the Wi‑Fi interface name in the unit (iw dev).
sudo cp host/wifi-no-powersave.service /etc/systemd/system/wifi-no-powersave.service
sudo systemctl daemon-reload
sudo systemctl enable --now wifi-no-powersave.service
```

Keep the machine plugged in.

---



## 11. Custom runner image

Bump `[VERSION](VERSION)` by hand, then build/push with
`[build-push.sh](build-push.sh)` (tags `:<VERSION>` and `:latest`) — see
[README.md](README.md). Public GHCR package avoids imagePullSecrets.

Pin the scale set to the **version tag** (not only `:latest`) in values:

```yaml
# nano ~/arc-runners-values.yaml

image: ghcr.io/ellexistech/arc-runner:0.3.1
```

```bash
helm upgrade ellexis-runners \
  --namespace arc-runners \
  --version 0.14.2 \
  -f ~/arc-runners-values.yaml \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set

kubectl delete pods -n arc-runners \
  -l actions.github.com/scale-set-name=ellexis-runners \
  --ignore-not-found
```

If `docker build` gets `403` pulling `ghcr.io/actions/actions-runner`, run
`docker logout ghcr.io` and retry (stale GHCR auth). Prefer pinning a base
image tag in the Dockerfile `FROM` line instead of `latest`.

---



## 12. Verify

1. Org/repo → **Settings → Actions → Runners** lists the scale set name.
2. A workflow job uses `runs-on: ellexis-runners` (or whatever
  `runnerScaleSetName` you set).
3. On a job: Node/pnpm/`gh`/`jq`/`scc` are available without a long tool download; if you
  mounted `/cache/columbus`, package-manager store paths should land there when your
   workflows configure them (e.g. pnpm 11: `PNPM_CONFIG_STORE_DIR`).

---



## 13. Day-2 ops


| Task               | How                                                                                                                            |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------ |
| Change max runners | `[set-runner-max.sh](set-runner-max.sh)` — from a laptop SSHs to the builder (`MAX_RUNNERS_HOST`), edits values, helm upgrade. |
| Bump image         | Edit `VERSION`, `bash ./build-push.sh`, pin new tag in values, helm upgrade / delete runner pods.                              |
| Chart bump         | Change `--version` deliberately; read ARC release notes.                                                                       |




### Troubleshooting

- **No idle runner pods** — expected with `minRunners: 0`; check the listener.
- **Jobs stuck queued while pods show** `Completed` — ARC 0.14 can leave
`EphemeralRunner` CRs in `phase=Running` with finalizers after the pod
finishes. Those zombies still count toward `maxRunners`. Install the sweeper
once (see below); it force-deletes ERs whose pod is gone / Succeeded / Failed
for ≥2 minutes.
- **pnpm store not on the mount** — pnpm 11 ignores `npm_config_`; use
`PNPM_CONFIG_STORE_DIR` (or equivalent) in the workflow.
- **Lid closes → offline** — re-check logind drop-in and masked sleep targets.



### Stuck EphemeralRunner sweeper (recommended)

Install once on the builder. Runs every **2 minutes**; waits **120s** after a pod
Succeeds/Fails so normal ARC cleanup can win first.

```bash
kubectl apply -f k8s/cleanup-stuck-ephemeralrunners.yaml

kubectl get cronjob -n arc-runners cleanup-stuck-ephemeralrunners
kubectl logs -n arc-runners -l app.kubernetes.io/name=cleanup-stuck-ephemeralrunners --tail=50
```

Optional host timer (same script, no extra image) if you prefer systemd:

```bash
sudo install -m 755 scripts/cleanup-stuck-ephemeralrunners.sh \
  /usr/local/bin/cleanup-stuck-ephemeralrunners.sh
sudo cp host/cleanup-stuck-ephemeralrunners.service \
  host/cleanup-stuck-ephemeralrunners.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now cleanup-stuck-ephemeralrunners.timer
```

Manual one-shot:

```bash
bash scripts/cleanup-stuck-ephemeralrunners.sh
# DRY_RUN=1 GRACE_SECONDS=60 bash scripts/cleanup-stuck-ephemeralrunners.sh
```

---



## 14. Tips for any consuming repository

Workflows should target your scale set name:

```yaml
jobs:
  build:
    runs-on: ellexis-runners
    steps:
      - uses: actions/checkout@v4
      # Prefer tools already in the image; set package-manager store to /cache/columbus/...
```



### Shared cache


| Path (example)               | Role                                      |
| ---------------------------- | ----------------------------------------- |
| `/cache/columbus/pnpm-store` | Shared pnpm store across pods             |
| `/cache/columbus/turbo`      | Local Turbo (or similar) filesystem cache |
| `/cache/columbus/bin`        | Cached tool binaries (gitleaks, osv, …)   |


- Mount via scale-set `template.spec` (`hostPath` or PVC) — see
`[values.example.yaml](values.example.yaml)`.
- On multi-node clusters use a **ReadWriteMany** volume so every node sees the
same store. Keep Actions `_work` on fast local disk.
- Avoid `actions/cache` for huge package stores if post-job uploads stall the
runner.
- Do **not** share `node_modules` across pods.



### Parallel cold installs

If several jobs `pnpm install` at once against an empty shared store, serialize
with `flock` on a lock file under the store directory (or warm the store with a
single job first). After the store is warm, parallel linking is safe.

### Containers / DinD

Default Columbus scale-set values enable **`containerMode.type: dind`** so pods
get a privileged `docker:dind` sidecar and workflows can `docker build` /
buildx (e.g. Release → Ellie images).

On the builder, merge that into `~/arc-runners-values.yaml` (see
[`values.example.yaml`](values.example.yaml)), then:

```bash
helm upgrade ellexis-runners \
  --namespace arc-runners \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
  --version 0.14.2 \
  -f ~/arc-runners-values.yaml
```

(Release name is **`ellexis-runners`**, same as install — not `arc-runners`.)

Smoke:

```bash
# After a job lands on ellexis-runners:
docker info
```

Notes:

- DinD needs **privileged** containers (allowed on this single-node k3s builder).
- Budget more RAM per runner (~1.5–2 Gi); keep `maxRunners` modest on 8GB hosts.
- Do **not** also mount the host `docker.sock` — DinD uses its own socket; host
  bind mounts still resolve on the **node**, not inside the runner container.
- To disable DinD (pnpm-only pool): remove `containerMode` from values and
  `helm upgrade` again; keep image builds on `ubuntu-latest`.

Without DinD this reference builder is **containerd only** — binary tools in
workflows still work; Docker API calls fail with `no such file or directory`
on `/var/run/docker.sock`.

### Remote build caches

Optional: wire your monorepo’s remote cache (Turbo, Nx, etc.) via repository
secrets. A local `/cache/columbus/...` dir can complement remote hits.

---



## Related

- Image: [README.md](README.md) · [Dockerfile](Dockerfile)
- Values: [values.example.yaml](values.example.yaml)
- Host units: [host/](host/)
- Scale script: [set-runner-max.sh](set-runner-max.sh)

