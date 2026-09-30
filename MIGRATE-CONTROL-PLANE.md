# SOP: Migrate / nominate the k3s control plane

Move the **single** ARC builder control plane from one host to another
(SQLite datastore). Agents keep working after they are **repointed** to the new
API URL. This is **not** multi-server HA — only one `k3s` server may run.

Related: [ONBOARD-WORKER.md](ONBOARD-WORKER.md), [SETUP.md](SETUP.md),
[`scripts/backup-control-plane.sh`](scripts/backup-control-plane.sh),
[`scripts/install-control-plane.sh`](scripts/install-control-plane.sh),
[`scripts/restore-control-plane.sh`](scripts/restore-control-plane.sh),
[`scripts/repoint-agent.sh`](scripts/repoint-agent.sh),
[`scripts/join-agent.sh`](scripts/join-agent.sh).

| Role | Example (after this migrate) | k3s |
| ---- | ---------------------------- | --- |
| Control plane | `akk.elx` / `elx-akk` / `192.168.1.10` | `k3s` server |
| Worker | `kvy.elx`, `zee.elx`, … | `k3s-agent` |

Expect **~15–30 minutes** of ARC downtime (listener Offline until the new CP
and agents are healthy).

---

## 0. Decide before you start

| Item | Example |
| ---- | ------- |
| Old CP SSH / node | `kvy.elx` / `elx-kvy` / `192.168.1.9` |
| New CP SSH / node | `akk.elx` / `elx-akk` / `192.168.1.10` |
| New `TLS_SAN` | `192.168.1.10,akk.elx` (IP required; DNS optional) |
| Agents to repoint | every `k3s-agent` still on the old URL |
| Demote old CP? | yes → uninstall server, `join-agent.sh` |

**Rules**

- Never run **two** servers with the same SQLite backup (split brain).
- Stop the **old** server and leave it stopped until the new one is verified
  (or you roll back by starting the old server again from its local data).
- You cannot “promote” an agent in place — uninstall the agent, install server,
  restore `db` + `token`.

---

## 1. Preflight (new CP host)

On the **new** host:

```bash
hostname -s          # e.g. elx-akk
ip -4 -br addr       # static LAN IP matching TLS_SAN
systemctl is-active k3s-agent   # ok if currently a worker
```

Ensure SSH works and you have sudo. Copy this repo’s `deploy/arc-runner`
scripts (LF line endings) onto both old and new hosts, e.g.:

```powershell
cd d:\dev\columbus\deploy\arc-runner
scp -r scripts host MIGRATE-CONTROL-PLANE.md akk.elx:~/arc-host-setup/
scp -r scripts host MIGRATE-CONTROL-PLANE.md kvy.elx:~/arc-host-setup/
scp scripts/repoint-agent.sh zee.elx:~/
```

Belt-and-suspenders copies from the **old** CP (workstation):

```powershell
scp kvy.elx:~/arc-runners-values.yaml .
scp -r kvy.elx:/etc/github-arc ./github-arc-backup
```

Install **Helm 3** on the new CP if day-2 scripts (`set-runner-max.sh`) will SSH
there (see [SETUP.md](SETUP.md) §3). After cutover, copy
`arc-runners-values.yaml` into the new CP user’s home.

---

## 2. Backup old CP (and freeze)

On the **old** control plane:

```bash
cd ~/arc-host-setup   # or your checkout of deploy/arc-runner
sudo KEEP_STOPPED=1 bash scripts/backup-control-plane.sh
# prints ARCHIVE=/root/k3s-cp-backup-<UTC>.tar.gz
# k3s stays STOPPED
```

Copy the archive to the new CP:

```bash
# from workstation or old → new
scp kvy.elx:/root/k3s-cp-backup-*.tar.gz akk.elx:/root/
```

Do **not** `systemctl start k3s` on the old host until rollback or until you
have demoted it to an agent.

---

## 3. Promote new CP

On the **new** host, if it is still an agent:

```bash
sudo /usr/local/bin/k3s-agent-uninstall.sh
```

Install server + restore:

```bash
cd ~/arc-host-setup
sudo TLS_SAN=192.168.1.10,akk.elx NODE_NAME=elx-akk \
  bash scripts/install-control-plane.sh

sudo BACKUP_ARCHIVE=/root/k3s-cp-backup-YYYYMMDDThhmmssZ.tar.gz \
  bash scripts/restore-control-plane.sh

sudo kubectl get nodes -o wide
sudo kubectl get pods -n arc-systems
sudo kubectl get pods -n arc-runners
```

