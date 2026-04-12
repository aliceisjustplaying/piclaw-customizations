#!/usr/bin/env bash
# patches/post-install/02-context-usage-from-session-context.sh
#
# Fix: context meter can stay stale after /new-session because getContextUsage()
# estimates from agent.state.messages instead of the canonical session tree.
#
# After a session switch, the authoritative context is
# sessionManager.buildSessionContext().messages. Using that keeps /agent/context
# and the web UI meter aligned with the actual active session.
#
# This patch is idempotent and safe to run on every update.

set -euo pipefail

SUDO_BIN="$(command -v sudo || true)"
if [ -z "$SUDO_BIN" ] && [ -x /run/current-system/sw/bin/sudo ]; then
  SUDO_BIN=/run/current-system/sw/bin/sudo
fi

TARGETS=(
  /home/agent/.bun/install/global/node_modules/@mariozechner/pi-coding-agent/dist/core/agent-session.js
)

for cached in /home/agent/.bun/install/cache/@mariozechner/pi-coding-agent@*/dist/core/agent-session.js; do
  [ -f "$cached" ] && TARGETS+=("$cached")
done

for nested in /home/agent/.bun/install/global/node_modules/piclaw/node_modules/@mariozechner/pi-coding-agent/dist/core/agent-session.js; do
  [ -f "$nested" ] && TARGETS+=("$nested")
done

declare -A seen_inodes
UNIQUE_PATHS=()
for p in "${TARGETS[@]}"; do
  [ -f "$p" ] || continue
  inode=$(stat -c '%i' "$p")
  if [ -z "${seen_inodes[$inode]:-}" ]; then
    seen_inodes[$inode]=1
    UNIQUE_PATHS+=("$p")
  fi
done

PATCHED=0
for target in "${UNIQUE_PATHS[@]}"; do
  if grep -q 'estimateContextTokens(this.sessionManager.buildSessionContext().messages)' "$target" 2>/dev/null; then
    echo "Already patched: $target"
    continue
  fi

  if ! grep -q 'estimateContextTokens(this.messages)' "$target" 2>/dev/null; then
    echo "Pattern not found, skipping: $target"
    continue
  fi

  tmp=$(mktemp)
  cp "$target" "$tmp"

  sed -i 's|estimateContextTokens(this.messages)|estimateContextTokens(this.sessionManager.buildSessionContext().messages)|' "$tmp"

  if ! cp "$tmp" "$target" 2>/dev/null; then
    if [ -n "$SUDO_BIN" ]; then
      "$SUDO_BIN" cp --preserve=mode,ownership "$tmp" "$target"
    else
      echo "Need sudo to patch: $target" >&2
      rm -f "$tmp"
      exit 1
    fi
  fi
  rm -f "$tmp"
  echo "Patched: $target"
  PATCHED=$((PATCHED + 1))
done

echo "Done. Patched $PATCHED file(s)."
