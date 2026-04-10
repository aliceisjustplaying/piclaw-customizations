#!/usr/bin/env bash
# Verify all patches apply cleanly to the latest piclaw source.
# Run this before any update to catch drift early.
set -euo pipefail

REPO_URL="https://github.com/rcarmo/piclaw.git"
PATCH_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "[verify-patches] Cloning latest source..."
git clone --depth=1 --quiet "$REPO_URL" "$WORK_DIR/piclaw"

cd "$WORK_DIR/piclaw"
all_ok=true
for p in "$PATCH_DIR"/[0-9]*.patch; do
  [ -f "$p" ] || continue
  name="$(basename "$p")"
  if sed 's/\.orig\t/\t/g; s/\.bak\t/\t/g' "$p" | patch -p0 --dry-run --quiet 2>/dev/null; then
    echo "  ✅ $name"
  else
    echo "  ❌ $name — FAILED to apply"
    sed 's/\.orig\t/\t/g; s/\.bak\t/\t/g' "$p" | patch -p0 --dry-run 2>&1 | head -5
    all_ok=false
  fi
done

if $all_ok; then
  echo "[verify-patches] All patches clean ✅"
  exit 0
else
  echo "[verify-patches] SOME PATCHES FAILED ❌"
  exit 1
fi
