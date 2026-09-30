# SOP: Onboard a new ARC worker node

Complete procedure to take a **fresh Ubuntu Server** from bare metal/VM to a
**k3s agent** in the Ellexis ARC builder cluster (`ellexis-runners`).

The control plane stays on the existing builder (today: `akk.elx` /
`elx-akk`). Workers only run ephemeral runner pods (+ CNI / Traefik svc-lb).
To **move** the control plane later, see
**[MIGRATE-CONTROL-PLANE.md](MIGRATE-CONTROL-PLANE.md)**.

| Role            | Example host     | k3s role        | Notes                                      |
| --------------- | ---------------- | --------------- | ------------------------------------------ |
| Control plane   | `akk.elx`        | `k3s` server    | ARC controller + listener live here        |
| Worker (this)   | `zee.elx`, `kvy.elx`, … | `k3s-agent` | Join only — do **not** install k3s server  |

Related: [SETUP.md](SETUP.md) (full cluster bootstrap),
[`scripts/join-agent.sh`](scripts/join-agent.sh),
[`scripts/apply-headless-host.sh`](scripts/apply-headless-host.sh),
[`scripts/apply-default-route-guard.sh`](scripts/apply-default-route-guard.sh).

---

## 0. Decide before you start

Fill this in for the new machine:

| Item              | Example / guidance                                      |
| ----------------- | ------------------------------------------------------- |
| Short hostname    | `elx-<name>` (k3s node name), e.g. `elx-zee`            |
| SSH / DNS name    | `<name>.elx`, e.g. `zee.elx`                            |
| Static LAN IP     | Free address on `192.168.1.0/24`, e.g. `192.168.1.7`    |
| Gateway           | Usually `192.168.1.1`                                   |
| Control-plane URL | `https://192.168.1.10:6443` (akk LAN IP — prefer IP)    |
| RAM class         | **4 Gi** → reserve for **1** DinD runner (defaults below) |
|                   | **8 Gi+** → lower reservations or raise later           |
| Laptop?           | If yes → headless lid + Wi‑Fi powersave + route guard   |

**4 Gi defaults** (already in `join-agent.sh`):

- `KUBE_RESERVED_MEM=1Gi`
- `SYSTEM_RESERVED_MEM=512Mi`
- → allocatable ≈ **2 Gi** → only one runner with `requests.memory: 1Gi` fits

Do **not** install Docker Engine on the worker — k3s uses containerd; DinD runs
inside the runner pod.

---

## 1. Install Ubuntu Server

1. Install **Ubuntu Server 24.04 LTS** (same major as the control plane).
2. Create a normal sudo user (e.g. `zee`) — avoid day-to-day root login.
3. Enable OpenSSH server during install (or `sudo apt install openssh-server`).
4. Prefer **wired** Ethernet if available; Wi‑Fi works but needs the route guard
   (section 8).
5. Finish install, reboot, log in on console.

Optional first pass (console is fine before static IP / DNS):

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl ca-certificates openssh-server iw
```

---

## 2. Hostname

```bash
sudo hostnamectl set-hostname elx-NAME   # e.g. elx-zee
# Ensure /etc/hosts has a line for 127.0.1.1 elx-NAME
hostname -s   # must match NODE_NAME you will pass to join-agent
```

---

## 3. Static IP (netplan)

Identify the iface:

```bash
ip -br link
# Wi‑Fi: iw dev
```

Edit netplan (Ubuntu 24.04 often uses `/etc/netplan/50-cloud-init.yaml` —
permissions are root-only). Prefer a dedicated drop-in so cloud-init does not
fight you:

```bash
sudo nano /etc/netplan/60-static-lan.yaml
```

**Ethernet example:**

```yaml
network:
  version: 2
  ethernets:
    eth0: # ← your iface
      dhcp4: false
      addresses:
        - 192.168.1.XX/24
      routes:
        - to: default
          via: 192.168.1.1
          on-link: true
      nameservers:
        addresses: [192.168.1.1, 1.1.1.1]
```

**Wi‑Fi example** (merge with existing `wifis:` / access-points from install):

```yaml
network:
  version: 2
  wifis:
    wlp0s12f0: # ← your iface (iw dev)
      dhcp4: false
      addresses:
        - 192.168.1.XX/24
      routes:
        - to: default
          via: 192.168.1.1
          on-link: true
      nameservers:
        addresses: [192.168.1.1, 1.1.1.1]
      access-points:
        "YOUR_SSID":
          password: "YOUR_WIFI_PASSWORD"
