#!/usr/bin/env bash
# Creates the Kopia repository and policies. Safe to re-run: it skips
# creation when the repository already exists and only (re)applies policies.
set -euo pipefail

cd "$(dirname "$0")"
# shellcheck disable=SC1091
set -a; . ./.env; set +a

: "${KOPIA_PASSWORD:?KOPIA_PASSWORD missing from .env}"
REPO_PATH=/backup

kopia_cmd=(docker compose run --rm -T kopia)

repo_exists() {
  "${kopia_cmd[@]}" repository connect filesystem \
    --path "$REPO_PATH" --password "$KOPIA_PASSWORD" >/dev/null 2>&1
}

if repo_exists; then
  echo "==> Repository already present at $REPO_PATH, reusing it."
else
  echo "==> Creating filesystem repository at $REPO_PATH"
  "${kopia_cmd[@]}" repository create filesystem \
    --path "$REPO_PATH" \
    --password "$KOPIA_PASSWORD" \
    --cache-directory /app/cache
fi

# Retention is time-tiered rather than a single weekly count: configs change
# often and are small, so a week of history costs almost nothing, while a
# month-old copy still matters if a bad change went unnoticed.
echo "==> Applying global defaults"
"${kopia_cmd[@]}" policy set --global \
  --keep-latest 20 \
  --keep-hourly 0 \
  --keep-daily 14 \
  --keep-weekly 8 \
  --keep-monthly 12 \
  --keep-annual 3 \
  --compression zstd \
  --one-file-system=true \
  --ignore-dir-errors=true \
  --ignore-file-errors=true \
  --ignore-identical-snapshots=true

# Tier 1: code + configuration. Small, changes often, backed up daily.
# NOTE: --add-ignore only appends, so stale rules would survive re-runs and
# silently win over the list below. Clear first, then add.
echo "==> Policy: config (daily)"
"${kopia_cmd[@]}" policy set /source --clear-ignore
"${kopia_cmd[@]}" policy set /source \
  --snapshot-time-crontab "17 3 * * *" \
  --add-ignore "ai-stack/data/ollama/models/" \
  --add-ignore "ai-stack/data/ollama/cache/" \
  --add-ignore "ai-stack/data/tts/" \
  --add-ignore "ai-stack/data/qdrant/" \
  --add-ignore "ai-stack/data/comfyui/models/" \
  --add-ignore "ai-stack/data/comfyui/custom_nodes/" \
  --add-ignore "ai-stack/data/comfyui/output/" \
  --add-ignore "ai-stack/data/webui/cache/" \
  --add-ignore "ai-stack/data/webui/vector_db/" \
  --add-ignore "ai-stack/data/webui/webui.db.before-model-cleanup" \
  --add-ignore "ai-stack/crawl4ai-docs/.venv/" \
  --add-ignore "arr-stack/downloads/" \
  --add-ignore "arr-stack/cache/" \
  --add-ignore "arr-stack/config/" \
  --add-ignore "monitoring-stack/prometheus_data/" \
  --add-ignore "monitoring-stack/loki_data/" \
  --add-ignore "monitoring-stack/grafana_data/" \
  --add-ignore "monitoring-stack/alloy_data/" \
  --add-ignore "monitoring-stack/homeassistant/config/.storage/" \
  --add-ignore "monitoring-stack/homeassistant/config/deps/" \
  --add-ignore "monitoring-stack/homeassistant/config/tts/" \
  --add-ignore "monitoring-stack/homeassistant/config/.cache/" \
  --add-ignore "ai-project/intimacy-connection/data/" \
  --add-ignore "*/node_modules/" \
  --add-ignore "*/.venv/" \
  --add-ignore "*/venv/" \
  --add-ignore "*/__pycache__/" \
  --add-ignore "*/.git/objects/pack/tmp_*" \
  --add-ignore "backup-stack/kopia/"

# The Authentik Postgres data directory is deliberately NOT snapshotted.
#
# Copying a live database directory is not a backup: Postgres is appending to its
# WAL and rewriting pages while Kopia reads them, so the copy can capture a torn
# page and fail recovery on restore — and it looks perfectly valid right up until
# the day you need it. identity-stack/db-backup-loop.sh takes a real consistent
# snapshot with pg_dump instead, writing to identity-stack/backups/, which this
# policy DOES copy.
#
# The same reasoning applies to the embrace (intimacy-connection) Postgres: it is
# covered by the weekly arr-style policy above for its config, and its live data
# directory is ignored here too.
echo "==> Adding live-database exclusions"
"${kopia_cmd[@]}" policy set /source \
  --add-ignore "identity-stack/data/postgres/" \
  --add-ignore "identity-stack/data/authentik/" \
  --add-ignore "identity-stack/data/media/" \
  --add-ignore "identity-stack/data/certs/"

