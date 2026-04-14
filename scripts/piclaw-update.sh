#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_URL="https://github.com/rcarmo/piclaw.git"
PATCH_DIR="$(cd "${SCRIPT_DIR}/../patches" && pwd)"
CACHE_DIR="/workspace/.cache/piclaw-upstream"
LIVE_DIR="/workspace/src/piclaw-live"
PREVIOUS_DIR="/workspace/src/piclaw-live.previous"
STATE_DIR="/workspace/.state"
LOCK_DIR="${STATE_DIR}/piclaw-live.update.lock"
WORK_ROOT="/workspace/.tmp"
WORK_DIR=""
SOURCE_DIR=""
STAGED_SYSTEM_PROMPT=""
LOCK_ACQUIRED=0
ACTIVATED=0
ROLLBACK_IN_PROGRESS=0

DRY_RUN=0
FORCE=0
NO_RESTART=0
VERIFY_ONLY=0
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

GLOBAL_PI_AGENT_VERSION_BEFORE=""
GLOBAL_PI_AGENT_VERSION_AFTER=""

status() {
  printf '[piclaw-update] %s\n' "$*"
}

error() {
  printf '[piclaw-update] ERROR: %s\n' "$*" >&2
}

quiet() {
  if [ "${VERBOSE}" -eq 1 ]; then
    "$@"
    return $?
  fi

  local out status_code
  out="$(mktemp)"
  "$@" >"${out}" 2>&1
  status_code=$?

  if [ "${status_code}" -eq 0 ]; then
    rm -f "${out}"
    return 0
  fi

  cat "${out}" >&2
  rm -f "${out}"
  return "${status_code}"
}

usage() {
  cat <<'EOF'
Usage: piclaw-update.sh [--dry-run] [--force] [--verify-only] [--no-restart] [--verbose]

Options:
  --dry-run      Refresh the upstream cache, compare versions, and exit.
  --force        Skip the version comparison and proceed with candidate prep.
  --verify-only  Build and validate a candidate without activating it.
  --no-restart   Compatibility flag. Activation still skips restart; caller handles restart.
  --verbose      Show full output from git, bun, and helper tools.
  -h, --help     Show this help text.
EOF
}

setup_work_dirs() {
  mkdir -p "$(dirname "${CACHE_DIR}")" "${STATE_DIR}" "${WORK_ROOT}" "/workspace/src"
  WORK_DIR="$(mktemp -d "${WORK_ROOT}/piclaw-update.XXXXXX")"
  SOURCE_DIR="${WORK_DIR}/piclaw-source"
  STAGED_SYSTEM_PROMPT="${WORK_DIR}/SYSTEM.md"
}

acquire_lock() {
  mkdir -p "${STATE_DIR}"

  if mkdir "${LOCK_DIR}" 2>/dev/null; then
    LOCK_ACQUIRED=1
    return 0
  fi

  error "Another update or rollback is already running (${LOCK_DIR})"
  exit 1
}

regenerate_system_prompt_from_root() {
  local root="$1"
  local output_path="${2:-${HOME}/.pi/agent/SYSTEM.md}"
  quiet env PICLAW_LIVE_ROOT="${root}" PICLAW_SYSTEM_PROMPT_OUT="${output_path}" "${SCRIPT_DIR}/piclaw-refresh-system-prompt"
}

rollback_failed_activation() {
  ROLLBACK_IN_PROGRESS=1
  status "Rolling back failed activation"

  local failed_live="${WORK_DIR}/failed-live"

  if [ -e "${LIVE_DIR}" ]; then
    mv "${LIVE_DIR}" "${failed_live}"
  fi

  if [ ! -e "${PREVIOUS_DIR}" ]; then
    error "Rollback failed: ${PREVIOUS_DIR} is missing"
    return 1
  fi

  mv "${PREVIOUS_DIR}" "${LIVE_DIR}"
  ACTIVATED=0

  if [ -e "${failed_live}" ]; then
    SOURCE_DIR="${failed_live}"
  fi

  regenerate_system_prompt_from_root "${LIVE_DIR}" || true
}

