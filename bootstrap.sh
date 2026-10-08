#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# bootstrap.sh — host-level prerequisites for the whole homelab
#
# Creates the two external Docker networks that every stack joins, verifies
# the host can actually support the architecture, and publishes the discovered
# Tailscale address into the stacks that need it.
#
# Safe to re-run: existing networks are reused untouched, and .env values are
# rewritten only when they actually differ.
#
# The Tailscale address is discovered rather than hardcoded on purpose. This
# host is expected to be replaced, and a new server is handed a different
# 100.x address — a stale literal would silently break the Authentik recovery
# listener, which is the break-glass path of last resort.
#
# Usage:  ./bootstrap.sh [--check]
#           --check   verify only, change nothing
# ---------------------------------------------------------------------------
set -euo pipefail

cd "$(dirname "$0")"

CHECK_ONLY=false
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=true

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
ok()   { printf '  ok  %s\n' "$*"; }

# network_exists <name>
network_exists() { docker network inspect "$1" >/dev/null 2>&1; }

# set_env_value <file> <KEY> <VALUE>
# Idempotently sets KEY=VALUE, appending the key if absent. Keeps any other
# lines (and their ordering) untouched so hand-edited .env files survive.
set_env_value() {
  local file=$1 key=$2 value=$3
  if grep -qE "^${key}=" "$file" 2>/dev/null; then
    local current
    current=$(grep -m1 -E "^${key}=" "$file" | cut -d= -f2-)
    [[ "$current" == "$value" ]] && return 0
    # Value is quoted in .env files; compare after stripping quotes.
    local bare=${current#\"}; bare=${bare%\"}
    [[ "$bare" == "$value" ]] && return 0
    sed -i "s|^${key}=.*|${key}=${value}|" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >>"$file"
  fi
}

# ---------------------------------------------------------------------------
# 1. Prerequisites
# ---------------------------------------------------------------------------
info "Checking prerequisites"
command -v docker >/dev/null 2>&1 || die "docker is not installed"
docker info >/dev/null 2>&1 || die "cannot reach the docker daemon (add yourself to the 'docker' group)"
ok "docker $(docker version --format '{{.Server.Version}}')"

docker compose version >/dev/null 2>&1 || die "docker compose v2 is required"
ok "compose $(docker compose version --short 2>/dev/null || echo v2)"

if command -v tailscale >/dev/null 2>&1; then
  TS_STATE=$(tailscale status --json 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["BackendState"])' 2>/dev/null || echo Unknown)
  if [[ "$TS_STATE" == "Running" ]]; then
    ok "tailscale ($TS_STATE)"
  else
    warn "tailscale installed but state is '$TS_STATE' — the recovery path needs it running"
  fi
else
  die "tailscale is not installed. Without it there is no break-glass path."
fi

# Ports 80/443 belong to Traefik alone. Anything else squatting on them will
# make the front door fail to bind later, which is confusing to debug then.
for port in 80 443; do
  if ss -tlnH "sport = :$port" 2>/dev/null | grep -q .; then
    warn "port $port is already in use by: $(ss -tlnHp "sport = :$port" 2>/dev/null | grep -oP 'users:\(\("\K[^"]+' | sort -u | tr '\n' ' ')"
  else
    ok "port $port free"
  fi
done

# ---------------------------------------------------------------------------
# 2. External networks
# ---------------------------------------------------------------------------
# proxy   carries human-facing traffic between Traefik and the apps.
# backend is --internal: no route off the host at all. Databases and caches
#         live here so nothing but their own stack can reach them.
info "Ensuring Docker networks"
for spec in "proxy:" "backend:--internal"; do
  net=${spec%%:*}
  flag=${spec#*:}
  if network_exists "$net"; then
    actual=$(docker network inspect "$net" --format '{{.Internal}}')
    if [[ -n "$flag" && "$actual" != "true" ]]; then
      die "network '$net' exists but is not --internal. Recreate it: docker network rm $net && docker network create $flag $net"
    fi
    ok "$net exists (internal=$actual)"
  elif $CHECK_ONLY; then
    warn "$net missing"
  else
    docker network create $flag "$net" >/dev/null
    ok "$net created$( [[ -n "$flag" ]] && echo ' (internal)' )"
  fi
done

# ---------------------------------------------------------------------------
# 3. Tailscale address
# ---------------------------------------------------------------------------
# Read once, used for the Authentik recovery listener. Deliberately NOT
# published through Traefik: routing the IdP through the proxy that depends on
# it is how you lock yourself out of your own IdP.
TS_IP=$(tailscale ip -4 2>/dev/null || true)
if [[ -z "$TS_IP" ]]; then
  die "no Tailscale IPv4 address. Authentik cannot expose its recovery listener."
fi
TS_DNS=$(tailscale status --json 2>/dev/null \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))' 2>/dev/null || echo "")

# Push into every stack that publishes on it.
#
# Two different consumers, same variable:
#   identity-stack  the Authentik recovery listener (never via Traefik —
#                   routing the IdP through the proxy that depends on it is
#                   how you lock yourself out of your own IdP).
#   ai-stack /      admin UIs and machine-to-machine services that must stay
#   arr-stack /      reachable from anywhere on the tailnet without being
#   monitoring-stack exposed to the whole LAN. Compose cannot read across
#                   stack directories, so each one carries its own copy.
if $CHECK_ONLY; then
  warn "would publish TAILSCALE_IP=$TS_IP into the stack .env files"
else
  published=()
  for dir in identity-stack ai-stack arr-stack monitoring-stack; do
    [[ -d $dir ]] || continue
    env_file="$dir/.env"
    if [[ ! -f $env_file ]]; then
      [[ -f $dir/.env.example ]] && cp "$dir/.env.example" "$env_file"
      [[ -f $env_file ]] || continue
      chmod 600 "$env_file"
    fi
    set_env_value "$env_file" "TAILSCALE_IP" "$TS_IP"
    set_env_value "$env_file" "TAILSCALE_DNS" "$TS_DNS"
    published+=("$dir/.env")
  done
  if ((${#published[@]})); then
    ok "published TAILSCALE_IP=$TS_IP to: ${published[*]}"
  else
    ok "Tailscale address $TS_IP (no stack .env to publish to yet)"
  fi
fi

# ---------------------------------------------------------------------------
# 3b. GPU render group
# ---------------------------------------------------------------------------
# Published so containerised GPU consumers can be granted access to /dev/dri
# without anyone hard-coding a group id.
#
# The number is HOST-SPECIFIC and has already bitten us once: 993 was `render`
# on the old MiniX, but on ROG-Strix 993 is `sgx` and render is 990. A compose
# file that hard-codes 993 there does not error -- the container simply cannot
# open the render node and VAAPI transcoding silently degrades to CPU. So the
# gid is resolved here, once, from the live host, and written into the stacks.
#
# Consumers:
#   arr-stack (amd branch)   jellyfin via /dev/dri/renderD128 for VAAPI
#   ai-stack  (amd branch)   ollama and comfyui via /dev/dri + /dev/kfd
# Unused on the main (NVIDIA) branch, so publishing it everywhere is harmless.
render_gid=$(getent group render 2>/dev/null | cut -d: -f3 || true)
video_gid=$(getent group video 2>/dev/null | cut -d: -f3 || true)

if [[ -z $render_gid ]]; then
  warn "no 'render' group on this host -- skipping RENDER_GID publish."
  warn "  Needed only for AMD/VAAPI. On NVIDIA it is simply unused."
elif $CHECK_ONLY; then
  warn "would publish RENDER_GID=$render_gid VIDEO_GID=${video_gid:-<none>} into stack .env files"
else
  gid_published=()
  for dir in ai-stack arr-stack monitoring-stack; do
    [[ -d $dir ]] || continue
    env_file="$dir/.env"
    [[ -f $env_file ]] || continue
    set_env_value "$env_file" "RENDER_GID" "$render_gid"
    [[ -n $video_gid ]] && set_env_value "$env_file" "VIDEO_GID" "$video_gid"
    gid_published+=("$dir/.env")
  done
  if ((${#gid_published[@]})); then
    ok "published RENDER_GID=$render_gid VIDEO_GID=${video_gid:-<none>} to: ${gid_published[*]}"
  else
    ok "render group is gid $render_gid (no stack .env to publish to yet)"
  fi
fi

# ---------------------------------------------------------------------------
# 4. Summary
# ---------------------------------------------------------------------------
printf '\n'
if $CHECK_ONLY; then
  info "Check complete. Nothing was changed."
else
  info "Bootstrap complete."
fi
cat <<EOF
  Tailscale IP   ${TS_IP}
  Tailscale DNS  ${TS_DNS:-<unavailable>}
  Render GID     ${render_gid:-<none>}
  Networks       proxy (routable), backend (internal, no egress)

  Next: build identity-stack, then proxy-stack. Start each with:
    ./bootstrap.sh --check && cd <stack> && docker compose up -d
EOF