# Tier 2: *arr application state. Databases change constantly, so these get a
# weekly schedule instead of daily to keep write volume on the NAS sane.
echo "==> Policy: arr app state (weekly)"
"${kopia_cmd[@]}" policy set /source/arr-stack/config --clear-ignore
"${kopia_cmd[@]}" policy set /source/arr-stack/config \
  --snapshot-time-crontab "41 4 * * 0" \
  --add-ignore "*/cache/" \
  --add-ignore "*/logs/" \
  --add-ignore "*/log/" \
  --add-ignore "*/Log/" \
  --add-ignore "*/logs.*" \
  --add-ignore "*/MediaCover/" \
  --add-ignore "*/Sentry/" \
  --add-ignore "*/Backups/" \
  --add-ignore "*/restore/" \
  --add-ignore "*/supervisord.log*" \
  --add-ignore "*/transcodes/" \
  --add-ignore "jellyfin/data/metadata/" \
  --add-ignore "jellyfin/data/data/jellyfin.db*" \
  --add-ignore "nzbhydra2/backup/" \
  --add-ignore "nzbhydra2/logs/"

# llama-cpp-lab is a PLAYGROUND, not homelab state, so the whole directory is
# excluded. It held 177 GB of GGUF weights under models/ plus 35 GB of other
# scratch, and nothing in it was ever in any ignore rule -- which is why the
# nightly Tier-1 snapshot jumped from 1.6 GB (Oct 3) to 212 GB (Oct 4).
#
# This is safe because llama-cpp-lab is its own git repo with a remote
# (git@github.com:ghoulbel/llama-cpp-lab.git, branch main) and nothing is
# unpushed, so the code survives without Kopia. Two things are NOT recoverable
# from that: its local .env (never committed), and any untracked benchmark
# results under benchmarks/results/. If either starts to matter, give the repo
# a .gitignore for .env and commit the results you care about.
echo "==> Policy: exclude the llama-cpp-lab playground entirely"
"${kopia_cmd[@]}" policy set /source \
  --add-ignore "llama-cpp-lab/"

# Tier 3: host-local configuration (/hostconfig).
#
# Everything above is inside Documents/ and therefore in git. /hostconfig is
# the handful of files that live in your HOME directory and are in no repo at
# all -- and every one of them is unrecoverable if this box dies:
#
#   cloudflared/246b168c-*.json  the TunnelSecret. There is no API to read it
#                                back and no way to re-create it. The only
#                                alternative is a brand new tunnel, which means
#                                deleting and hand-recreating all nine DNS
#                                records.
#   ssh/id_ed25519               the key that pushes all nine repos.
#   secrets/                     editor API keys.
#   opencode/                    which provider/model the editor runs on.
#   hostconfig-fstab             the Synology NFS mount options.
#   hostconfig-etc/              the cloudflared systemd unit.
#
# Weekly is plenty: these change a few times a year, not a day.
echo "==> Policy: host config (weekly)"
if "${kopia_cmd[@]}" snapshot list /hostconfig >/dev/null 2>&1 \
   || "${kopia_cmd[@]}" policy list 2>/dev/null | grep -q 'root@kopia:/hostconfig'; then
  echo "    source already exists, refreshing policy"
else
  echo "    creating source /hostconfig"
fi
"${kopia_cmd[@]}" policy set /hostconfig --clear-ignore
# --one-file-system=false is MANDATORY here and is NOT the default. /hostconfig
# is a plain directory on the container's own overlay filesystem (st_dev 67)
# holding SIX separate bind mounts inside it, all on a different device
# (st_dev 66306). With oneFileSystem left at its default true, kopia refuses to
# descend into a mount point on another device, so it scanned nothing at all:
# two snapshots were created that reported files=0 dirs=1 size=0 while `find
# /hostconfig -type f` counted 10217 files. --source does not hit this because
# its snapshot root IS the bind mount, so everything beneath shares its st_dev.
"${kopia_cmd[@]}" policy set /hostconfig \
  --one-file-system=false \
  --add-ignore "opencode/node_modules/**" \
  --add-ignore "opencode/cache/**" \
  --add-ignore "opencode/log/**" \
  --add-ignore "opencode/tools/**" \
  --add-ignore "opencode/global-index/**" \
  --add-ignore "**/*.log" \
  --add-ignore "**/.DS_Store" \
  --snapshot-time-crontab "0 5 * * 0" \
  --keep-latest 3 \
  --keep-daily 7 \
  --keep-weekly 8 \
  --keep-monthly 12 \
  --keep-annual 3

echo "==> Policies:"
"${kopia_cmd[@]}" policy list
echo "==> Done. Start the stack with: docker compose up -d"