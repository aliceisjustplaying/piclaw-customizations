#!/usr/bin/env bash

set -euo pipefail

REPO_URL="https://github.com/rcarmo/piclaw.git"
SOURCE_DIR="/tmp/piclaw-source"
PACK_DIR="/tmp/piclaw-pack"
PATCH_DIR="/workspace/patches"

DRY_RUN=0
FORCE=0
NO_RESTART=0

PICLAW_VERSION_BEFORE=""
PICLAW_VERSION_AFTER=""
PICLAW_COMMIT_AFTER=""
PICLAW_REPORT_LINE=""

CODEX_VERSION_BEFORE=""
CODEX_VERSION_AFTER=""
CODEX_REPORT_LINE=""

CLAUDE_VERSION_BEFORE=""
CLAUDE_VERSION_AFTER=""
CLAUDE_REPORT_LINE=""

PI_AGENT_VERSION_BEFORE=""
PI_AGENT_VERSION_AFTER=""
PI_AGENT_REPORT_LINE=""

status() {
  printf '[piclaw-update] %s\n' "$*"
}

error() {
  printf '[piclaw-update] ERROR: %s\n' "$*" >&2
}

usage() {
  cat <<'EOF'
Usage: piclaw-update.sh [--dry-run] [--force] [--no-restart]

Options:
  --dry-run     Clone or pull the source, compare versions, and exit.
  --force       Skip the version comparison and proceed with install.
  --no-restart  Do everything except restart (caller handles restart).
  -h, --help    Show this help text.
EOF
}

cleanup() {
  local exit_code=$?

  if [ -e "${SOURCE_DIR}" ]; then
    rm -rf "${SOURCE_DIR}"
  fi

  if [ -e "${PACK_DIR}" ]; then
    rm -rf "${PACK_DIR}"
  fi

  exit "${exit_code}"
}

trap cleanup EXIT

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      ;;
    --force)
      FORCE=1
      ;;
    --no-restart)
      NO_RESTART=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      error "Unknown argument: $1"
      usage >&2
      exit 1
      ;;
  esac
  shift
done

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    error "Required command not found: $1"
    exit 1
  fi
}

resolve_bun_install() {
  # BUN_INSTALL is the root that contains bin/ and install/global/
  # Prefer the env var, then ~/.bun (standard self-install location),
  # then resolve from the binary (fails if bun is in a read-only store like Nix).
  if [ -n "${BUN_INSTALL:-}" ] && [ -d "${BUN_INSTALL}" ]; then
    printf '%s\n' "${BUN_INSTALL}"
    return
  fi

  if [ -d "${HOME}/.bun" ]; then
    printf '%s\n' "${HOME}/.bun"
    return
  fi

  local bun_path
  bun_path="$(readlink -f "$(command -v bun)")"
  dirname "$(dirname "${bun_path}")"
}

resolve_global_dir() {
  echo "$(resolve_bun_install)/install/global"
}

get_installed_version() {
  if ! command -v piclaw >/dev/null 2>&1; then
    printf 'unknown\n'
    return 0
  fi

  piclaw --version 2>/dev/null || printf 'unknown\n'
}

get_source_version() {
  git -C "${SOURCE_DIR}" describe --always --dirty --tags
}

get_source_commit() {
  git -C "${SOURCE_DIR}" rev-parse HEAD
}

get_codex_version() {
  codex --version 2>/dev/null || echo "not installed"
}

get_claude_version() {
  claude --version 2>/dev/null | head -1 || echo "not installed"
}

get_pi_agent_version() {
  if command -v pi >/dev/null 2>&1; then
    pi --version 2>/dev/null || echo "unknown"
  else
    echo "not installed"
  fi
}

update_report_line() {
  local name before after
  name="$1"
  before="$2"
  after="$3"

  if [ "${before}" != "${after}" ]; then
    printf 'Updated %s from %s to %s' "${name}" "${before}" "${after}"
  elif [ "${after}" = "not installed" ]; then
    printf '%s not installed' "${name}"
  else
    printf '%s already up-to-date (%s)' "${name}" "${after}"
  fi
}