```

Apply:

```bash
sudo chmod 600 /etc/netplan/*.yaml
sudo netplan generate
sudo netplan apply
ip -br addr
ip route show default
ping -c 2 192.168.1.1
ping -c 2 1.1.1.1
```

`on-link: true` avoids the common Wi‑Fi race
`Could not set route: Nexthop has invalid gateway` after carrier loss.

---

## 4. Optional — Synology DNS (`*.elx`)

If the office uses a Synology NAS as LAN DNS (so laptops resolve `zee.elx`
without editing every hosts file):

1. DSM → **Control Panel → DNS Server** (or **DHCP Server** → DNS / static
   DHCP mapping — whichever you already use for `kvy.elx`).
2. Add an **A record** (or DHCP reservation + DNS name):

   | Name / host | Type | Value            |
   | ----------- | ---- | ---------------- |
   | `zee`       | A    | `192.168.1.XX`   |

   so FQDN is `zee.elx` if the zone is `elx`.
3. Point the new host’s netplan `nameservers` at the NAS (often `192.168.1.1`
   if the router forwards, or the NAS IP directly).
4. From your **workstation**:

   ```powershell
   Resolve-DnsName zee.elx
   ping zee.elx
   ```

If you skip Synology DNS, use the IP or add a temporary Windows hosts entry /
SSH `Host` alias (section 5).

---

## 5. SSH access from your workstation

### 5.1 Copy your public key

On the new host (console), either paste your pubkey into
`~/.ssh/authorized_keys` or from the workstation:

```powershell
# PowerShell — first connect may ask to trust the host key
ssh-copy-id -i $env:USERPROFILE\.ssh\id_ed25519.pub USER@192.168.1.XX
# or after DNS:
ssh-copy-id -i $env:USERPROFILE\.ssh\id_ed25519.pub USER@zee.elx
```

If `ssh-copy-id` is unavailable on Windows, manually append the pubkey.

### 5.2 Optional `~/.ssh/config` Host alias

```sshconfig
Host zee.elx
  HostName 192.168.1.XX
  User zee
  IdentityFile ~/.ssh/id_ed25519
```

### 5.3 Smoke

```powershell
ssh zee.elx "hostname -s; ip -br addr; free -h"
```

Confirm: short hostname is `elx-…`, IP is static, RAM matches plan.

---

## 6. Copy install scripts (workstation → worker)

From the columbus repo (or the `deploy/arc-runner` checkout):

```powershell
cd d:\dev\columbus\deploy\arc-runner

ssh NEWHOST.elx "mkdir -p ~/arc-host-setup/host ~/arc-host-setup/scripts"

scp scripts/join-agent.sh `
  scripts/apply-headless-host.sh `
  scripts/apply-default-route-guard.sh `
  NEWHOST.elx:~/arc-host-setup/scripts/

scp host/99-headless-ci.conf `
  host/wifi-no-powersave.service `
  host/ensure-default-route.sh `
  host/ensure-default-route.service `
  host/ensure-default-route.timer `
  host/ensure-default-route.path `
  NEWHOST.elx:~/arc-host-setup/host/

ssh NEWHOST.elx "sed -i 's/\r$//' ~/arc-host-setup/host/* ~/arc-host-setup/scripts/*; chmod +x ~/arc-host-setup/scripts/*.sh ~/arc-host-setup/host/*.sh"
```

Scripts must be **LF** line endings (Windows CRLF breaks `set -euo pipefail`).
Repo [`.gitattributes`](.gitattributes) forces `*.sh` → LF; the `sed` line is a
safety net.

---

## 7. Join the k3s cluster (main install)

### 7.1 Fetch the node token (control plane)

On `akk.elx` (needs sudo):

```bash
sudo cat /var/lib/rancher/k3s/server/node-token
```

Treat the token like a secret. Prefer the control-plane **LAN IP** in
`K3S_URL` (stable if DNS flaps).

### 7.2 Install agent on the worker

```powershell
ssh -tt NEWHOST.elx "sudo K3S_URL=https://192.168.1.10:6443 K3S_TOKEN='PASTE_TOKEN' NODE_NAME=elx-NAME bash ~/arc-host-setup/scripts/join-agent.sh"
```

Optional env (defaults shown):

| Env                   | Default            | When to change                          |
| --------------------- | ------------------ | --------------------------------------- |
| `NODE_NAME`           | `hostname -s`      | Must match section 2                    |
| `CACHE_ROOT`          | `/cache/columbus`  | Must match scale-set hostPath           |
| `KUBE_RESERVED_MEM`   | `1Gi`              | Lower on 8 Gi+ hosts if you want >1 pod |
| `SYSTEM_RESERVED_MEM` | `512Mi`            | Same                                    |

What the script does:

1. `apt` install `curl` / `ca-certificates`
2. Creates `/cache/columbus/{pnpm-store,turbo,bin}` (mode `777`)
3. Installs **k3s agent** with kube/system memory reservation
4. Enables `k3s-agent` on boot

### 7.3 Confirm on the control plane

```bash
ssh akk.elx
kubectl get nodes -o wide
# NEW node should be Ready, ROLES empty (<none>), INTERNAL-IP = static IP

kubectl label node elx-NAME arc.ellexis.io/capacity=small --overwrite
# use capacity=large (or omit) on bigger boxes if you invent more labels later

kubectl describe node elx-NAME | grep -A8 Allocatable
```

Expect ~`2135452Ki` memory allocatable on a 4 Gi host with the default
reservations. Flannel `subnet.env` warnings in the first ~30 s are normal;
`svclb-traefik-*` should become Running on the new node.

---

## 8. Laptop hardening (if the worker is a laptop)

Keep the machine **plugged in**.

### 8.1 Lid / sleep / Wi‑Fi powersave

```powershell
ssh -tt NEWHOST.elx "sudo WIFI_IFACE=wlpXsYfZ bash ~/arc-host-setup/scripts/apply-headless-host.sh"
```

Omit `WIFI_IFACE` to auto-detect (`iw dev`). Confirms:

- logind ignores lid / suspend keys
- `sleep` / `suspend` / `hibernate` / `hybrid-sleep` **masked**
- `wifi-no-powersave.service` enabled
- `k3s-agent` enabled on boot

### 8.2 Default-route watchdog (strongly recommended on Wi‑Fi)

After Wi‑Fi carrier loss, systemd-networkd sometimes fails to reinstall the
default gateway → pods cannot reach `api.github.com` (jobs fail even if the
scale set looks Online on akk).

```powershell
ssh -tt NEWHOST.elx "sudo IFACE=wlpXsYfZ GATEWAY=192.168.1.1 bash ~/arc-host-setup/scripts/apply-default-route-guard.sh"
```

Expect: `api.github.com → 200`, timer + path **enabled**, oneshot
`inactive (dead)` with `status=0/SUCCESS` (normal for Type=oneshot).

---

## 9. Cluster capacity (optional)

`maxRunners` is **cluster-wide** (not per node). Adding a worker does not
automatically raise it.

```bash
# from workstation, against control plane:
bash ./set-runner-max.sh 4
# or: MAX_RUNNERS_HOST=akk.elx bash ./set-runner-max.sh 5
```

Scheduling still cannot place two 1 Gi runners on a 4 Gi agent when allocatable
≈ 2 Gi — the extra slot is for **akk** (or other large nodes).

---

## 10. Verification checklist

On **control plane**:

```bash
kubectl get nodes -o wide
kubectl get pods -A -o wide --field-selector spec.nodeName=elx-NAME
kubectl get autoscalingrunnerset -n arc-runners
```

On **worker**:

```bash
systemctl is-enabled k3s-agent
systemctl is-active k3s-agent
ip route show default
curl -sS -o /dev/null -w '%{http_code}\n' --connect-timeout 5 https://api.github.com/
ls -la /cache/columbus
# laptops:
systemctl is-enabled ensure-default-route.timer wifi-no-powersave.service
systemctl is-enabled sleep.target   # expect: masked
```

End-to-end: trigger workflows with `runs-on: ellexis-runners`. When akk is full,
a runner pod should schedule on the new node (`kubectl get pods -n arc-runners -o wide`).

Org → **Settings → Actions → Runners**: scale set stays Online as long as the
**listener on the control plane** can reach GitHub (worker route guard still
matters for jobs that land on that worker).

---

## 11. Troubleshooting

| Symptom | Check / fix |
| ------- | ----------- |
| Node `NotReady` | `journalctl -u k3s-agent -e`; token / `K3S_URL` IP; firewall 6443 from worker → CP |
| Join script CRLF errors (`$'\r'`, `pipefail`) | Re-copy scripts; `sed -i 's/\r$//' …` |
| `network is unreachable` / Offline jobs | `ip route`; install/repair route guard (section 8.2) |
| Pods never land on worker | Capacity full on CP first; check allocatable; no taints unless you added them |
| Only N runners while `maxRunners` higher | ARC scales to **assigned jobs**, not max; see listener `Calculated target runner count` |
| Cache empty on worker | Expected — `hostPath` is **per node**; stores warm independently |

Remove a worker later:

```bash
# drain optional
kubectl drain elx-NAME --ignore-daemonsets --delete-emptydir-data
# on worker:
sudo /usr/local/bin/k3s-agent-uninstall.sh
# on CP:
kubectl delete node elx-NAME
```

---

## Quick reference (copy-paste)

```powershell
# 1) After static IP + SSH work:
cd d:\dev\columbus\deploy\arc-runner
# scp scripts + host units → NEWHOST:~/arc-host-setup/   (section 6)

# 2) Token from CP:
ssh -t akk.elx "sudo cat /var/lib/rancher/k3s/server/node-token"

# 3) Join:
ssh -tt NEWHOST.elx "sudo K3S_URL=https://192.168.1.10:6443 K3S_TOKEN='…' NODE_NAME=elx-NAME bash ~/arc-host-setup/scripts/join-agent.sh"

# 4) Label (on CP):
ssh akk.elx "kubectl label node elx-NAME arc.ellexis.io/capacity=small --overwrite"

# 5) Laptop extras:
ssh -tt NEWHOST.elx "sudo bash ~/arc-host-setup/scripts/apply-headless-host.sh"
ssh -tt NEWHOST.elx "sudo IFACE=WIFI GATEWAY=192.168.1.1 bash ~/arc-host-setup/scripts/apply-default-route-guard.sh"
```
