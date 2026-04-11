#!/usr/bin/env bash
# patches/post-install/01-jiti-trynative-bun-runtime.sh
#
# Fix: jiti's tryNative must be false when running under Bun (not just
# compiled Bun binaries). Without this, Bun's native resolver handles
# imports before jiti can apply its alias map, breaking pi package
# extensions that import @mariozechner/* peer dependencies.
#
# This patch is idempotent — safe to run on every update.

set -euo pipefail

LOADER_PATHS=(
  /home/agent/.bun/install/global/node_modules/@mariozechner/pi-coding-agent/dist/core/extensions/loader.js
)

# Also patch any cached versions
for cached in /home/agent/.bun/install/cache/@mariozechner/pi-coding-agent@*/dist/core/extensions/loader.js; do
  [ -f "$cached" ] && LOADER_PATHS+=("$cached")
done

# Deduplicate by inode so hardlinked files are only patched once
declare -A seen_inodes
UNIQUE_PATHS=()
for p in "${LOADER_PATHS[@]}"; do
  [ -f "$p" ] || continue
  inode=$(stat -c '%i' "$p")
  if [ -z "${seen_inodes[$inode]:-}" ]; then
    seen_inodes[$inode]=1
    UNIQUE_PATHS+=("$p")
  fi
done

PATCHED=0
for loader in "${UNIQUE_PATHS[@]}"; do
  # Already patched?
  if grep -q 'isBunRuntime.*tryNative.*false.*alias.*getAliases' "$loader" 2>/dev/null; then
    echo "Already patched: $loader"
    continue
  fi

  # Original line (single-line, may have whitespace variations)
  if grep -q 'isBunBinary ? { virtualModules: VIRTUAL_MODULES, tryNative: false } : { alias: getAliases() }' "$loader"; then
    # sed -i can't write to root-owned dirs; use temp file + sudo mv
    tmp=$(mktemp)
    sed 's|isBunBinary ? { virtualModules: VIRTUAL_MODULES, tryNative: false } : { alias: getAliases() }|isBunBinary ? { virtualModules: VIRTUAL_MODULES, tryNative: false } : { alias: getAliases(), ...(isBunRuntime \&\& { tryNative: false }) }|' "$loader" > "$tmp"
    sudo cp --preserve=mode,ownership "$tmp" "$loader"
    rm -f "$tmp"
    echo "Patched: $loader"
    PATCHED=$((PATCHED + 1))
  else
    echo "WARNING: pattern not found in $loader — skipping (may need update for new pi-coding-agent version)"
  fi
done

echo "Done. Patched $PATCHED file(s)."
