#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_URL="https://github.com/rcarmo/piclaw.git"
CACHE_DIR="/workspace/.cache/piclaw-upstream"
WORK_DIR=""
SOURCE_DIR=""
PACK_DIR=""
PATCH_DIR="$(cd "${SCRIPT_DIR}/../patches" && pwd)"

DRY_RUN=0
FORCE=0
NO_RESTART=0
VERBOSE=0

PICLAW_VERSION_BEFORE=""
PICLAW_VERSION_AFTER=""
PICLAW_COMMIT_AFTER=""

CODEX_VERSION_BEFORE=""
CODEX_VERSION_AFTER=""

CLAUDE_VERSION_BEFORE=""
CLAUDE_VERSION_AFTER=""

PI_AGENT_VERSION_BEFORE=""
PI_AGENT_VERSION_AFTER=""

status() {
  printf '[piclaw-update] %s\n' "$*"
}

error() {
  printf '[piclaw-update] ERROR: %s\n' "$*" >&2
}

# Capture stdout+stderr unless --verbose is set.
# On failure, replay the captured output and preserve the command's exit code.
quiet() {
  if [ "${VERBOSE}" -eq 1 ]; then
    "$@"
    return 0
  fi

  local out status_code
  out="$(mktemp)"

  if "$@" >"${out}" 2>&1; then
    rm -f "${out}"
    return 0
  fi

  status_code=$?
  cat "${out}" >&2
  rm -f "${out}"
  return "${status_code}"
}

usage() {
  cat <<'EOF'
Usage: piclaw-update.sh [--dry-run] [--force] [--no-restart] [--verbose]

Options:
  --dry-run     Refresh the upstream cache, compare versions, and exit.
  --force       Skip the version comparison and proceed with install.
  --no-restart  Do everything except restart (caller handles restart).
  --verbose     Show full output from git, bun, tsc, npm, and patch.
  -h, --help    Show this help text.
EOF
}

setup_work_dirs() {
  WORK_DIR="$(mktemp -d -t piclaw-update.XXXXXX)"
  SOURCE_DIR="${WORK_DIR}/source"
  PACK_DIR="${WORK_DIR}/pack"

  mkdir -p "$(dirname "${CACHE_DIR}")" "${PACK_DIR}"
}

cleanup() {
  local exit_code=$?

  if [ -n "${WORK_DIR}" ] && [ -e "${WORK_DIR}" ]; then
    rm -rf "${WORK_DIR}"
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
    --verbose|-v)
      VERBOSE=1
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

require_commands() {
  local cmd
  for cmd in "$@"; do
    require_command "${cmd}"
  done
}

resolve_bun_binary() {
  command -v bun
}

resolve_bun_install() {
  # Writable root for bun's global installs (contains install/global/).
  # Prefer BUN_INSTALL env var, then ~/.bun, then derive from the binary.
  if [ -n "${BUN_INSTALL:-}" ] && [ -d "${BUN_INSTALL}" ]; then
    printf '%s\n' "${BUN_INSTALL}"
    return
  fi

  if [ -d "${HOME}/.bun" ]; then
    printf '%s\n' "${HOME}/.bun"
    return
  fi

  local bun_path
  bun_path="$(readlink -f "$(resolve_bun_binary)")"
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
  local pkg_json
  pkg_json="$(resolve_global_dir)/node_modules/@mariozechner/pi-coding-agent/package.json"
  if [ -f "${pkg_json}" ]; then
    jq -r '.version' "${pkg_json}" 2>/dev/null || echo "unknown"
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
  status "Refreshing upstream cache in ${CACHE_DIR}"

  if [ -e "${CACHE_DIR}" ] && [ ! -d "${CACHE_DIR}/.git" ]; then
    status "Removing non-git directory at ${CACHE_DIR}"
    rm -rf "${CACHE_DIR}"
  fi

  if [ -d "${CACHE_DIR}/.git" ]; then
    quiet git -C "${CACHE_DIR}" fetch --prune origin
    quiet git -C "${CACHE_DIR}" reset --hard origin/HEAD
  else
    rm -rf "${CACHE_DIR}"
    quiet git clone "${REPO_URL}" "${CACHE_DIR}"
  fi

  status "Creating working checkout in ${SOURCE_DIR}"
  quiet git clone --no-hardlinks "${CACHE_DIR}" "${SOURCE_DIR}"
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
  local count=0

  if [ ! -d "${PATCH_DIR}" ]; then
    error "Patch directory does not exist: ${PATCH_DIR}"
    exit 1
  fi

  status "Applying source patches from ${PATCH_DIR}"
  cd "${SOURCE_DIR}"

  for p in "${PATCH_DIR}"/[0-9]*.patch; do
    [ -f "${p}" ] || continue
    status "Applying patch $(basename "${p}")"
    if ! sed 's/\.orig\t/\t/g; s/\.bak\t/\t/g' "${p}" | quiet patch -p0; then
      error "Failed to apply patch $(basename "${p}")"
      exit 1
    fi
    count=$((count + 1))
  done

  if [ "${count}" -eq 0 ]; then
    error "No patches found in ${PATCH_DIR}"
    exit 1
  fi

  status "Applied ${count} patch(es)"
}