cleanup() {
  local exit_code=$?

  if [ "${exit_code}" -ne 0 ] && [ "${ACTIVATED}" -eq 1 ] && [ "${ROLLBACK_IN_PROGRESS}" -eq 0 ]; then
    rollback_failed_activation || true
  fi

  if [ -n "${WORK_DIR}" ] && [ -e "${WORK_DIR}" ]; then
    rm -rf "${WORK_DIR}"
  fi

  if [ "${LOCK_ACQUIRED}" -eq 1 ] && [ -d "${LOCK_DIR}" ]; then
    rmdir "${LOCK_DIR}" 2>/dev/null || true
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
    --verify-only)
      VERIFY_ONLY=1
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

patch_strip_level() {
  local patch_file="$1"
  if grep -qE '^(diff --git a/|--- a/)' "${patch_file}"; then
    echo 1
  else
    echo 0
  fi
}

git_apply_patch() {
  local repo_dir="$1"
  local patch_file="$2"
  shift 2

  local strip_level
  strip_level="$(patch_strip_level "${patch_file}")"
  git -C "${repo_dir}" apply -p"${strip_level}" --recount --unidiff-zero "$@" "${patch_file}"
}

get_global_pi_agent_version() {
  local pkg_json="${HOME}/.bun/install/global/node_modules/@mariozechner/pi-coding-agent/package.json"
  if [ -f "${pkg_json}" ]; then
    jq -r '.version' "${pkg_json}" 2>/dev/null || echo "unknown"
  else
    echo "not installed"
  fi
}

get_pi_agent_version_from_root() {
  local root="$1"
  local pkg_json="${root}/node_modules/@mariozechner/pi-coding-agent/package.json"
  if [ -f "${pkg_json}" ]; then
    jq -r '.version' "${pkg_json}" 2>/dev/null || echo "unknown"
  else
    echo "not installed"
  fi
}

get_current_piclaw_version() {
  if [ -d "${LIVE_DIR}/.git" ]; then
    git -C "${LIVE_DIR}" describe --always --dirty --tags
    return 0
  fi

  if command -v piclaw >/dev/null 2>&1; then
    piclaw --version 2>/dev/null || printf 'unknown\n'
    return 0
  fi

  printf 'unknown\n'
}

get_live_piclaw_version() {
  if [ -d "${LIVE_DIR}/.git" ]; then
    git -C "${LIVE_DIR}" describe --always --dirty --tags
  else
    printf 'not deployed\n'
  fi
}

get_live_piclaw_commit() {
  if [ -d "${LIVE_DIR}/.git" ]; then
    git -C "${LIVE_DIR}" rev-parse HEAD
  else
    printf 'unknown\n'
  fi
}

get_source_version() {
  git -C "${SOURCE_DIR}" describe --always --dirty --tags
}

get_current_pi_agent_version() {
  if [ -d "${LIVE_DIR}/node_modules" ]; then
    get_pi_agent_version_from_root "${LIVE_DIR}"
  else
    get_global_pi_agent_version
  fi
}

get_codex_version() {
  codex --version 2>/dev/null || echo "not installed"
}

get_claude_version() {
  claude --version 2>/dev/null | head -1 || echo "not installed"
}

update_report_line() {
  local name="$1"
  local before="$2"
  local after="$3"

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

  status "Creating candidate checkout in ${SOURCE_DIR}"
  quiet git clone --no-hardlinks "${CACHE_DIR}" "${SOURCE_DIR}"
}