refresh_source_checkout() {
  status "Refreshing source checkout in ${SOURCE_DIR}"

  if [ -e "${SOURCE_DIR}" ] && [ ! -d "${SOURCE_DIR}/.git" ]; then
    status "Removing non-git directory at ${SOURCE_DIR}"
    rm -rf "${SOURCE_DIR}"
  fi

  if [ -d "${SOURCE_DIR}/.git" ]; then
    git -C "${SOURCE_DIR}" fetch --prune origin
    git -C "${SOURCE_DIR}" reset --hard origin/HEAD
  else
    rm -rf "${SOURCE_DIR}"
    git clone "${REPO_URL}" "${SOURCE_DIR}"
  fi
}

compare_versions_or_exit() {
  local installed_version source_version
  installed_version="$(get_installed_version)"
  source_version="$(get_source_version)"

  PICLAW_VERSION_BEFORE="${installed_version}"

  status "Installed version: ${installed_version}"
  status "Source version: ${source_version}"

  if [ "${DRY_RUN}" -eq 1 ]; then
    status "Dry run requested; exiting after version comparison"
    exit 0
  fi

  if [ "${FORCE}" -eq 1 ]; then
    status "Force requested; skipping version equality check"
    return 0
  fi

  if [ "${installed_version}" = "${source_version}" ]; then
    printf 'Already up to date\n'
    exit 0
  fi
}

apply_source_patches() {
  local p

  status "Applying source patches from ${PATCH_DIR}"
  cd "${SOURCE_DIR}"

  for p in "${PATCH_DIR}"/[0-9]*.patch; do
    [ -f "${p}" ] || continue
    status "Applying patch $(basename "${p}")"
    if ! sed 's/\.orig\t/\t/g; s/\.bak\t/\t/g' "${p}" | patch -p0; then
      error "Failed to apply patch $(basename "${p}")"
      exit 1
    fi
  done
}

build_from_source() {
  status "Building PiClaw from source"
  cd "${SOURCE_DIR}"
  bun install --ignore-scripts
  bun run build
  bun run build:web

  status "Removing browser sourcemaps"
  find runtime/web/static/dist -type f -name '*.map' -delete

  status "Packing build artifacts"
  rm -rf "${PACK_DIR}"
  mkdir -p "${PACK_DIR}"
  rm -f piclaw-*.tgz
  bun pm pack
  mv piclaw-*.tgz "${PACK_DIR}/" 2>/dev/null || true
}

find_tarball() {
  local tarball
  tarball="$(find "${PACK_DIR}" -maxdepth 1 -type f -name '*.tgz' 2>/dev/null | head -n 1)"
  if [ -z "${tarball}" ] || [ ! -f "${tarball}" ]; then
    error "No tarball produced in ${PACK_DIR}"
    exit 1
  fi
  printf '%s\n' "${tarball}"
}

write_global_package_manifest() {
  local piclaw_root agent_version tarball global_package_json

  piclaw_root="$(resolve_global_dir)"
  agent_version="$(jq -r '.dependencies["@mariozechner/pi-coding-agent"]' "${SOURCE_DIR}/package.json")"

  if [ -z "${agent_version}" ] || [ "${agent_version}" = "null" ]; then
    error "Failed to read @mariozechner/pi-coding-agent dependency version from package.json"
    exit 1
  fi

  tarball="$1"
  global_package_json="${piclaw_root}/package.json"

  status "Writing global package manifest to ${global_package_json}"
  printf '{"dependencies":{"@mariozechner/pi-coding-agent":"%s","piclaw":"%s"}}\n' \
    "latest" "${tarball}" | sudo tee "${global_package_json}" >/dev/null

  for lockfile in "${piclaw_root}/bun.lock" "${piclaw_root}/bun.lockb"; do
    if [ -e "${lockfile}" ]; then
      status "Removing global lockfile ${lockfile}"
      sudo rm -f "${lockfile}"
    fi
  done
}

