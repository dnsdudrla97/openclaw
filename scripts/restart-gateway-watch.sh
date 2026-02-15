#!/usr/bin/env bash
# Dev helper: rebuild + restart the local gateway whenever source changes.
#
# This wraps the repo-local watcher (tsdown --watch + node --watch) so you can
# keep a gateway running against your current checkout without manual restarts.
#
# Usage:
#   ./scripts/restart-gateway-watch.sh
#   ./scripts/restart-gateway-watch.sh --port 1337 --bind loopback
#   OPENCLAW_GATEWAY_PORT=1337 OPENCLAW_GATEWAY_BIND=loopback ./scripts/restart-gateway-watch.sh
#
# Notes:
# - The watcher runs in the foreground. Stop with Ctrl+C.
# - By default, it uses --force to free the target port.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PORT="${OPENCLAW_GATEWAY_PORT:-1337}"
BIND="${OPENCLAW_GATEWAY_BIND:-loopback}"
FORCE=1

EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)
      PORT="${2:-}"
      shift 2
      ;;
    --bind)
      BIND="${2:-}"
      shift 2
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --no-force)
      FORCE=0
      shift
      ;;
    --help|-h)
      cat <<'EOF'
Usage: restart-gateway-watch.sh [--port <port>] [--bind <mode>] [--[no-]force] [-- <extra gateway args...>]

Runs a gateway from this checkout with watch mode enabled (auto rebuild + restart).

Options:
  --port <port>          Gateway port (default: $OPENCLAW_GATEWAY_PORT or 1337)
  --bind <mode>          loopback|lan|tailnet|auto|custom (default: $OPENCLAW_GATEWAY_BIND or loopback)
  --force / --no-force   Kill existing listeners on the port before starting (default: --force)
  -- <args...>           Pass-through args to `openclaw gateway ...`

Examples:
  ./scripts/restart-gateway-watch.sh
  ./scripts/restart-gateway-watch.sh --port 1337 --bind loopback -- --ws-log full
EOF
      exit 0
      ;;
    --)
      shift
      EXTRA_ARGS+=("$@")
      break
      ;;
    *)
      EXTRA_ARGS+=("$1")
      shift
      ;;
  esac
done

if [[ -z "${PORT}" ]]; then
  echo "ERROR: missing --port value" >&2
  exit 2
fi

ARGS=(gateway --bind "${BIND}" --port "${PORT}")
if [[ "${FORCE}" -eq 1 ]]; then
  ARGS+=(--force)
fi
if ((${#EXTRA_ARGS[@]} > 0)); then
  ARGS+=("${EXTRA_ARGS[@]}")
fi

exec node scripts/watch-node.mjs "${ARGS[@]}"
