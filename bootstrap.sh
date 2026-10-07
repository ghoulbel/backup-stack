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

# llama-cpp-lab holds 177 GB of GGUF model weights that were never added to any
# ignore rule. They are re-downloadable from HuggingFace at any time, so every
# nightly snapshot was re-uploading them: the daily Tier-1 snapshot grew from
# 1.6 GB (Oct 3) to 212 GB (Oct 4) purely because of this. Model weights are not
# state -- losing them costs bandwidth, not data.
echo "==> Policy: llama model weights (177 GB, re-downloadable)"
"${kopia_cmd[@]}" policy set /source \
  --add-ignore "llama-cpp-lab/models/"

echo "==> Policies:"
"${kopia_cmd[@]}" policy list
echo "==> Done. Start the stack with: docker compose up -d"