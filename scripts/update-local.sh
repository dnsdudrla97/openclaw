#!/usr/bin/env bash
# Local update helper for source installs / fork workflows.
#
# This script follows the "Updating" runbook (docs/install/updating.md) but keeps
# everything local and explicit (no curl | bash by default).
#
# Default behavior:
# - Backup ~/.openclaw/openclaw.json (use --backup-all to include credentials/workspace)
# - Fetch + merge upstream/main into the current branch (use --remote/--branch to change)
# - pnpm install
# - pnpm build
# - Run `node openclaw.mjs doctor`
#
# Optional:
# - Restart gateway + run health checks.
#
# Examples:
#   ./scripts/update-local.sh
#   ./scripts/update-local.sh --remote upstream --branch main
#   ./scripts/update-local.sh --no-git --skip-install --build fast
#   ./scripts/update-local.sh --restart-gateway --health

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

log()  { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: update-local.sh [options]

Options:
  --remote <name>           Git remote to pull from (default: upstream if present, else origin)
  --branch <name>           Remote branch to pull (default: main)
  --strategy <merge|rebase|ff-only>
                            How to reconcile divergent branches (default: merge)
  --allow-dirty             Allow running with a dirty git worktree (default: abort if dirty)
  --no-git                  Skip git fetch/pull (build-only)

  --[no-]backup             Backup ~/.openclaw/openclaw.json (default: --backup)
  --backup-all              Also backup ~/.openclaw/credentials and ~/.openclaw/workspace
  --backup-dir <path>       Backup destination (default: ~/.openclaw/backups/openclaw-update-<timestamp>)

  --[no-]install            Run pnpm install (default: --install)
  --build <full|fast|none>  Build mode (default: full)
  --[no-]doctor             Run `node openclaw.mjs doctor` after build (default: --doctor)
  --restart-gateway          Run `node openclaw.mjs gateway restart` after doctor
  --health                  Run `node openclaw.mjs health` at the end

  -h, --help                Show help

Notes:
  - This script does NOT push to your fork. After merging upstream, push manually if desired.
  - For global installs (npm/pnpm -g), use the website installer or `openclaw update` instead.
EOF
}

REMOTE=""
BRANCH="main"
STRATEGY="merge"
ALLOW_DIRTY=0
DO_GIT=1

DO_BACKUP=1
BACKUP_ALL=0
BACKUP_DIR=""

DO_INSTALL=1
BUILD_MODE="full"
DO_DOCTOR=1
DO_RESTART_GATEWAY=0
DO_HEALTH=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote) REMOTE="${2:-}"; shift 2 ;;
    --branch) BRANCH="${2:-}"; shift 2 ;;
    --strategy) STRATEGY="${2:-}"; shift 2 ;;
    --allow-dirty) ALLOW_DIRTY=1; shift ;;
    --no-git) DO_GIT=0; shift ;;

    --backup) DO_BACKUP=1; shift ;;
    --no-backup) DO_BACKUP=0; shift ;;
    --backup-all) BACKUP_ALL=1; shift ;;
    --backup-dir) BACKUP_DIR="${2:-}"; shift 2 ;;

    --install) DO_INSTALL=1; shift ;;
    --no-install|--skip-install) DO_INSTALL=0; shift ;;
    --build) BUILD_MODE="${2:-}"; shift 2 ;;
    --doctor) DO_DOCTOR=1; shift ;;
    --no-doctor) DO_DOCTOR=0; shift ;;
    --restart-gateway) DO_RESTART_GATEWAY=1; shift ;;
    --health) DO_HEALTH=1; shift ;;

    -h|--help) usage; exit 0 ;;
    *)
      fail "Unknown arg: $1 (use --help)"
      ;;
  esac
done

case "${STRATEGY}" in
  merge|rebase|ff-only) ;;
  *) fail "Invalid --strategy: ${STRATEGY} (expected merge|rebase|ff-only)" ;;
esac

case "${BUILD_MODE}" in
  full|fast|none) ;;
  *) fail "Invalid --build: ${BUILD_MODE} (expected full|fast|none)" ;;
esac

if ! command -v pnpm >/dev/null 2>&1; then
  fail "pnpm not found in PATH"
