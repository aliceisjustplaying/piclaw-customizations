#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_HOME="/home/agent"
AGENT_PATH="${AGENT_HOME}/.local/bin:${AGENT_HOME}/.bun/bin:/usr/local/bin:/run/wrappers/bin:/run/current-system/sw/bin"

status() {
  printf '[piclaw-rollback-host] %s\n' "$*"
}

error() {
  printf '[piclaw-rollback-host] ERROR: %s\n' "$*" >&2
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
  run_as_agent "${SCRIPT_DIR}/piclaw-rollback.sh" "$@"

  status "Restarting piclaw service"
  systemctl restart piclaw.service

  if ! wait_for_health; then
    error "PiClaw failed health checks after rollback"
    exit 1
  fi

  status "Rollback complete"
}

main "$@"