build_from_source() {
  cd "${SOURCE_DIR}"
  status "Installing dependencies"
  BUN_INSTALL_CACHE_DIR="${SOURCE_DIR}/.bun-cache" quiet bun install --ignore-scripts
  status "Compiling server"
  quiet bun run build
  status "Compiling web UI"
  quiet bun run build:web

  find runtime/web/static/dist -type f -name '*.map' -delete

  status "Packing tarball"
  rm -rf "${PACK_DIR}"
  mkdir -p "${PACK_DIR}"
  rm -f piclaw-*.tgz
  quiet bun pm pack
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

  printf '{"dependencies":{"@mariozechner/pi-coding-agent":"%s","piclaw":"%s"}}\n' \
    "${agent_version}" "${tarball}" | sudo tee "${global_package_json}" >/dev/null

  for lockfile in "${piclaw_root}/bun.lock" "${piclaw_root}/bun.lockb"; do
    if [ -e "${lockfile}" ]; then
      sudo rm -f "${lockfile}"
    fi
  done
}

install_global_packages() {
  local tarball bun_install bun_bin
  tarball="$1"
  bun_install="$(resolve_bun_install)"
  bun_bin="$(resolve_bun_binary)"

  status "Installing PiClaw + pi-coding-agent globally"
  quiet sudo BUN_INSTALL="${bun_install}" "${bun_bin}" install -g "${tarball}" --registry https://registry.npmjs.org --ignore-scripts
}

capture_tool_versions_before_updates() {
  CODEX_VERSION_BEFORE="$(get_codex_version)"
  CLAUDE_VERSION_BEFORE="$(get_claude_version)"
  PI_AGENT_VERSION_BEFORE="$(get_pi_agent_version)"
}

update_codex_cli() {
  if ! command -v npm >/dev/null 2>&1; then
    CODEX_VERSION_AFTER="${CODEX_VERSION_BEFORE}"
    status "Codex update skipped (npm not installed)"
    return 0
  fi

  status "Updating Codex CLI"
  if ! quiet npm update -g @openai/codex; then
    if ! quiet npm install -g @openai/codex; then
      status "Codex CLI update failed; continuing"
    fi
  fi

  CODEX_VERSION_AFTER="$(get_codex_version)"
  status "$(update_report_line "Codex" "${CODEX_VERSION_BEFORE}" "${CODEX_VERSION_AFTER}")"
}

update_claude_cli() {
  if ! command -v claude >/dev/null 2>&1; then
    CLAUDE_VERSION_AFTER="${CLAUDE_VERSION_BEFORE}"
    status "$(update_report_line "Claude" "${CLAUDE_VERSION_BEFORE}" "${CLAUDE_VERSION_AFTER}")"
    return 0
  fi

  status "Updating Claude CLI"
  if ! quiet claude update --yes; then
    status "Claude CLI update failed; continuing"
  fi

  CLAUDE_VERSION_AFTER="$(get_claude_version)"
  status "$(update_report_line "Claude" "${CLAUDE_VERSION_BEFORE}" "${CLAUDE_VERSION_AFTER}")"
}

capture_piclaw_versions_after_install() {
  PICLAW_VERSION_AFTER="$(get_installed_version)"
  PICLAW_COMMIT_AFTER="$(get_source_commit)"
  status "$(update_report_line "PiClaw" "${PICLAW_VERSION_BEFORE}" "${PICLAW_VERSION_AFTER}")"
}

