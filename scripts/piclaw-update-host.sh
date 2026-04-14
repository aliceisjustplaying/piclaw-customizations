#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_HOME="/home/agent"
AGENT_PATH="${AGENT_HOME}/.local/bin:${AGENT_HOME}/.bun/bin:/etc/profiles/per-user/agent/bin:/usr/local/bin:/run/wrappers/bin:/run/current-system/sw/bin"

status() {
  printf '[piclaw-update-host] %s\n' "$*"
}

error() {
  printf '[piclaw-update-host] ERROR: %s\n' "$*" >&2
}

run_as_agent() {
  sudo -u agent -H env \
    HOME="${AGENT_HOME}" \
    USER=agent \
    PATH="${AGENT_PATH}" \
    "$@"
}

wait_for_health() {
  local attempt
  for attempt in $(seq 1 30); do
    if systemctl is-active piclaw.service >/dev/null 2>&1 && run_as_agent "${SCRIPT_DIR}/piclaw-healthcheck.sh" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  return 1
}

main() {
  local skip_restart=0
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --no-restart|--verify-only|--dry-run)
        skip_restart=1
        ;;
    esac
  done

  run_as_agent "${SCRIPT_DIR}/piclaw-update.sh" "$@"

  if [ "${skip_restart}" -eq 1 ]; then
    status "Skipping restart for the requested mode"
    exit 0
  fi

  status "Restarting piclaw service"
  systemctl restart piclaw.service

  if wait_for_health; then
    status "Update complete, health OK"
    exit 0
  fi

  error "Health check failed after restart; rolling back"
  run_as_agent "${SCRIPT_DIR}/piclaw-rollback.sh"

  systemctl restart piclaw.service

  if ! wait_for_health; then
    error "Rollback also failed health checks"
    exit 1
  fi

  error "Rolled back — update failed health check"
  exit 1
}

main "$@"
