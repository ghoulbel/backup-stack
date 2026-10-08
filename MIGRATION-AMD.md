# MIGRATION-AMD.md — moving the homelab from ROG-Strix to the GMKtec Elite ER937-AI

**Written:** 2026-10-07
**From:** ROG-Strix (Ubuntu, NVIDIA RTX 4060 Laptop, LAN `192.168.1.49`, Tailscale `100.102.27.93`)
**To:** GMKtec Elite ER937-AI (Ubuntu Server, AMD Radeon 890M / gfx1151, 64 GB RAM, 2 TB SSD)
**Why:** ROG-Strix becomes a personal laptop. The new box takes over the LAN IP `192.168.1.49`.

This document is written to be executed by a human **or an LLM with shell access**. Every
step has an explicit *Expect:* line. **Do not skip a step whose Expect line you have not
seen pass.** If an Expect fails, stop and fix that step before continuing — later phases
depend on earlier ones.

---

## Contents

Phases run in this order. §3 is already done; it is listed so you know what happened.

| § | what it is | when |
|---|---|---|
| [0](#0-the-one-paragraph-version) | the one-paragraph version | read first |
| [1](#1-ground-rules--read-before-you-touch-anything) | **ground rules — read before touching anything** | read first |
| [2](#2-inventory--what-exists-and-where-it-lives) | inventory: repos, irreplaceable files, what to copy vs re-download | read first |
| [3](#3-phase-0--old-host-already-completed-2026-10-07) | Phase 0 — OLD HOST, **already completed 2026-10-07** | done |
| [4](#4-phase-1--new-host-baseline) | Phase 1 — new host baseline (Tailscale, SSH, Docker, NFS) | **start here** |
| [5](#5-the-amd-branches--what-actually-changes-on-amd) | the `amd` branches and what changes on AMD | during phase 1 |
| [6](#6-phase-2--restore-the-secrets) | Phase 2 — fetch the secrets back out of Kopia | after §4 |
| [7](#7-phase-3--bring-the-stacks-up-in-dependency-order) | Phase 3 — bring the stacks up in dependency order | after §6 |
| [8](#8-phase-4--copy-the-17-gb-that-cannot-be-re-downloaded) | Phase 4 — copy the ~17 GB that cannot be re-downloaded | after §7 |
| [9](#9-phase-5--the-cutover) | Phase 5 — the cutover, and the only moment you lose service | after §8 |
| [10](#10-phase-6--verification-against-the-22-rules) | Phase 6 — verification, plus **rollback triggers** | end |
| [11](#11-post-move-prove-the-backups-moved-too) | prove the backups moved | end |
| [12](#12-post-move-cleanup) | cleanup | end |
| [13](#13-kopia-cli-traps--read-before-you-debug-a-missing-file) | **Kopia CLI traps — read before debugging a "missing" file** | on demand |
| [14](#14-verified-facts-about-this-estate) | verified facts about this estate | on demand |

### Find it fast

| you need to… | go to |
|---|---|
| know what order to do things in | §0, §1, then the Contents table above |
| find the git remote for a stack | §2.1 |
| know which files are **not** in git | §2.2 |
| know what to copy vs re-download | §2.3 and §2.4 |
| see what a stack's AMD config changes to | §5, then `git diff main..amd` in that repo |
| get the `.env` files, `acme.json`, tunnel secret, SSH key or dumps back | **§6.0** |
| bring a stack up | §7.1–§7.7, in that order |
| move the new box onto `192.168.1.49` | §9.4, §9.5 |
| know why `cloudflared` starts last | §9.7 |
| decide whether to roll back | §10 rollback triggers |
| understand a Kopia error or an empty result | §13 |
| check a fact before trusting it | §14 |

---

## 0. The one-paragraph version

Everything here is either (a) in a git repo on GitHub, (b) in a Kopia snapshot on the NAS,
or (c) re-downloadable. Only ~17 GB is neither re-downloadable nor reproducible, and it
has all been snapshotted and byte-verified. You clone eight repos, restore eight `.env`
files and one NFS mount, copy ~17 GB, bring the stacks up in dependency order, then power
the old box off, move the new box to `.49`, and **only then** start `cloudflared`.

---

## 1. Ground rules — read before you touch anything

| # | Rule | Why |
|---|---|---|
| 1 | **Never run two hosts on `192.168.1.49` at the same time.** | DHCP/ARP fight; both hosts break. |
| 2 | **Bring the new box up on `192.168.1.50` first.** Move to `.49` only after ROG-Strix is powered off (Phase 5). | Same rule, reversed order. |
| 3 | **`cloudflared` starts LAST**, in Phase 5, and only after Authentik answers on the new box. | Starting it earlier points all nine public hostnames at a Traefik that has no identity provider. Every host 302s into a void. |
| 4 | **`identity-stack` comes up FIRST**, before `proxy-stack`. | Everything's SSO depends on it. Traefik's forward-auth middleware points at `authentik-server:9000`. |
| 5 | **Never copy a Postgres data directory.** | Both are uid 70 and unreadable; a raw copy of a live database is also *wrong*, not just impossible. Use `pg_dump`. Already done — you just restore the dumps. |
| 6 | **Do not re-pull ollama or ComfyUI weights tonight.** 217 GB, multi-hour. Not needed for any service to be "up". |
| 7 | **`llama-cpp-lab` does not migrate.** 177 GB playground, own repo, own remote. Out of scope. |
| 8 | **Frigate does not migrate.** The cameras are not physically mounted. Do not port `stable-tensorrt` — TensorRT is NVIDIA-only and will not start. |
| 9 | **Take a fresh Kopia snapshot before powering the old box off.** | Anything you change tonight after Phase 3 is not in the snapshot. |
| 10 | **Keep ROG-Strix powered and intact until Phase 6 verification passes.** | It is the rollback. Its disk is your safety net. |

---

## 2. Inventory — what exists and where it lives

### 2.1 Git repositories (all on GitHub over SSH)

| Path | Branch | Remote |
|---|---|---|
| `proxy-stack/` | `main` | `git@github.com:ghoulbel/proxy-stack.git` |
| `identity-stack/` | `main` | `git@github.com:ghoulbel/identity-stack.git` |
| `ai-stack/` | `main` | `git@github.com:ghoulbel/nvidia-ai-stack.git` (repo name differs from dir!) |
| `arr-stack/` | `main` | `git@github.com:ghoulbel/nvidia-arr-stack.git` (repo name differs from dir!) |
| `monitoring-stack/` | `main` | `git@github.com:ghoulbel/monitoring-stack.git` |
| `backup-stack/` | `main` | `git@github.com:ghoulbel/backup-stack.git` |
| `ai-project/intimacy-connection/` | `deepseek` | `git@github.com:ghoulbel/intimacy-connection.git` |
| `ai-project/pip-story-friend/` | `deepseek` | `git@github.com:ghoulbel/pip-story-friend.git` |

**`ai-stack` and `arr-stack` have an `amd` branch** prepared for the Radeon 890M. See §5.
Clone those two with `git clone -b amd`.

The parent directory `/home/ghoulbel/Documents` is itself a git repo (branch `master`) with
**no remote**. It holds `bootstrap.sh`. Copy it by hand (§4.2) or it is lost.

Git identity on the old box: `ghoulbel <bel.g@gmx.ch>`.

### 2.2 Things that are NOT in git and must be restored by hand

| Item | Where it lives now | Critical? |
|---|---|---|
| 9 `.env` files | Kopia `/hostconfig` snapshot `cfd4b5bbb7051581f20ad5fa4738679b` (verified) | **YES — irreplaceable** |
| `proxy-stack/letsencrypt/acme.json` | Kopia `/source` snapshot `0ec8e3fbf38fed3ca33fec58ad051003` (verified) | recoverable by re-issue, but copy it |
| `~/.cloudflared/246b168c-…json` (TunnelSecret) | Kopia `/hostconfig` (md5-verified) | **YES — cannot be regenerated** |
| `~/.cloudflared/config.yml` | Kopia `/hostconfig` (verified) | **YES** |
| `~/.ssh/` (the key that pushes all 9 repos) | Kopia `/hostconfig` (fingerprint-verified) | **YES** |
| `/etc/fstab` NFS options | Kopia `/hostconfig/hostconfig-fstab` (verified) | **YES** |
| `/etc/cloudflared/config.yml` | same file as `~/.cloudflared/config.yml` | YES |
| `cloudflared.service` unit | Kopia `/hostconfig/hostconfig-etc/` | no — stock Debian package unit |
| Tailscale node identity | **nowhere — must re-authenticate** | see §4.1 |

### 2.3 Data that must be copied (~17 GB total)

| Path | Size | Re-downloadable? |
|---|---|---|
| `arr-stack/config/` | 6.4 GB | **NO** — Sonarr/Radarr/Lidarr DBs, qBittorrent torrents, uptimekuma `kuma.db` (367 MB), suggestarr `requests.db`, Jellyfin library + watch history |
| `ai-stack/data/webui/` | 2.5 GB | **NO** — OpenWebUI chats, users, settings |
| `monitoring-stack/homeassistant/config/` | 32 MB | **NO** — HA state |
| `ai-stack/data/comfyui/custom_nodes/`, `ai-stack/data/comfyui/user/` | small | **NO** — your workflows. Weights are re-downloadable. |
| `identity-stack/backups/authentik-20261007-170932.dump` | 5.4 MB | already in the snapshot |
| `ai-project/intimacy-connection/backups/embrace-20261007-170315.dump` | 68 KB | already in the snapshot |

### 2.4 Data that is re-downloadable — do NOT copy

`ai-stack/data/ollama` (156.6 GB), `ai-stack/data/comfyui/models` + `output` (61 GB),
`ai-stack/data/qdrant` (3 GB, regenerable), `ai-stack/data/tts` (1.8 GB, cache),
`monitoring-stack/{prometheus_data,loki_data,alloy_data,grafana_data}` (6.4 GB, history).

Media does not move at all — it is already on the Synology NFS mount.

---

## 3. Phase 0 — OLD HOST, already completed 2026-10-07

Everything in this phase is **done**. Verify it, do not redo it.

| # | Action | Evidence it succeeded |
|---|---|---|
| 0.1 | `pip-story-friend/.env` chmod 600 | was 755, world-readable, held an LLM API key |
| 0.2 | Captured `/etc/cloudflared/config.yml`, `/etc/fstab`, `/etc/hosts`, `cloudflared.service` into `~/.config/hostconfig-*` | files present |
| 0.3 | Deleted the 501 MB dead `~/.config/opencode-broken` | gone |
| 0.4 | `pg_dump` **embrace** | `ai-project/intimacy-connection/backups/embrace-20261007-170315.dump`, 67,537 B, real restore exit 0, row counts identical to production |
| 0.5 | `pg_dump` **identity-stack** | `identity-stack/backups/authentik-20261007-170932.dump`, 5,381,321 B, real restore exit 0 |
| 0.6 | Kopia snapshot `/source/arr-stack/config` | id `c3b77140b1e8010ce0fbad2f88b21820` (was 4 days stale) |
| 0.7 | Kopia snapshot `/source` | id `0ec8e3fbf38fed3ca33fec58ad051003`, root object `k966e58bb25e5a0e5d074b49e68e7fdd5` |
| 0.8 | Kopia snapshot `/hostconfig` | id `cfd4b5bbb7051581f20ad5fa4738679b`, 81 files / 236 KB |
| 0.9 | Restore-verify all ten critical objects | all md5 **IDENTICAL** to live |

> **Note:** the embrace database holds **zero** love letters and zero memories. It was
> re-initialised on 2026-09-25 and the oldest Kopia snapshot is 2026-10-02, so that content
> never existed on this box and was not lost in this migration.

### 0.10 — ACTION REQUIRED FROM THE USER, BEFORE POWERING OFF

`KOPIA_PASSWORD` must be copied into a password manager **and onto paper**. Kopia cannot do
this for you: the repository now contains the Cloudflare TunnelSecret, the SSH key that
pushes all nine repos, `AUTHENTIK_SECRET_KEY`, `CF_DNS_API_TOKEN`, the embrace `MASTER_KEY`,
every database password and `KOPIA_SERVER_PASSWORD` — and its only copy of its own password
is inside the repository it unlocks. Lose it and every backup since the beginning is gone.

**Expect:** the password is in a password manager, and written on paper, and you have read
it back and confirmed it matches `grep '^KOPIA_PASSWORD=' /home/ghoulbel/Documents/backup-stack/.env`.

---

## 4. Phase 1 — NEW HOST baseline

Do all of this on the new box. It should be on **`192.168.1.50`**, not `.49`.

### 4.1 Tailscale — must be re-authenticated, cannot be copied

The node state is encrypted and bound to the host. There is nothing to copy.

```bash
sudo tailscale up --accept-routes=false --advertise-tags=tag:homelab
```

If the tag is rejected (`requested tags [...] are invalid or not permitted`) drop the flag:

```bash
sudo tailscale up --accept-routes=false
```

**Decisions to carry over from the old box:**
- `--accept-routes` **must stay OFF.** A dead peer (`minix`) advertises `192.168.1.0/24`
  and `0.0.0.0/0`; accepting those risks flipping your default route when it returns.
- Use a **new hostname** (do not reuse `rog-strix`).
- **After** the migration works, decommission the old node in the Tailscale admin console.
  Merely powering the box off leaves a ghost entry.

**Expect:** `tailscale status | head -1` shows your new hostname, and `tailscale ip -4`
returns an address on `100.x`.

### 4.2 SSH key

```bash
# Restore it from Kopia first -- §6.0 step 4 writes it to /tmp/restore/id_ed25519.
# It is the key that pushes all nine repos, so a fresh one means re-adding a deploy
# key to every remote. Losing it is recoverable but annoying.
mkdir -p ~/.ssh && chmod 700 ~/.ssh
install -m 600 /tmp/restore/id_ed25519 ~/.ssh/id_ed25519
install -m 644 /tmp/restore/id_ed25519.pub ~/.ssh/id_ed25519.pub 2>/dev/null || true
# restore from Kopia, then:
chmod 600 ~/.ssh/id_ed25519; chmod 644 ~/.ssh/id_ed25519.pub
ssh -T git@github.com
```

**Expect:** GitHub greets you by username. If it says `Permission denied (publickey)` the key
did not restore correctly — stop and fix it, because every clone in §5 depends on it.

### 4.3 Git identity and Docker

```bash
git config --global user.name  "ghoulbel"
git config --global user.email "bel.g@gmx.ch"
```

Install Docker Engine + Compose v2. **Match the old versions if you can** so behaviour is
identical: old box had **Docker 29.8.2, Compose 5.6.0**.

```bash
sudo usermod -aG docker "$USER"   # log out and back in, or: newgrp docker
docker --version && docker compose version
```

**Expect:** both version commands print a version; `docker run --rm hello-world` succeeds.

### 4.4 NFS mount — media and backups live here

```bash
sudo mkdir -p /mnt/synology
# options captured from the live mount on the old box:
#   nfs4  rw,noatime,vers=4.1,rsize=524288,wsize=524288,hard,proto=tcp,sec=sys,_netdev
sudo mount -t nfs4 -o rw,noatime,vers=4.1,rsize=524288,wsize=524288,hard,proto=tcp,sec=sys \
  192.168.1.198:/volume1/data /mnt/synology
```

Then make it permanent — add to `/etc/fstab`:

```
192.168.1.198:/volume1/data /mnt/synology nfs4 rw,noatime,vers=4.1,rsize=524288,wsize=524288,hard,proto=tcp,sec=sys,_netdev 0 0
```

**No Synology change is needed.** The new box ends up with the same client IP (`.49`), and
the export is already permitted.

**Expect:**
```bash
ls /mnt/synology/downloads | head
touch /mnt/synology/downloads/.writecheck && rm /mnt/synology/downloads/.writecheck
```
`touch` must succeed. The media directories are mode `777` so access is gated by mode, not
by uid — you do **not** need uid 1026 to exist on the new box.

### 4.5 Host facts the stacks will look up

```bash
getent group render; getent group video
```

**Expect:** both print a line. Note the **gid numbers** — they are host-specific and will
*not* be 993. On the old box `993` was `sgx` and `render` was `990`; on the old MiniX, `993`
*was* render. **Never hard-code a gid** — §4.7 makes `bootstrap.sh` resolve and publish it
for you into the stacks' `.env` files.

### 4.6 Copy the parent `bootstrap.sh`

It has no remote. Copy it off the old box or out of the Kopia snapshot into
`/home/ghoulbel/Documents/bootstrap.sh`.

**Expect:** `bash -n ~/Documents/bootstrap.sh` exits 0.

### 4.7 Resolve the render/video GIDs (needed only on the `amd` branches)

```bash
cd ~/Documents && ./bootstrap.sh
```

Section `3b. GPU render group` of that script reads `getent group render` and
`getent group video` and publishes `RENDER_GID` / `VIDEO_GID` into the `.env`
of `ai-stack`, `arr-stack` and `monitoring-stack`. Run it **after** copying the
script and **before** any `docker compose` command on those stacks — the compose
files guard with `${RENDER_GID:?...}`, so a missing value fails the run loudly
instead of producing a container that silently cannot open `/dev/dri`.

**Expect:**

```
ok  published TAILSCALE_IP=100.102.27.93 to: identity-stack/.env ai-stack/.env ...
ok  published RENDER_GID=989 VIDEO_GID=44 to: ai-stack/.env arr-stack/.env monitoring-stack/.env
```

then confirm:

```bash
grep -H '^RENDER_GID=\|^VIDEO_GID=' ~/Documents/{ai,arr,monitoring}-stack/.env
```

**Expect:** exactly one `RENDER_GID=` per file, holding *your host's* number.
Record it in §2 — it is whatever this host prints, not 993. (993 was `render` on
the old MiniX but is `sgx` on ROG-Strix, where render is 990. That mismatch
costs VAAPI with no error message anywhere.)

If the command warns `no 'render' group on this host`, the GPU users/groups are
not created yet: `sudo usermod -aG render,video $USER`, then log out and back in.
---

## 5. The `amd` branches — what actually changes on AMD

Three repos differ from `main`. **Clone those with `-b amd`:**

```bash
git clone -b amd git@github.com:ghoulbel/nvidia-ai-stack.git      ai-stack
git clone -b amd git@github.com:ghoulbel/nvidia-arr-stack.git     arr-stack
git clone -b amd git@github.com:ghoulbel/monitoring-stack.git     monitoring-stack
```

The other five are hardware-agnostic — clone them on `main`.

All three `amd` branches are committed and pushed. Reference commits, in case you
need to see exactly what changed or cherry-pick a piece:

| repo | branch | commit | what it does |
|---|---|---|---|
| `ai-stack` | `amd` | `4a36271` | rebuilt from `docker-compose.yaml.minix-recovered`: ollama → `ollama/ollama:rocm` + `/dev/kfd` `/dev/dri` + `OLLAMA_IGPU_ENABLE=1`; comfyui → `rocm/pytorch:latest` with `TORCH_BLAS_PREFER_HIPBLASLT=0`, `PYTORCH_HIP_ALLOC_CONF`, `--force-fp16 --cpu-vae --lowvram` |
| `arr-stack` | `amd` | `cfd3de7` | rebuilt from `docker-compose.yaml.minix-backup`: jellyfin → `/dev/dri/renderD128` + render group |
| `monitoring-stack` | `amd` | `5236eea` | rebuilt from `docker-compose.yaml.minix.copy`: `dcgm-exporter` → `kmulvey/radeon_exporter` as `amd-metrics-exporter`; frigate → `stable-rocm` + `LIBVA_DRIVER_NAME=radeonsi`; the GPU scrape job points at `amd-metrics-exporter:9200` |

These are transcriptions of the compose files the MiniX actually ran with the same
Radeon 890M, not something newly designed. The only substitution anywhere is the
render group: `"993"` → `${RENDER_GID:?...}`, because 993 was `render` on the MiniX
and is `sgx` here, where `render` is 990 (§4.7 resolves it).

```bash
# review any of them before you trust it
cd ai-stack        && git log --oneline main..amd && git diff main..amd
cd ../arr-stack    && git log --oneline main..amd
cd ../monitoring-stack && git log --oneline main..amd
```

**Expect:** one commit each, on top of `main`.

### 5.1 `ai-stack` — two services

**ollama.** `gpus: all` is an NVIDIA runtime directive and **errors out** if the NVIDIA
container toolkit is missing. Dropped. `OLLAMA_VULKAN=1` instead.

> **Read this before trusting local models.** ROCm has **no released support for gfx1151**
> (the 890M); the upstream request is still open. Vulkan is the realistic path, not a
> guaranteed one. Test it before you rely on it.

**ComfyUI.** The CUDA image `pytorch/pytorch:2.12.1-cuda13.0-cudnn9-runtime` is useless on
a Radeon. The branch installs torch from `https://rocm.nightlies.amd.com/v2/gfx1151/`
(the exact index ComfyUI's own vendored README recommends — see `README.md:247` in the
ComfyUI checkout), plus `HSA_OVERRIDE_GFX_VERSION=11.0.0`,
`TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL=1` and `PYTORCH_TUNABLEOP_ENABLED=1`.

> **Expect CPU-only.** 890M shared-memory/GTT handling is an unresolved upstream ComfyUI
> issue. The branch carries a documented CPU-only fallback. Do not promise GPU image
> generation on this chip until you have seen it produce an image.

### 5.2 `arr-stack` — one service

**jellyfin** moves from `gpus: all` (NVIDIA NVENC) to **VAAPI** via `/dev/dri/renderD128`
plus `group_add` for the render/video gids from §4.7. Jellyfin auto-detects VAAPI; no config
change needed.

### 5.3 `monitoring-stack` — two changes

- **`dcgm-exporter` removed.** It is NVIDIA-only (`nvidia/dcgm-exporter`, `cap_add: SYS_ADMIN`,
  `gpus: all`). Its AMD equivalent is `kmulvey/radeon_exporter`, which your old MiniX compose
  file used. **It is deliberately not added back** — the cameras are not mounted, so there is
  nothing meaningful to scrape and a permanently-down target is just noise. Re-add it later
  when you want GPU dashboards again.
- **frigate commented out.** `stable-tensorrt` is NVIDIA-only. Leave it commented until the
  cameras are physically mounted, then use the AMD-appropriate Frigate image for your card.

---

## 6. Phase 2 — restore the secrets

Do this immediately after cloning, before starting anything.

### 6.0 Fetch the objects out of Kopia

You need Kopia's password and the repo config **on the old host**, because the repo
lives on the NAS mounted there. Do this before the old box is switched off.

`kopia show` takes a **root entry object id**, not the snapshot id. Passing the
snapshot id silently returns nothing, and the md5 of nothing is
`d41d8cd98f00b204e9800998ecf8427e`, so a swallowed error looks like a real mismatch.

```bash
mkdir -p /tmp/restore && cd ~/Documents/backup-stack
K() { docker exec -e KOPIA_PASSWORD="$(grep '^KOPIA_PASSWORD=' .env | cut -d= -f2-)" \
       kopia kopia "$@" --config-file=/app/config/repository.config; }

# Discover these at run time. Do not copy the ids from this file: the playbook
# itself is inside the snapshot, so any id written here goes stale the moment this
# file changes. Only the newest snapshot has the configuration you want.
rootobj() { K snapshot list "$1" --json 2>/dev/null \
            | python3 -c "import sys,json;print(json.load(sys.stdin)[-1]['rootEntry']['obj'])"; }
SRC=$(rootobj /source)
HC=$(rootobj /hostconfig)
echo "SRC=$SRC  HC=$HC"

# As of 2026-10-07 these were:
#   SRC=k966e58bb25e5a0e5d074b49e68e7fdd5   HC=k50a8fcb5247bf748d772ea3d8c0c0a60

# 1. all nine .env files -- MASTER_KEY and AUTHENTIK_SECRET_KEY live in these,
#    so never generate fresh values
for f in identity-stack proxy-stack ai-stack arr-stack monitoring-stack backup-stack \
         ai-project/intimacy-connection ai-project/pip-story-friend; do
  mkdir -p "/tmp/restore/$(dirname "$f")"
  K show "$SRC/$f/.env" > "/tmp/restore/$f.env"
  chmod 600 "/tmp/restore/$f.env"
done

# 2. TLS certificate store
K show "$SRC/proxy-stack/letsencrypt/acme.json" > /tmp/restore/acme.json

# 3. database dumps
K show "$SRC/identity-stack/backups/authentik-20261007-170932.dump" \
  > /tmp/restore/authentik.dump
K show "$SRC/ai-project/intimacy-connection/backups/embrace-20261007-170315.dump" \
  > /tmp/restore/embrace.dump

# 4. host-local config: tunnel secret, tunnel ingress, SSH key, fstab, unit file
K show "$HC/cloudflared/246b168c-7c77-47e1-9a89-d89c1fdb293f.json" \
  > /tmp/restore/246b168c-7c77-47e1-9a89-d89c1fdb293f.json
K show "$HC/cloudflared/config.yml"  > /tmp/restore/cloudflared-config.yml
K show "$HC/ssh/id_ed25519"          > /tmp/restore/id_ed25519
K show "$HC/hostconfig-fstab"        > /tmp/restore/fstab
K show "$HC/hostconfig-etc/cloudflared.service" > /tmp/restore/cloudflared.service
```

**Expect:** every file is non-empty. One line catches every failure mode at once,
because the only way `kopia show` returns nothing is a wrong object id or a bad path:

```bash
find /tmp/restore -type f -empty    # must print nothing
md5sum /tmp/restore/id_ed25519 ~/.ssh/id_ed25519   # must match
```

### 6.1 The nine `.env` files

Every `.env` is gitignored, so a clone has none. Restore them from Kopia.

On the old box (or from a Kopia restore):

```bash
cd /home/ghoulbel/Documents/backup-stack
K() { docker exec -e KOPIA_PASSWORD="$(grep '^KOPIA_PASSWORD=' .env | cut -d= -f2-)" \
       kopia kopia "$@" --config-file=/app/config/repository.config; }
mkdir -p /tmp/restore

# example: pull one object out of the /source snapshot.
# /source root object id is  k966e58bb25e5a0e5d074b49e68e7fdd5  (NOT the snapshot id)
K show k966e58bb25e5a0e5d074b49e68e7fdd5/identity-stack/.env > /tmp/restore/identity-stack.env
```

Repeat for each of:

```
proxy-stack/.env                     identity-stack/.env
ai-stack/.env                        arr-stack/.env
monitoring-stack/.env                backup-stack/.env
ai-project/intimacy-connection/.env  ai-project/pip-story-friend/.env
```

Then place each one next to its `docker-compose.yaml` and `chmod 600`.

> **Do not generate new values.** These contain `AUTHENTIK_SECRET_KEY` (changing it
> invalidates every session), `CF_DNS_API_TOKEN`, the three OAuth client secrets, and the
> embrace `MASTER_KEY` (changing it makes the love-letter keys undecryptable). Copy them.

**Expect:** each file exists, is mode 600, and `grep -c '^[A-Z]' <file>` is non-zero.
`ai-stack`, `arr-stack` and `monitoring-stack` `.env` also carry `TAILSCALE_IP` from the old
box — `../bootstrap.sh` republishes it for the new one; see §7.1.

### 6.2 TLS certificates

```bash
cp /tmp/restore/acme.json ~/Documents/proxy-stack/letsencrypt/acme.json
chmod 600 ~/Documents/proxy-stack/letsencrypt/acme.json
```

**Expect:** mode is 600. If Traefik cannot read it you get
`permissions 755 ... are too open` and it will not start.

### 6.3 Cloudflare tunnel credentials

```bash
mkdir -p /etc/cloudflared ~/.cloudflared
cp /tmp/restore/246b168c-7c77-47e1-9a89-d89c1fdb293f.json /etc/cloudflared/
cp /tmp/restore/246b168c-7c77-47e1-9a89-d89c1fdb293f.json ~/.cloudflared/
cp /tmp/restore/cloudflared-config.yml /etc/cloudflared/config.yml
chmod 600 /etc/cloudflared/246b168c-7c77-47e1-9a89-d89c1fdb293f.json
chmod 644 /etc/cloudflared/config.yml
```

**Expect:** `cloudflared tunnel --config /etc/cloudflared/config.yml ingress validate`
prints `OK` and does **not** print any `unused keys` or `not found in type` line. That
validator **exits 0 even when it warns**, so grep the output — do not trust the exit code.

> **No DNS changes are needed.** You are reusing the same tunnel UUID and the same public IP,
> so all nine hostnames keep working untouched. Do not create a new tunnel.

### 6.4 `proxy-stack/.env` sanity

Confirm `CF_DNS_API_TOKEN` is present and non-empty. It is what lets Traefik solve DNS-01 and
renew certificates unattended.

**Expect:** `grep -c '^CF_DNS_API_TOKEN=cfut_' ~/Documents/proxy-stack/.env` → `1`.

---

## 7. Phase 3 — bring the stacks up in dependency order

**Never start `cloudflared` in this phase.**

### 7.0 External networks, once

```bash
cd ~/Documents && ./bootstrap.sh
```

Creates the external `proxy` network and the `--internal` `backend` network, and publishes
the new `TAILSCALE_IP` into the four stacks that need it (`identity-stack`, `ai-stack`,
`arr-stack`, `monitoring-stack`).

**Expect:** `docker network ls` lists both `proxy` and `backend`, and `docker network inspect
backend --format '{{.Internal}}'` prints `true`. Each of the four `.env` files contains
exactly one `TAILSCALE_IP=` line.

### 7.1 identity-stack — FIRST, everything depends on it

```bash
cd ~/Documents/identity-stack && ./bootstrap.sh && docker compose up -d
```

> **Critical:** `AUTHENTIK_BOOTSTRAP_EMAIL` and `AUTHENTIK_BOOTSTRAP_PASSWORD` in `.env` are
> **inert** — bootstrap variables are consumed once at first initialisation and ignored
> forever after. Restoring the existing Postgres dump means the original accounts, passwords
> and akadmin's TOTP come back with it. **Do not "helpfully" change them.** akadmin's TOTP
> secret lives only in the database; there is no recovery path if you lose it.

**Expect:**
```bash
docker compose ps                      # all three Up (healthy)
docker exec authentik-postgresql psql -U authentik -d authentik -tAc \
  "select name||' = '||status from authentik_blueprints_blueprintinstance where name like 'homelab%' order by name;"
```
All five custom blueprints report `successful`, and `authentik_core_user` contains
`akadmin`, `marina`, `moncef`.

**Wait for health.** First-boot migrations take minutes; `start_period` is 120 s. Do not
proceed until the healthcheck passes.

### 7.2 proxy-stack — Traefik, the sole front door

```bash
cd ~/Documents/proxy-stack && docker compose up -d
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8082/ping   # 200
```

**Expect:** ping returns `200`, container is `healthy`, and `docker logs traefik` contains no
`level=error` lines.

On first start it issues Let's Encrypt certificates for `sso`, `traefik` and `grafana` via
DNS-01. That takes ~15 s. **A `TRAEFIK DEFAULT CERT` on the first check is not a fault** —
wait and re-check before debugging.

### 7.3 monitoring-stack

`prometheus/prometheus.yml` is **gitignored and host-local**, but `docker-compose.yaml`
bind-mounts it read-only into the container:

```
- ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
```

A fresh clone has only the tracked `prometheus.yml.example`. If you `up -d` without
creating the live file, Docker creates a **directory** at that path and Prometheus
exits with a config-file error. Create it first:

```bash
cd ~/Documents/monitoring-stack
sed "s|REPLACE_WITH_HA_BEARER_TOKEN|$(grep '^HA_BEARER_TOKEN=' .env | cut -d= -f2-)|" \
    prometheus/prometheus.yml.example > prometheus/prometheus.yml
grep -c REPLACE_WITH prometheus/prometheus.yml     # must print 0
```

`prometheus.yml.example` on the `amd` branch already carries the `amd_gpu` job pointing
at `amd-metrics-exporter:9200`, so do not hand-edit the job names.

```bash
docker compose up -d
```

**Expect:** all containers `Up`; `up{job="prometheus"}` and the other scrape targets
report `up=1` in Grafana. On the `amd` branch the GPU target is `amd_gpu` and Frigate
**is** present (it runs `stable-rocm` there — see §5). The renderer is
`kmulvey/radeon_exporter`; if `amd_gpu` is down, check
`docker logs amd-metrics-exporter` for a `/dev/dri` permission error and confirm
`RENDER_GID` resolved in §4.7.

> Frigate needs cameras. If they are not mounted on the new host, `up{job="frigate"}`
> will be 0 — that is correct, not a fault.

### 7.4 arr-stack

```bash
cd ~/Documents/arr-stack && docker compose up -d
```

**Expect:** every service `Up`. qBittorrent's WebUI answers on `http://192.168.1.50:8080`.
Note port `6881` stays published on `0.0.0.0` for inbound BitTorrent peers — that is
deliberate and unchanged.

### 7.5 ai-stack

```bash
cd ~/Documents/ai-stack && docker compose up -d
```

**Expect:** `open-webui` healthy; `http://127.0.0.1:3000/api/config` returns 200.

> **`OLLAMA_KEEP_ALIVE=0` is load-bearing.** The 890M shares unified memory with everything
> else, and ComfyUI will fail with `torch.OutOfMemoryError: Allocation on device 0 would
> exceed allowed memory` if ollama holds it. On the old box `llama-server` sat on 7518 MiB
> with `expires_at: 2319-01-17` and starved ComfyUI completely. Do not remove it.

Do **not** pull ollama's 156 GB of weights tonight. `ollama pull <model>` as needed.

### 7.6 backup-stack

```bash
cd ~/Documents/backup-stack && ./bootstrap.sh && docker compose up -d
```

**Expect:** the kopia server container is healthy on `127.0.0.1:5151`, and `policy list`
shows four sources: `(global)`, `root@kopia:/hostconfig`, `root@kopia:/source`,
`root@kopia:/source/arr-stack/config`.

> **`--one-file-system=false` on `/hostconfig` is mandatory.** `/hostconfig` is a plain
> directory on the container's own overlay filesystem that *contains six bind mounts* on a
> different device. Kopia's default `oneFileSystem: true` refuses to descend into a mount
> point on another device, silently snapshots **zero files**, and reports "no files have been
> changed" on every re-run. This actually happened and produced two empty snapshots. The
> value is set in `bootstrap.sh`; do not remove it.

### 7.7 embrace and pip-story

```bash
cd ~/Documents/ai-project/intimacy-connection && docker compose up -d
cd ~/Documents/ai-project/pip-story-friend   && docker compose up -d
```

Restore the embrace database from its dump **before** you consider it migrated:

```bash
cd ~/Documents/ai-project/intimacy-connection
cat backups/embrace-20261007-170315.dump | docker compose exec -T postgres \
  sh -c 'pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --no-acl --clean'
```

**Expect:** restore exits 0, and `docker compose exec -T postgres sh -c 'psql -U
"$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "select count(*) from \"User\""'` prints `2`.

---

## 8. Phase 4 — copy the ~17 GB that cannot be re-downloaded

Do this while the old box is still powered on.

```bash
# from the NEW box, pulling from the OLD box over the LAN:
rsync -aH --info=progress2 \
  OLD_IP:/home/ghoulbel/Documents/arr-stack/config/            ~/Documents/arr-stack/config/
rsync -aH --info=progress2 \
  OLD_IP:/home/ghoulbel/Documents/ai-stack/data/webui/         ~/Documents/ai-stack/data/webui/
rsync -aH --info=progress2 \
  OLD_IP:/home/ghoulbel/Documents/monitoring-stack/homeassistant/config/ \
                                                               ~/Documents/monitoring-stack/homeassistant/config/
rsync -aH --info=progress2 \
  OLD_IP:/home/ghoulbel/Documents/ai-stack/data/comfyui/custom_nodes/ \
                                                               ~/Documents/ai-stack/data/comfyui/custom_nodes/
rsync -aH --info=progress2 \
  OLD_IP:/home/ghoulbel/Documents/ai-stack/data/comfyui/user/  ~/Documents/ai-stack/data/comfyui/user/
```

Do **not** rsync any Postgres data directory.

**Expect:** each command finishes; then
```bash
du -sh ~/Documents/arr-stack/config ~/Documents/ai-stack/data/webui
```
≈ 6.4 GB and ≈ 2.5 GB.

> **Ownership.** `arr-stack` runs as `${PUID:-1000}`. If your new user is not uid 1000, set
> `PUID`/`PGID` in `arr-stack/.env` to match and `chown -R` the copied `config/` tree. The
> NFS media dirs are mode 777, so uid does not matter there — only local config does.

---

## 9. Phase 5 — the cutover

This is the only genuinely dangerous phase. Take it in order.

### 9.1 Pre-flight

- [ ] Phase 0.10 done (`KOPIA_PASSWORD` in a password manager and on paper)
- [ ] Every `Expect` in §4–§8 has passed
- [ ] A **fresh** Kopia snapshot has been taken on the old box (anything you changed tonight is not in the old snapshot)
- [ ] `ping` from the new box to the old box works

### 9.2 Stop the old box's public surface

```bash
sudo systemctl stop cloudflared
```

**Expect:** `systemctl is-active cloudflared` prints `inactive`. All nine public hostnames now
return Cloudflare's 1033 error. That is expected and brief.

### 9.3 Stop the old services

```bash
cd ~/Documents
for d in ai-project/pip-story-friend ai-project/intimacy-connection ai-stack arr-stack \
         monitoring-stack proxy-stack identity-stack; do
  (cd "$d" && docker compose stop)
done
```

**Expect:** every container in `docker ps` is `Exited` or `Absent`.

### 9.4 Power off the old box and release the IP

```bash
# on the OLD box:
sudo shutdown -h now
```

**Expect:** the host goes down. **Then** confirm `.49` is free — wait for the DHCP lease to
expire or, better, check your router's DHCP reservation and move the new box's reservation to
`.49`. Do not power the old box back on while the new box holds `.49`.

### 9.5 Move the new box to `192.168.1.49`

```bash
# on the NEW box — pick whichever your setup uses:
sudo netplan apply            # after editing /etc/netplan/*.yaml to 192.168.1.49
# or, for a NetworkManager host:
nmcli con mod "<conn>" ipv4.addresses 192.168.1.49/24 && nmcli con up "<conn>"
```

**Expect:** `ip -4 addr show | grep 192.168.1.49` prints the address, and
`ping -c1 192.168.1.198` (the Synology) succeeds. **The NFS mount survives the IP change
because the export is keyed on the client address and it is now the same `.49` — re-check it
anyway with the `touch` test from §4.4.**

### 9.6 Verify locally BEFORE exposing anything

```bash
curl -sk -o /dev/null -w '%{http_code}\n' --resolve sso.ghoulhub.uk:443:127.0.0.1 https://sso.ghoulhub.uk/
curl -sk -o /dev/null -w '%{http_code}\n' --resolve openwebui.ghoulhub.uk:443:127.0.0.1 https://openwebui.ghoulhub.uk/
```

**Expect:** `sso` → `302` to `/flows/…`, `openwebui` → `302` to
`https://sso.ghoulhub.uk/application/o/authorize/…`. If these do not redirect, **do not
start cloudflared** — you would be publishing a broken front door to the internet.

### 9.7 Start cloudflared — LAST

```bash
sudo cp /tmp/restore/cloudflared-config.yml /etc/cloudflared/config.yml
sudo systemctl enable --now cloudflared
```

**Expect:** `systemctl is-active cloudflared` prints `active`, and
`journalctl -u cloudflared -n 20 --no-pager` shows no `ERR … Unable to reach the origin service`.

### 9.8 From an unrelated network (phone on mobile data)

Open all nine. Expect: `sso` 302, `traefik` 302, `grafana` 302 to `/login`, `openwebui` 302,
`jellyseerr` 302, `embrace` 307, `pip` 401, `jellyfin` 302 to `/web/`, `comfyui` 302.

**Expect:** every one of the nine behaves as above.

---

## 10. Phase 6 — verification against the 22 rules

| # | Rule | Check | Pass |
|---|---|---|---|
| 1 | Traefik is the sole front door | `docker exec traefik wget -qO- http://traefik:8080/api/http/routers \| head -c 50` | every router is `@docker` |
| 2 | Authentik gates every human-facing service | each of the nine returns 302/401 anonymously | ✔ |
| 3 | LAN does not bypass Authentik | `curl -k -H 'Host: openwebui.ghoulhub.uk' https://127.0.0.1/` from the LAN | 302 to sso |
| 6 | M2M uses private networks, never interactive Authentik | ollama/searxng/prometheus reachable only on loopback + Tailscale | ✔ |
| 7 | No app directly on the internet | see the note below this table — `grep -c 0.0.0.0` is **not** the right test | no non-front-door service resolves in public DNS or has a tunnel ingress rule |
| 9 | No Traefik↔Authentik deadlock | `/etc/cloudflared/config.yml` has a `https://localhost:443` rule for every hostname | ✔ |
| 11 | Minimal infrastructure | `docker network ls` | only `proxy` + `backend --internal` + per-stack bridges |
| 14 | Authentik never publicly exposed | `docker inspect authentik-server` | ports on `127.0.0.1:9000` and `${TAILSCALE_IP}:9000` only |
| 15 | Authentik break-glass works | `curl http://100.102.27.93:9000/if/flow/default-authentication-flow/` | 200 |
| 18 | Backups exist and are restorable | see §11 | ✔ |
| 19 | No secret in git | `git -C <repo> grep -nE 'cfut_\|sk-\|BEGIN PRIVATE KEY'` | 0 hits |

#### Rule 7 — how to actually test it (corrected 2026-10-08)

The original check was `docker inspect <c> | grep -c 0.0.0.0`, with a pass
condition of "only traefik 80/443, homeassistant 8123, frigate 8554/8555,
qbittorrent 6881". **That pass condition is stale.** It predates the arr-stack
compose, which deliberately publishes the nine `*arr`/utility web UIs on
`0.0.0.0` for phone-and-laptop administration. See the long comment above the
`ports:` block in `arr-stack/docker-compose.yaml`: the tunnel routes none of
them, so "LAN reachable" is the entire exposure, and each service authenticates
itself before showing data.

What rule 7 actually protects against is an app being reachable *from the
internet*. A published `0.0.0.0` port is not that on its own — reachability from
the internet is decided by DNS and by the tunnel. Test both, not the port:

```bash
# 1. nothing but the nine hostnames may resolve publicly
for h in sso traefik grafana openwebui jellyseerr embrace pip jellyfin comfyui \
         radarr sonarr lidarr prowlarr sabnzbd nzbhydra2 uptimekuma suggestarr qbittorrent; do
  printf '  %-14s dns=%s\n' "$h" "$(getent hosts "$h.ghoulhub.uk" >/dev/null && echo RESOLVES || echo none)"
done

# 2. and none of the LAN-only services may have a tunnel ingress rule
grep -cE 'radarr|sonarr|lidarr|prowlarr|sabnzbd|nzbhydra2|uptimekuma|suggestarr|qbittorrent' \
  /etc/cloudflared/config.yml     # must print 0
```

**Expect:** every DNS entry is `none` and the grep prints `0`.

Ports that must stay published, and why:

| Port | Why it cannot move behind Traefik |
|---|---|
| `traefik` 80/443 | it *is* the front door |
| `homeassistant` 8123 | bearer token, no cookie; LAN IoT devices depend on it. Not public — no DNS, no router |
| `frigate` 8554/8555 | go2rtc RTSP + WebRTC stream distribution; a TV/NVR pulling a restream needs raw LAN |
| `qbittorrentvpn` 6881 tcp+udp | inbound BitTorrent peer port; NAT traversal depends on it |

The residual exposure the `arr-stack` compose comment names is real: guests and
IoT devices on the home Wi-Fi can load those login pages. **ufw cannot close
that** — on a flat subnet it cannot tell a guest apart from your own laptop.
Closing it properly means putting guests and IoT on their own VLAN at the router.
That is the only fix, and it is out of scope for the box itself.

### Rollback triggers — power the old box back off if ANY of these hold

- `sso.ghoulhub.uk` does not return 302 within 5 minutes of starting cloudflared.
- Any app 502s after cutover.
- `pg_restore` of either dump failed — do **not** proceed with an empty database.
- The new box cannot reach the Synology over NFS. Backups are unreachable without it.

Rollback = power on ROG-Strix. Its `.49` claim means you must first shut the new box down.
Its disk already holds a complete, working estate.

---

## 11. Post-move: prove the backups moved too

```bash
cd ~/Documents/backup-stack
K() { docker exec -e KOPIA_PASSWORD="$(grep '^KOPIA_PASSWORD=' .env | cut -d= -f2-)" \
       kopia kopia "$@" --config-file=/app/config/repository.config; }
K snapshot list --all
K repository status
```

**Expect:** `/hostconfig` newest snapshot is non-empty, and `/source` has a fresh snapshot
from the new box. `repository status` shows `Hostname: kopia` and the same filesystem
repository on the NAS.

**Expect:** all three roots have snapshots, and `du -sh /mnt/synology/backup/homelab` is
roughly 178 GB or larger.

---

## 12. Post-move cleanup

```bash
# 1. Decommission the old Tailscale node (admin console) — do not just power it off.
# 2. Delete the stale Kopia snapshots that predate the migration once you are confident:
#    K snapshot delete <id> --delete        # note: takes NO source path argument
# 3. Re-point the router's DHCP reservation to the new box if it is not already.
```

Then, when you get around to it:

- `ollama pull` the models you actually use (156 GB — do it deliberately, model by model).
- Re-add `kmulvey/radeon_exporter` for GPU dashboards on the AMD box.
- Set up Frigate properly once the cameras are mounted.
- Pull ComfyUI weights and confirm whether the 890M can actually run them. If not, keep it
  CPU-only — it will be slow but honest.
- Create a remote for the parent `Documents/` repo so `bootstrap.sh` is not one-disk-only.

---

## 13. Kopia CLI traps — read before you debug a "missing" file

These cost real time during the pre-migration backup. They are not user error.

| Trap | Reality |
|---|---|
| `kopia snapshot list` (no `--all`) | shows the wrong root. Always `--all`. |
| `kopia snapshot list --json` fields | keys are `description,endTime,id,retentionReason,rootEntry,source,startTime,stats`. There is **no** `root` and **no** `size` — size and file counts live under `stats`. |
| `stats` shows `files=0` / `NoneB` | usually means statistics were never computed, **not** an empty snapshot. Confirm with `kopia snapshot restore`. |
| `kopia show <snapID> <path>` | wrong. It takes **`<rootEntryObjectID>/<path>`** in ONE argument. The snapshot id is not the root object id. |
| stderr swallowed | a failed `kopia show` yields an empty string whose md5 is `d41d8cd98f00b204e9800998ecf8427e`. That looks like a *mismatch*; it is actually a *failure*. Check the exit code. |
| `pg_restore --list /dev/stdin` | fails with "did not find magic string in file header" because it must seek. Not a corrupt dump. `docker cp` the file into the container first. |
| `kopia snapshot restore` of a subdirectory | `restore requires a source and target`; the `<snapID>:<subdir>` form fails too. Restore everything, or use `kopia show` per object. |
| `docker compose run --rm db-backup -c '... --once'` | **silently ignores `--once`** and runs forever. Use `docker compose run --rm db-backup --once`. |

---

## 14. Verified facts about this estate

Every one of these was measured, not assumed.

- **Router:** the Sagemcom ISP gateway **refuses to return RFC1918 answers from upstream
  DNS** (proved with a controlled two-record experiment). That is why every hostname is a
  *proxied* CNAME to the tunnel rather than a DNS-only A record. Do not "simplify" this.
- **Domain:** `ghoulhub.uk`. Nine hostnames, all CNAME →
  `246b168c-7c77-47e1-9a89-d89c1fdb293f.cfargotunnel.com`, proxied.
- **The "minix" label in the Cloudflare dashboard is the tunnel's display name**, not a
  second tunnel. Cosmetic only.
- **`~/.config/opencode` = 501 MB**, almost all of it `node_modules`, which the
  `/hostconfig` policy ignores. The real payload is ~1 MB.
- **ufw is `Status: inactive`** on the old box, so there are no firewall rules to recreate.
  If you enable a firewall on the new box you are starting from zero.
- **`docker restart` does not re-read compose `environment:`.** Any change to `environment:`
  or to Traefik labels needs `docker compose up -d --force-recreate`. A label-only change is
  otherwise silently ignored and the router 404s with no error.
- **Traefik v3.7:** `forwardedHeaders` and `transport` live at `entryPoints.<name>`, not under
  `.http`. There is **no `api` node under an entryPoint** (it crash-loops). Per-provider ACME
  credential fields were removed — only the `CF_DNS_API_TOKEN` env var works.
- **Middleware order is load-bearing.** Traefik runs middlewares left to right and stops at
  the first that ends the request, so a short-circuiting one (forward-auth, basic auth) must
  come **last**, after `rate-limit` and `security-headers`.
- **A malformed Traefik label makes the provider silently drop every router on that
  container** — you get a bare 404 and no hint.
- **Authentik REST API rejects all writes with 403 CSRF** regardless of headers. Use
  blueprints. `docker restart` does not re-read compose env, so a blueprint can apply with
  `!Env` resolving empty and create nothing, with `exc: null` and nothing in any log. The
  only reliable diagnostic is
  `select name,status from authentik_blueprints_blueprintinstance`.
- **A top-level `context:` block breaks a blueprint.** Use comments or
  `metadata.labels.description`.
- **OpenWebUI cannot use native OIDC against Authentik** (authlib GETs the issuer root and
  Authentik answers a 302, so `raise_for_status()` throws). It is behind Traefik
  forward-auth with `WEBUI_AUTH_TRUSTED_EMAIL_HEADER`. **`ENABLE_OAUTH` must be explicitly
  `false`** — OpenWebUI defaults it to true, and an advertised-but-broken provider renders a
  button that 500s. Never set `ENABLE_PASSWORD_AUTH=false`.
- **Jellyfin is deliberately NOT behind forward-auth.** Native clients (Apple TV, iOS,
  Android, Roku) authenticate with an app token and send **no cookies**, so a gate would
  reject every playback request. It is Type C with its own auth, behind Traefik for TLS only.
- **Home Assistant likewise** (bearer token, no cookie) and is intentionally left on
  `0.0.0.0:8123` for LAN IoT devices. It is not public — no tunnel rule, no Traefik router.
- **The leaked OpenAI API key**: `pip-story-friend/.aider.conf.yml` held a live key and was
  tracked since the initial commit. The file is now untracked, **but the key remains in git
  history at `385203b`** and was pushed to the remote. It must be **rotated**, and purging
  the history needs `git filter-repo` plus a force-push.
- **Only akadmin has MFA.** marina and moncef have no TOTP device. That is a rule-2 gap.