compare_versions_or_exit() {
  local current_version source_version
  current_version="$(get_current_piclaw_version)"
  source_version="$(get_source_version)"

  PICLAW_VERSION_BEFORE="${current_version}"

  status "Current version: ${current_version}"
  status "Source version: ${source_version}"

  if [ "${DRY_RUN}" -eq 1 ]; then
    status "Dry run requested; exiting after version comparison"
    exit 0
  fi

  if [ "${FORCE}" -eq 1 ] || [ "${VERIFY_ONLY}" -eq 1 ]; then
    if [ "${FORCE}" -eq 1 ]; then
      status "Force requested; skipping version equality check"
    else
      status "Verify-only requested; skipping version equality check"
    fi
    return 0
  fi

  if [ ! -d "${LIVE_DIR}/.git" ]; then
    status "No live checkout found at ${LIVE_DIR}; proceeding with initial source deployment"
    return 0
  fi

  if [ "${current_version}" = "${source_version}" ]; then
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
    status "Checking patch $(basename "${p}")"
    if ! quiet git_apply_patch "${SOURCE_DIR}" "${p}" --check; then
      error "git apply --check failed for $(basename "${p}")"
      exit 1
    fi

    status "Applying patch $(basename "${p}")"
    if ! quiet git_apply_patch "${SOURCE_DIR}" "${p}"; then
      error "git apply failed for $(basename "${p}")"
      exit 1
    fi

    local leftover
    leftover="$(find "${SOURCE_DIR}" \( -name '*.rej' -o -name '*.orig' \) -print)"
    if [ -n "${leftover}" ]; then
      printf '%s\n' "${leftover}" >&2
      error "Patch $(basename "${p}") produced .rej/.orig files"
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

verify_session_system_prompt_patch() {
  local session_file="${SOURCE_DIR}/runtime/src/agent-pool/session.ts"
  [ -f "${session_file}" ] || return 0

  if grep -q 'getSystemPromptOverride' "${session_file}" && ! grep -Eq 'import \{[^}]*readFileSync' "${session_file}"; then
    error "session.ts references getSystemPromptOverride without importing readFileSync"
    exit 1
  fi
}

verify_candidate_patch_integrity() {
  local check_reverse_patches="${1:-1}"
  status "Verifying patch integrity"

  local leftover
  leftover="$(find "${SOURCE_DIR}" \( -name '*.rej' -o -name '*.orig' \) -print)"
  if [ -n "${leftover}" ]; then
    printf '%s\n' "${leftover}" >&2
    error "Patch application left .rej/.orig files in the candidate tree"
    exit 1
  fi

  if [ "${check_reverse_patches}" -eq 1 ]; then
    if ! quiet git -C "${SOURCE_DIR}" diff --check; then
      error "Candidate checkout failed git diff --check after patch application"
      exit 1
    fi
  fi

  if grep -R -n -E '^(<<<<<<<|=======|>>>>>>>)' "${SOURCE_DIR}" >/dev/null 2>&1; then
    grep -R -n -E '^(<<<<<<<|=======|>>>>>>>)' "${SOURCE_DIR}" >&2 || true
    error "Candidate checkout contains conflict markers after patch application"
    exit 1
  fi

  if [ "${check_reverse_patches}" -eq 1 ]; then
    local reverse_check_dir="${WORK_DIR}/reverse-check-source"
    rm -rf "${reverse_check_dir}"
    rsync -a --delete "${SOURCE_DIR}/" "${reverse_check_dir}/"

    local patches=()
    local p
    for p in "${PATCH_DIR}"/[0-9]*.patch; do
      [ -f "${p}" ] || continue
      patches+=("${p}")
    done

    local idx
    for (( idx=${#patches[@]}-1; idx>=0; idx-- )); do
      p="${patches[$idx]}"
      if ! quiet git_apply_patch "${reverse_check_dir}" "${p}" --check --reverse; then
        error "git apply reverse-check failed for $(basename "${p}")"
        exit 1
      fi
      if ! quiet git_apply_patch "${reverse_check_dir}" "${p}" --reverse; then
        error "git apply reverse failed for $(basename "${p}")"
        exit 1
      fi
    done
  fi

  verify_session_system_prompt_patch
}

build_from_source() {
  cd "${SOURCE_DIR}"
  status "Installing dependencies"
  if ! BUN_INSTALL_CACHE_DIR="${WORK_DIR}/.bun-cache" quiet bun install --ignore-scripts; then
    error "Dependency installation failed"
    exit 1
  fi
  status "Compiling server"
  if ! quiet bun run build; then
    error "Server build failed"
    exit 1
  fi
  status "Compiling web UI"
  if ! quiet bun run build:web; then
    error "Web UI build failed"
    exit 1
  fi

  find runtime/web/static/dist -type f -name '*.map' -delete
}

validate_candidate() {
  status "Validating candidate checkout"
  test -s "${SOURCE_DIR}/runtime/web/static/dist/app.bundle.js"
  test -s "${SOURCE_DIR}/runtime/web/static/dist/app.bundle.css"
  test -s "${SOURCE_DIR}/runtime/web/static/dist/login.bundle.js"
  test -s "${SOURCE_DIR}/runtime/web/static/dist/login.bundle.css"
  test -f "${SOURCE_DIR}/node_modules/@mariozechner/pi-coding-agent/dist/cli.js"
}

stage_system_prompt() {
  status "Staging SYSTEM.md from template"
  if ! regenerate_system_prompt_from_root "${SOURCE_DIR}" "${STAGED_SYSTEM_PROMPT}"; then
    error "Failed to stage SYSTEM.md"
    exit 1
  fi

  test -s "${STAGED_SYSTEM_PROMPT}"
}

capture_tool_versions_before_updates() {
  CODEX_VERSION_BEFORE="$(get_codex_version)"
  CLAUDE_VERSION_BEFORE="$(get_claude_version)"
  PI_AGENT_VERSION_BEFORE="$(get_current_pi_agent_version)"
  GLOBAL_PI_AGENT_VERSION_BEFORE="$(get_global_pi_agent_version)"
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
  if ! quiet claude update; then
    status "Claude CLI update failed; continuing"
  fi

  CLAUDE_VERSION_AFTER="$(get_claude_version)"
  status "$(update_report_line "Claude" "${CLAUDE_VERSION_BEFORE}" "${CLAUDE_VERSION_AFTER}")"
}

update_global_pi_agent_cli() {
  if ! command -v bun >/dev/null 2>&1; then
    GLOBAL_PI_AGENT_VERSION_AFTER="${GLOBAL_PI_AGENT_VERSION_BEFORE}"
    status "Global pi-coding-agent update skipped (bun not installed)"
    return 0
  fi

  status "Updating global pi-coding-agent CLI"
  if ! quiet bun add -g @mariozechner/pi-coding-agent@latest; then
    status "Global pi-coding-agent update failed; continuing"
  fi

  GLOBAL_PI_AGENT_VERSION_AFTER="$(get_global_pi_agent_version)"
  status "$(update_report_line "Global pi-coding-agent" "${GLOBAL_PI_AGENT_VERSION_BEFORE}" "${GLOBAL_PI_AGENT_VERSION_AFTER}")"
}

apply_post_install_patches() {
  local target_root="$1"
  local post_patch_dir="${SCRIPT_DIR}/../patches/post-install"
  [ -d "${post_patch_dir}" ] || return 0

  local count=0
  local script
  for script in "${post_patch_dir}"/[0-9]*.sh; do
    [ -f "${script}" ] || continue
    [ -x "${script}" ] || chmod +x "${script}"
    status "Running post-install patch $(basename "${script}")"
    if ! quiet "${script}" "${target_root}"; then
      error "Post-install patch $(basename "${script}") failed"
      exit 1
    fi
    count=$((count + 1))
  done

  if [ "${count}" -gt 0 ]; then
    status "Applied ${count} post-install patch(es)"
  fi
}

activate_candidate() {
  status "Activating candidate checkout"

  if [ -e "${PREVIOUS_DIR}" ]; then
    rm -rf "${PREVIOUS_DIR}"
  fi

  if [ -e "${LIVE_DIR}" ]; then
    mv "${LIVE_DIR}" "${PREVIOUS_DIR}"
  fi

  mv "${SOURCE_DIR}" "${LIVE_DIR}"
  SOURCE_DIR=""
  ACTIVATED=1
}

capture_piclaw_versions_after_activation() {
  PICLAW_VERSION_AFTER="$(get_live_piclaw_version)"
  PICLAW_COMMIT_AFTER="$(get_live_piclaw_commit)"
  status "$(update_report_line "PiClaw" "${PICLAW_VERSION_BEFORE}" "${PICLAW_VERSION_AFTER}")"
}

capture_pi_agent_version_after_activation() {
  PI_AGENT_VERSION_AFTER="$(get_pi_agent_version_from_root "${LIVE_DIR}")"
  status "$(update_report_line "pi-coding-agent" "${PI_AGENT_VERSION_BEFORE}" "${PI_AGENT_VERSION_AFTER}")"
}

format_summary_version() {
  local before="$1"
  local after="$2"

  if [ "${before}" != "${after}" ]; then
    printf '%s -> %s' "${before}" "${after}"
  elif [ "${after}" = "not installed" ]; then
    printf 'not installed'
  else
    printf '%s (already up-to-date)' "${after}"
  fi
}

print_summary_report() {
  local piclaw_line codex_line claude_line bundled_pi_agent_line global_pi_agent_line

  piclaw_line="$(format_summary_version "${PICLAW_VERSION_BEFORE}" "${PICLAW_VERSION_AFTER}")"
  codex_line="$(format_summary_version "${CODEX_VERSION_BEFORE}" "${CODEX_VERSION_AFTER}")"
  claude_line="$(format_summary_version "${CLAUDE_VERSION_BEFORE}" "${CLAUDE_VERSION_AFTER}")"
  bundled_pi_agent_line="$(format_summary_version "${PI_AGENT_VERSION_BEFORE}" "${PI_AGENT_VERSION_AFTER}")"
  global_pi_agent_line="$(format_summary_version "${GLOBAL_PI_AGENT_VERSION_BEFORE}" "${GLOBAL_PI_AGENT_VERSION_AFTER}")"

  printf '═══════════════════════════════════════════════════════\n'
  printf '  PiClaw Update Report\n'
  printf '═══════════════════════════════════════════════════════\n'
  printf '  PiClaw:  %s\n' "${piclaw_line}"
  printf '           https://github.com/rcarmo/piclaw/commit/%s\n' "${PICLAW_COMMIT_AFTER}"
  printf '  Codex:   %s\n' "${codex_line}"
  printf '  Claude:  %s\n' "${claude_line}"
  printf '  pi-coding-agent (bundled): %s\n' "${bundled_pi_agent_line}"
  printf '  pi-coding-agent (global):  %s\n' "${global_pi_agent_line}"
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
  local ext_dir
  for ext_dir in "${ext_src}"/*/; do
    [ -d "${ext_dir}" ] || continue
    local name
    local dest
    name="$(basename "${ext_dir}")"
    dest="${ext_dest}/${name}"

    mkdir -p "${dest}"
    rsync -a --delete --exclude='node_modules' "${ext_dir}" "${dest}/"

    if [ -f "${configs_src}/${name}.json" ]; then
      cp "${configs_src}/${name}.json" "${ext_dest}/${name}.json"
    fi

    count=$((count + 1))
  done

  status "Deployed ${count} custom extension(s)"
}

wire_extension_node_modules() {
  local live_node_modules="${LIVE_DIR}/node_modules"
  local extension_root
  local extension_dir

  for extension_root in "${HOME}/.pi/agent/extensions" "/workspace/.pi/extensions"; do
    [ -d "${extension_root}" ] || continue

    for extension_dir in "${extension_root}"/*/; do
      [ -d "${extension_dir}" ] || continue
      ln -sfn "${live_node_modules}" "${extension_dir}/node_modules" 2>/dev/null
    done
  done
}

install_staged_system_prompt() {
  status "Installing staged SYSTEM.md"
  mkdir -p "$(dirname "${HOME}/.pi/agent/SYSTEM.md")"
  install -m 0644 "${STAGED_SYSTEM_PROMPT}" "${HOME}/.pi/agent/SYSTEM.md"
}

main() {
  require_command git
  acquire_lock
  setup_work_dirs
  refresh_source_checkout
  compare_versions_or_exit

  require_commands bun jq rsync curl python3

  apply_source_patches
  verify_candidate_patch_integrity 1
  build_from_source
  validate_candidate
  capture_tool_versions_before_updates
  apply_post_install_patches "${SOURCE_DIR}"
  verify_candidate_patch_integrity 0
  stage_system_prompt

  if [ "${VERIFY_ONLY}" -eq 1 ]; then
    status "Candidate verified; no activation performed"
    echo "Deployability verification complete"
    return 0
  fi

  activate_candidate
  capture_piclaw_versions_after_activation
  capture_pi_agent_version_after_activation
  deploy_custom_extensions
  wire_extension_node_modules
  install_staged_system_prompt
  update_global_pi_agent_cli
  update_codex_cli
  update_claude_cli
  print_summary_report

  if [ "${NO_RESTART}" -eq 1 ]; then
    status "Activation complete. Restart skipped (--no-restart). Caller should restart and verify piclaw."
  else
    status "Activation complete. Restart and health verification are handled by the host wrapper."
  fi

  echo "Activation complete"
}

main "$@"