fi

export PATH="${ROOT_DIR}/node_modules/.bin:${PATH}"

copy_path() {
  local src="$1"
  local dst="$2"
  if [[ ! -e "${src}" ]]; then
    return 0
  fi
  mkdir -p "$(dirname "${dst}")"
  if command -v ditto >/dev/null 2>&1; then
    ditto "${src}" "${dst}"
  else
    cp -R "${src}" "${dst}"
  fi
}

maybe_backup() {
  if [[ "${DO_BACKUP}" -ne 1 ]]; then
    return 0
  fi

  local openclaw_home="${HOME}/.openclaw"
  if [[ -z "${BACKUP_DIR}" ]]; then
    local ts
    ts="$(date +"%Y%m%d-%H%M%S")"
    BACKUP_DIR="${openclaw_home}/backups/openclaw-update-${ts}"
  fi

  log "==> Backup: ${BACKUP_DIR}"
  mkdir -p "${BACKUP_DIR}"

  copy_path "${openclaw_home}/openclaw.json" "${BACKUP_DIR}/openclaw.json"
  copy_path "${openclaw_home}/openclaw.json.bak" "${BACKUP_DIR}/openclaw.json.bak"

  if [[ "${BACKUP_ALL}" -eq 1 ]]; then
    copy_path "${openclaw_home}/credentials" "${BACKUP_DIR}/credentials"
    copy_path "${openclaw_home}/workspace" "${BACKUP_DIR}/workspace"
  fi
}

maybe_git_update() {
  if [[ "${DO_GIT}" -ne 1 ]]; then
    log "==> Git: skipped (--no-git)"
    return 0
  fi

  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    fail "Not a git repository: ${ROOT_DIR}"
  fi

  if [[ -z "${REMOTE}" ]]; then
    if git remote get-url upstream >/dev/null 2>&1; then
      REMOTE="upstream"
    else
      REMOTE="origin"
    fi
  fi

  if [[ "${ALLOW_DIRTY}" -ne 1 ]]; then
    if [[ -n "$(git status --porcelain)" ]]; then
      fail "Dirty git worktree. Commit/stash your changes or re-run with --allow-dirty."
    fi
  fi

  log "==> Git fetch: ${REMOTE}"
  git fetch --tags "${REMOTE}"

  log "==> Git pull (${STRATEGY}): ${REMOTE}/${BRANCH}"
  case "${STRATEGY}" in
    merge)
      git pull --tags --no-rebase "${REMOTE}" "${BRANCH}"
      ;;
    rebase)
      git pull --tags --rebase "${REMOTE}" "${BRANCH}"
      ;;
    ff-only)
      git pull --tags --ff-only "${REMOTE}" "${BRANCH}"
      ;;
  esac
}

maybe_install() {
  if [[ "${DO_INSTALL}" -ne 1 ]]; then
    log "==> pnpm install: skipped (--no-install)"
    return 0
  fi
  log "==> pnpm install"
  pnpm install
}

maybe_build() {
  case "${BUILD_MODE}" in
    none)
      log "==> Build: skipped (--build none)"
      return 0
      ;;
    fast)
      log "==> Build (fast): tsdown"
      pnpm -s exec tsdown
      return 0
      ;;
    full)
      log "==> Build (full): pnpm build"
      pnpm build
      return 0
      ;;
  esac
}

maybe_doctor() {
  if [[ "${DO_DOCTOR}" -ne 1 ]]; then
    log "==> Doctor: skipped (--no-doctor)"
    return 0
  fi
  log "==> Doctor"
  node openclaw.mjs doctor
}

maybe_restart_gateway() {
  if [[ "${DO_RESTART_GATEWAY}" -ne 1 ]]; then
    return 0
  fi
  log "==> Gateway restart"
  node openclaw.mjs gateway restart
}

maybe_health() {
  if [[ "${DO_HEALTH}" -ne 1 ]]; then
    return 0
  fi
  log "==> Health"
  node openclaw.mjs health
}

maybe_backup
maybe_git_update
maybe_install
maybe_build
maybe_doctor
maybe_restart_gateway
maybe_health

log "==> Done"