install_global_packages() {
  local tarball bun_install
  tarball="$1"
  bun_install="$(resolve_bun_install)"

  status "Installing PiClaw + pi-coding-agent globally"
  sudo BUN_INSTALL="${bun_install}" "${bun_install}/bin/bun" install -g "${tarball}" --registry https://registry.npmjs.org --ignore-scripts
}

capture_tool_versions_before_updates() {
  CODEX_VERSION_BEFORE="$(get_codex_version)"
  CLAUDE_VERSION_BEFORE="$(get_claude_version)"
  PI_AGENT_VERSION_BEFORE="$(get_pi_agent_version)"
}

update_codex_cli() {
  if ! command -v npm >/dev/null 2>&1; then
    CODEX_VERSION_AFTER="${CODEX_VERSION_BEFORE}"
    CODEX_REPORT_LINE="Codex update skipped (npm not installed)"
    status "${CODEX_REPORT_LINE}"
    return 0
  fi

  status "Updating Codex CLI"
  npm update -g @openai/codex 2>/dev/null || npm install -g @openai/codex 2>/dev/null || true
  CODEX_VERSION_AFTER="$(get_codex_version)"
  CODEX_REPORT_LINE="$(update_report_line "Codex" "${CODEX_VERSION_BEFORE}" "${CODEX_VERSION_AFTER}")"
  status "${CODEX_REPORT_LINE}"
}

update_claude_cli() {
  if ! command -v claude >/dev/null 2>&1; then
    CLAUDE_VERSION_AFTER="${CLAUDE_VERSION_BEFORE}"
    CLAUDE_REPORT_LINE="$(update_report_line "Claude" "${CLAUDE_VERSION_BEFORE}" "${CLAUDE_VERSION_AFTER}")"
    return 0
  fi

  status "Updating Claude CLI"
  claude update --yes 2>/dev/null || true
  CLAUDE_VERSION_AFTER="$(get_claude_version)"
  CLAUDE_REPORT_LINE="$(update_report_line "Claude" "${CLAUDE_VERSION_BEFORE}" "${CLAUDE_VERSION_AFTER}")"
  status "${CLAUDE_REPORT_LINE}"
}

capture_piclaw_versions_after_install() {
  PICLAW_VERSION_AFTER="$(get_installed_version)"
  PICLAW_COMMIT_AFTER="$(get_source_commit)"
  PICLAW_REPORT_LINE="$(update_report_line "PiClaw" "${PICLAW_VERSION_BEFORE}" "${PICLAW_VERSION_AFTER}")"
  status "${PICLAW_REPORT_LINE}"
}

capture_pi_agent_version_after_install() {
  PI_AGENT_VERSION_AFTER="$(get_pi_agent_version)"
  PI_AGENT_REPORT_LINE="$(update_report_line "pi-coding-agent" "${PI_AGENT_VERSION_BEFORE}" "${PI_AGENT_VERSION_AFTER}")"
  status "${PI_AGENT_REPORT_LINE}"
}

format_summary_version() {
  local before after
  before="$1"
  after="$2"

  if [ "${before}" != "${after}" ]; then
    printf '%s → %s' "${before}" "${after}"
  elif [ "${after}" = "not installed" ]; then
    printf 'not installed'
  else
    printf '%s (already up-to-date)' "${after}"
  fi
}