Delete stale node objects (old CP name + previous agent identity for this host
if it appears twice / NotReady):

```bash
sudo kubectl delete node elx-kvy --ignore-not-found
# if elx-akk was previously an agent and is stuck NotReady alongside the new server:
# sudo kubectl delete node elx-akk --ignore-not-found
# (only if needed — do not delete the Ready control-plane node)
```

Confirm GitHub org → **Settings → Actions → Runners**: scale set returns
**Online** once the listener can reach GitHub from the new CP.

---

## 4. Repoint agents

On each **agent** (same cluster token after restore):

```bash
sudo K3S_URL=https://192.168.1.10:6443 bash ~/repoint-agent.sh
# or: bash ~/arc-host-setup/scripts/repoint-agent.sh
```

On the new CP:

```bash
kubectl get nodes -o wide
```

If an agent stays NotReady: `journalctl -u k3s-agent -e` on that host; confirm
firewall allows worker → `NEW_IP:6443`; TLS SAN must include that IP.

---

## 5. Demote the old control plane to a worker

On the **old** host (server still stopped / data still on disk until uninstall):

```bash
sudo /usr/local/bin/k3s-uninstall.sh
```

Join as agent (token from **new** CP):

```bash
# on new CP:
sudo cat /var/lib/rancher/k3s/server/node-token

# on old host (now worker):
sudo K3S_URL=https://192.168.1.10:6443 K3S_TOKEN='…' \
  NODE_NAME=elx-kvy \
  bash ~/arc-host-setup/scripts/join-agent.sh
```

Label / headless / route guard as needed (see [ONBOARD-WORKER.md](ONBOARD-WORKER.md)).

Copy day-2 files onto the new CP if not already there:

```bash
# on new CP user home
scp workstation:arc-runners-values.yaml ~/
# helm already installed; kubeconfig from install-control-plane.sh
```

Update local defaults: `set-runner-max.sh` should SSH to the new builder
(`MAX_RUNNERS_HOST` / `BUILDER_HOSTNAME`).

---

## 6. Verify

```bash
kubectl get nodes -o wide
kubectl get pods -n arc-systems -o wide
kubectl get pods -n arc-runners -o wide
kubectl get autoscalingrunnerset -n arc-runners
```

Trigger a workflow with `runs-on: ellexis-runners`. Confirm a runner pod lands
and completes.

---

## 7. Rollback

If the new CP never becomes healthy and agents were **not** repointed:

1. Leave the new host alone (or uninstall its server).
2. On the **old** CP: `sudo systemctl start k3s` (local data was never wiped if
   you only stopped it; if you already ran `k3s-uninstall.sh`, restore from the
   backup archive onto that host instead).
3. Agents that still use the old `K3S_URL` reconnect.

If some agents were already repointed, run `repoint-agent.sh` back to the old
URL after the old server is up again.

---

## Quick reference (this cluster)

```powershell
# Scripts → hosts
cd d:\dev\columbus\deploy\arc-runner
scp -r scripts host MIGRATE-CONTROL-PLANE.md akk.elx:~/arc-host-setup/
scp -r scripts host MIGRATE-CONTROL-PLANE.md kvy.elx:~/arc-host-setup/
scp scripts/repoint-agent.sh zee.elx:~/

# Freeze + backup old CP
ssh -t kvy.elx "sudo KEEP_STOPPED=1 bash ~/arc-host-setup/scripts/backup-control-plane.sh"
scp kvy.elx:/root/k3s-cp-backup-*.tar.gz akk.elx:/root/

# Promote akk
ssh -t akk.elx "sudo /usr/local/bin/k3s-agent-uninstall.sh"
ssh -t akk.elx "sudo TLS_SAN=192.168.1.10,akk.elx NODE_NAME=elx-akk bash ~/arc-host-setup/scripts/install-control-plane.sh"
ssh -t akk.elx "sudo BACKUP_ARCHIVE=\$(ls -1t /root/k3s-cp-backup-*.tar.gz | head -1) bash ~/arc-host-setup/scripts/restore-control-plane.sh"

# Repoint zee; demote kvy → join-agent (token from akk)
ssh -t zee.elx "sudo K3S_URL=https://192.168.1.10:6443 bash ~/repoint-agent.sh"
```
