#!/usr/bin/env bash
# Regenerate patches by diffing the live deployed piclaw against clean source.
# Use this after making manual fixes to deployed files to keep patches in sync.
set -euo pipefail

REPO_URL="https://github.com/rcarmo/piclaw.git"
PATCH_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# Resolve installed piclaw package root
piclaw_bin="$(readlink -f "$(command -v piclaw)")"
INSTALLED="$(dirname "$(dirname "$(dirname "$piclaw_bin")")")"
if [ ! -d "$INSTALLED/runtime" ]; then
  echo "[regen] ERROR: Could not find piclaw package root at $INSTALLED"
  exit 1
fi
echo "[regen] Installed piclaw at: $INSTALLED"

echo "[regen] Cloning clean source..."
git clone --depth=1 --quiet "$REPO_URL" "$WORK_DIR/piclaw"

# Single-file server-side patches (relative to piclaw root)
declare -A PATCH_FILES=(
  ["01-session-system-prompt.patch"]="runtime/src/agent-pool/session.ts"
  ["02-bootstrap-broadcast-event.patch"]="runtime/src/runtime/bootstrap.ts"
  # 04-web-codex-action-handler.patch is multi-file (dispatch-agent.ts + web UI), cannot be regenerated from installed bundle
  # 05-web-update-autocomplete.patch is web-source only, cannot be regenerated from installed bundle
  # 06-terminal-dock-and-popout-fixes.patch is web-source only, cannot be regenerated from installed bundle
  ["11-db-lazy-init-for-extension-module-graph.patch"]="runtime/src/db/connection.ts"
  ["12-fix-extension-error-cast.patch"]="runtime/src/channels/web/theming/ui-bridge.ts"
)

cd "$WORK_DIR/piclaw"

for patch_name in $(echo "${!PATCH_FILES[@]}" | tr ' ' '\n' | sort); do
  rel_path="${PATCH_FILES[$patch_name]}"
  clean="$rel_path"
  live="$INSTALLED/$rel_path"

  if [ ! -f "$clean" ]; then
    echo "  ⚠️  $patch_name — clean source file missing: $rel_path"
    continue
  fi
  if [ ! -f "$live" ]; then
    echo "  ⚠️  $patch_name — live file missing: $live"
    continue
  fi

  # Generate diff with relative paths
  diff_output=$(diff -u "$clean" "$live" 2>&1 | sed "1s|^--- .*|--- $rel_path|; 2s|^+++ .*|+++ $rel_path|") || true
  if [ -z "$diff_output" ]; then
    echo "  ⚠️  $patch_name — no diff (patch not applied to live?)"
  else
    echo "$diff_output" > "$PATCH_DIR/$patch_name"
    lines_added=$(grep -c '^+[^+]' "$PATCH_DIR/$patch_name" 2>/dev/null || echo 0)
    echo "  ✅ $patch_name — regenerated ($lines_added lines added)"
  fi
done

# --- Multi-file patch: 07-dream-model-override ---
DREAM_PATCH_FILES=("runtime/src/dream.ts" "runtime/src/task-scheduler.ts")
DREAM_PATCH_NAME="07-dream-model-override.patch"
DREAM_PATCH_OUTPUT=""
for rel_path in "${DREAM_PATCH_FILES[@]}"; do
  clean="$rel_path"
  live="$INSTALLED/$rel_path"
  if [ ! -f "$clean" ] || [ ! -f "$live" ]; then
    echo "  ⚠️  $DREAM_PATCH_NAME — missing: $rel_path"
    continue
  fi
  hunk=$(diff -u "$clean" "$live" 2>&1 | sed "1s|^--- .*|--- $rel_path|; 2s|^+++ .*|+++ $rel_path|" || true)
  if [ -n "$hunk" ]; then
    DREAM_PATCH_OUTPUT+="${hunk}
"
  fi
done
if [ -n "$DREAM_PATCH_OUTPUT" ]; then
  echo "$DREAM_PATCH_OUTPUT" > "$PATCH_DIR/$DREAM_PATCH_NAME"
  lines_added=$(grep -c '^+[^+]' "$PATCH_DIR/$DREAM_PATCH_NAME" 2>/dev/null || echo 0)
  echo "  ✅ $DREAM_PATCH_NAME — regenerated ($lines_added lines added, multi-file)"
else
  echo "  ⚠️  $DREAM_PATCH_NAME — no diff"
fi

echo ""
echo "[regen] Verifying regenerated patches apply cleanly..."
git checkout -- . 2>/dev/null
all_ok=true
for p in "$PATCH_DIR"/[0-9]*.patch; do
  [ -f "$p" ] || continue
  name="$(basename "$p")"
  if patch -p0 --dry-run --quiet < "$p" 2>/dev/null; then
    echo "  ✅ $name"
  else
    echo "  ❌ $name — FAILED"
    all_ok=false
  fi
done

if $all_ok; then
  echo "[regen] All patches verified ✅"
else
  echo "[regen] SOME PATCHES FAILED ❌ — manual intervention needed"
  exit 1
fi