capture_pi_agent_version_after_install() {
  PI_AGENT_VERSION_AFTER="$(get_pi_agent_version)"
  status "$(update_report_line "pi-coding-agent" "${PI_AGENT_VERSION_BEFORE}" "${PI_AGENT_VERSION_AFTER}")"
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

deploy_custom_extensions() {
  local ext_src="${SCRIPT_DIR}/../extensions"
  local ext_dest="/workspace/.pi/extensions"
  local configs_src="${SCRIPT_DIR}/../configs"

  [ -d "${ext_src}" ] || return 0

  status "Deploying custom extensions"
  mkdir -p "${ext_dest}"

  local count=0
  for ext_dir in "${ext_src}"/*/; do
    [ -d "${ext_dir}" ] || continue
    local name
    name="$(basename "${ext_dir}")"
    local dest="${ext_dest}/${name}"

    # Sync extension files (exclude node_modules — wired separately)
    mkdir -p "${dest}"
    rsync -a --delete --exclude='node_modules' "${ext_dir}" "${dest}/"

    # Deploy matching config if it exists
    if [ -f "${configs_src}/${name}.json" ]; then
      cp "${configs_src}/${name}.json" "${ext_dest}/${name}.json"
    fi

    count=$((count + 1))
  done

  status "Deployed ${count} custom extension(s)"
}

wire_extension_node_modules() {
  local bun_install global_node_modules extension_root extension_dir
  bun_install="$(resolve_bun_install)"
  global_node_modules="${bun_install}/install/global/node_modules"

  for extension_root in "${HOME}/.pi/agent/extensions" "/workspace/.pi/extensions"; do
    [ -d "${extension_root}" ] || continue

    for extension_dir in "${extension_root}"/*/; do
      [ -d "${extension_dir}" ] || continue
      ln -sfn "${global_node_modules}" "${extension_dir}/node_modules" 2>/dev/null
    done
  done
}

wire_runtime_extensions_node_modules() {
  local bun_install dest
  bun_install="$(resolve_bun_install)"
  dest="${bun_install}/install/global/node_modules/piclaw"

  if [ -d "${dest}/runtime/extensions" ] && [ -d "${dest}/node_modules" ]; then
    sudo ln -sfn "${dest}/node_modules" "${dest}/runtime/extensions/node_modules"
  fi
}

apply_post_install_patches() {
  local post_patch_dir="${SCRIPT_DIR}/../patches/post-install"
  [ -d "${post_patch_dir}" ] || return 0

  local count=0
  for script in "${post_patch_dir}"/[0-9]*.sh; do
    [ -f "${script}" ] || continue
    [ -x "${script}" ] || chmod +x "${script}"
    status "Running post-install patch $(basename "${script}")"
    if ! quiet "${script}"; then
      error "Post-install patch $(basename "${script}") failed"
      exit 1
    fi
    count=$((count + 1))
  done

  if [ "${count}" -gt 0 ]; then
    status "Applied ${count} post-install patch(es)"
  fi
}

fix_permissions() {
  local bun_install
  bun_install="$(resolve_bun_install)"

  [ -d "${bun_install}/bin" ] && sudo chmod -R a+rX "${bun_install}/bin"
  sudo chmod -R a+rX "${bun_install}/install/global"
}

ensure_piclaw_symlink() {
  local piclaw_bin
  piclaw_bin="$(readlink -f "$(command -v piclaw)")"

  if [ ! -L /usr/local/bin/piclaw ] || [ "$(readlink -f /usr/local/bin/piclaw 2>/dev/null || true)" != "${piclaw_bin}" ]; then
    sudo ln -sfn "${piclaw_bin}" /usr/local/bin/piclaw
  fi
}

regenerate_system_prompt() {
  status "Regenerating SYSTEM.md"
  quiet sudo "${SCRIPT_DIR}/piclaw-refresh-system-prompt"
}

restart_service() {
  status "Restarting piclaw service"
  sudo systemctl restart piclaw.service
}

verify_installation() {
  status "Verifying service, CLI, and SYSTEM.md"
  systemctl is-active piclaw.service >/dev/null
  piclaw --version >/dev/null
  test -s "${HOME}/.pi/agent/SYSTEM.md"
  echo "Update complete"
}

main() {
  require_command git
  setup_work_dirs
  refresh_source_checkout
  compare_versions_or_exit

  require_commands bun jq sudo patch rsync
  apply_source_patches
  build_from_source

  local tarball
  tarball="$(find_tarball)"

  capture_tool_versions_before_updates
  write_global_package_manifest "${tarball}"
  install_global_packages "${tarball}"
  capture_piclaw_versions_after_install
  capture_pi_agent_version_after_install
  deploy_custom_extensions
  wire_extension_node_modules
  wire_runtime_extensions_node_modules
  apply_post_install_patches
  fix_permissions
  ensure_piclaw_symlink
  regenerate_system_prompt
  update_codex_cli
  update_claude_cli
  print_summary_report

  if [ "${NO_RESTART}" -eq 1 ]; then
    status "Skipping restart (--no-restart). Caller should restart piclaw."
  else
    require_command systemctl
    restart_service
    verify_installation
  fi
}

main "$@"
