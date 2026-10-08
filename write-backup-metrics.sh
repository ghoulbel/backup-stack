#!/usr/bin/env bash
# Export Kopia snapshot freshness as Prometheus metrics via the node_exporter
# textfile collector, so "the backups silently stopped running" becomes an alert
# instead of a discovery months later.
#
# Why this exists: Kopia has no exporter. Its container can be perfectly
# healthy while the scheduled snapshot silently fails - a policy that no longer
# matches, a detached NFS mount, a full NAS. The only real signal is the age of
# the newest snapshot, and that has to be measured somewhere.
#
# Writes to monitoring-stack/textfile/, which node_exporter reads read-only.
set -euo pipefail

STACK_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="$STACK_DIR/../monitoring-stack/textfile"
mkdir -p "$OUT_DIR"

PW="$(grep '^KOPIA_PASSWORD=' .env | cut -d= -f2-)"
CFG=/app/config/repository.config

# Newest snapshot end time per source, in unix seconds.
snapshot_age() {
    local src=$1
    docker exec -e KOPIA_PASSWORD="$PW" kopia kopia snapshot list "$src" --all --json \
        --config-file="$CFG" 2>/dev/null |
    python3 -c '
import sys, json, datetime
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if not d:
    sys.exit(0)
newest = max(s["endTime"] for s in d)
print(int(datetime.datetime.fromisoformat(
    newest.replace("Z", "+00:00")).timestamp()))
'
}

{
    echo '# HELP kopia_snapshot_age_seconds Age of the newest snapshot per source.'
    echo '# TYPE kopia_snapshot_age_seconds gauge'
    for src in /source /hostconfig /source/arr-stack/config; do
        ts=$(snapshot_age "$src" || true)
        [ -n "$ts" ] || continue
        now=$(date +%s)
        slug=$(printf '%s' "$src" | tr '/' '_' | sed 's/^_//;s/_$//')
        echo "kopia_snapshot_age_seconds{source=\"$src\"} $((now - ts))"
    done

    # The tunnel is the only route to the internet. Its failure mode is
    # Cloudflare 1033, which nothing else in the estate can detect: Traefik,
    # Authentik and every app stay perfectly healthy behind a dead tunnel.
    echo '# HELP cloudflared_active 1 if the cloudflared service is active.'
    echo '# TYPE cloudflared_active gauge'
    if systemctl is-active --quiet cloudflared; then
        echo 'cloudflared_active 1'
    else
        echo 'cloudflared_active 0'
    fi

    echo '# HELP cloudflared_connections Registered tunnel connections.'
    echo '# TYPE cloudflared_connections gauge'
    n=$(journalctl -u cloudflared --no-pager 2>/dev/null |
        grep -c 'Registered tunnel connection' || true)
    echo "cloudflared_connections ${n:-0}"
} > "$OUT_DIR/kopia.prom.$$"

mv "$OUT_DIR/kopia.prom.$$" "$OUT_DIR/kopia.prom"