print_summary_report() {
  local piclaw_line codex_line claude_line pi_agent_line

  piclaw_line="$(format_summary_version "${PICLAW_VERSION_BEFORE}" "${PICLAW_VERSION_AFTER}")"
  codex_line="$(format_summary_version "${CODEX_VERSION_BEFORE}" "${CODEX_VERSION_AFTER}")"
  claude_line="$(format_summary_version "${CLAUDE_VERSION_BEFORE}" "${CLAUDE_VERSION_AFTER}")"
  pi_agent_line="$(format_summary_version "${PI_AGENT_VERSION_BEFORE}" "${PI_AGENT_VERSION_AFTER}")"

  printf '═══════════════════════════════════════════════════════\n'
  printf '  PiClaw Update Report\n'
  printf '═══════════════════════════════════════════════════════\n'
  printf '  PiClaw:  %s\n' "${piclaw_line}"
  printf '           https://github.com/rcarmo/piclaw/commit/%s\n' "${PICLAW_COMMIT_AFTER}"
  printf '  Codex:   %s\n' "${codex_line}"
  printf '  Claude:  %s\n' "${claude_line}"
  printf '  pi-coding-agent: %s\n' "${pi_agent_line}"
  printf '═══════════════════════════════════════════════════════\n'
}

wire_extension_node_modules() {
  local bun_install global_node_modules extension_root extension_dir
  bun_install="$(resolve_bun_install)"
  global_node_modules="${bun_install}/install/global/node_modules"

  status "Wiring extension node_modules symlinks"

  for extension_root in "${HOME}/.pi/agent/extensions" "/workspace/.pi/extensions"; do
    [ -d "${extension_root}" ] || continue

    for extension_dir in "${extension_root}"/*/; do
      [ -d "${extension_dir}" ] || continue
      [ -e "${extension_dir}/node_modules" ] || ln -sf "${global_node_modules}" "${extension_dir}/node_modules" 2>/dev/null
    done
  done
}

wire_runtime_extensions_node_modules() {
  local bun_install dest
  bun_install="$(resolve_bun_install)"
  dest="${bun_install}/install/global/node_modules/piclaw"

  status "Ensuring runtime/extensions/node_modules symlink is wired"

  if [ -d "${dest}/runtime/extensions" ] && [ -d "${dest}/node_modules" ]; then
    sudo ln -sfn "${dest}/node_modules" "${dest}/runtime/extensions/node_modules"
  fi
}

fix_permissions() {
  local bun_install
  bun_install="$(resolve_bun_install)"

  status "Setting global Bun install permissions"
  sudo chmod -R a+rX "${bun_install}/bin" "${bun_install}/install/global"
}

ensure_piclaw_symlink() {
  local piclaw_bin
  piclaw_bin="$(readlink -f "$(command -v piclaw)")"

  status "Ensuring /usr/local/bin/piclaw symlink exists"
  if [ ! -L /usr/local/bin/piclaw ] || [ "$(readlink -f /usr/local/bin/piclaw 2>/dev/null || true)" != "${piclaw_bin}" ]; then
    sudo ln -sfn "${piclaw_bin}" /usr/local/bin/piclaw
  fi
}

regenerate_system_prompt() {
  status "Regenerating SYSTEM.md"
  sudo /usr/local/bin/piclaw-refresh-system-prompt
}

restart_service() {
  status "Restarting piclaw service"
  sudo systemctl restart piclaw.service
}

verify_installation() {
  status "Verifying service and SYSTEM.md"
  systemctl is-active piclaw.service >/dev/null
  test -s "${HOME}/.pi/agent/SYSTEM.md"
  echo "Update complete"
}

main() {
  require_command git
  require_command bun
  require_command jq
  require_command sudo
  require_command patch
  require_command systemctl
  refresh_source_checkout
  compare_versions_or_exit
  apply_source_patches
  build_from_source

  local tarball
  tarball="$(find_tarball)"

  capture_tool_versions_before_updates
  write_global_package_manifest "${tarball}"
  install_global_packages "${tarball}"
  capture_piclaw_versions_after_install
  capture_pi_agent_version_after_install
  wire_extension_node_modules
  wire_runtime_extensions_node_modules
  fix_permissions
  ensure_piclaw_symlink
  regenerate_system_prompt
  update_codex_cli
  update_claude_cli
  print_summary_report

  if [ "${NO_RESTART}" -eq 1 ]; then
    status "Skipping restart (--no-restart). Caller should restart piclaw."
  else
    restart_service
    verify_installation
  fi
}

main "$@"
