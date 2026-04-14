#!/usr/bin/env bash
# Audit active patches against upstream PiClaw.
# Classifies each active patch as:
#   - needed: forward apply works on the current simulated stack
#   - upstreamed: reverse apply works (retire candidate)
#   - drifted: neither direction works
#   - blocked: a previous patch drifted, so later classifications would be unreliable
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_URL="https://github.com/rcarmo/piclaw.git"
UPSTREAM_REF="main"
STATE_FILE="${SCRIPT_DIR}/.state/upstream-audit-state.json"
PRINT_JSON=0

usage() {
  cat <<'EOF'
Usage: audit-upstream.sh [--repo-url URL] [--ref REF] [--state-file PATH] [--json]

Options:
  --repo-url URL     Override upstream repo URL (default: https://github.com/rcarmo/piclaw.git)
  --ref REF          Upstream branch or ref to audit (default: main)
  --state-file PATH  Persist audit state here (default: patches/.state/upstream-audit-state.json)
  --json             Print the resulting state JSON to stdout
  -h, --help         Show this help text
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo-url)
      REPO_URL="$2"
      shift 2
      ;;
    --ref)
      UPSTREAM_REF="$2"
      shift 2
      ;;
    --state-file)
      STATE_FILE="$2"
      shift 2
      ;;
    --json)
      PRINT_JSON=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[audit-upstream] ERROR: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "[audit-upstream] ERROR: required command not found: $1" >&2
    exit 1
  fi
}

require_command git
require_command jq

mkdir -p "$(dirname "$STATE_FILE")"

patch_strip_level() {
  local patch_file="$1"
  if grep -qE '^(diff --git a/|--- a/)' "$patch_file"; then
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
  strip_level="$(patch_strip_level "$patch_file")"
  git -C "$repo_dir" apply -p"$strip_level" --recount --unidiff-zero "$@" "$patch_file"
}

WORK_DIR="$(mktemp -d)"
RESULTS_NDJSON="$WORK_DIR/results.ndjson"
RESULTS_JSON="$WORK_DIR/results.json"
NEXT_STATE="$WORK_DIR/state.json"
PREVIOUS_STATE_FILE="$WORK_DIR/previous-state.json"
trap 'rm -rf "$WORK_DIR"' EXIT

if [ -f "$STATE_FILE" ]; then
  cp "$STATE_FILE" "$PREVIOUS_STATE_FILE"
else
  printf '{"version":1,"patches":[]}\n' > "$PREVIOUS_STATE_FILE"
fi

printf '[audit-upstream] Cloning %s#%s...\n' "$REPO_URL" "$UPSTREAM_REF"
git clone --depth=1 --branch "$UPSTREAM_REF" --quiet "$REPO_URL" "$WORK_DIR/piclaw"
REPO_DIR="$WORK_DIR/piclaw"
UPSTREAM_SHA="$(git -C "$REPO_DIR" rev-parse --short HEAD)"
AUDITED_AT="$(date -Iseconds)"
printf '[audit-upstream] Upstream HEAD: %s\n' "$UPSTREAM_SHA"

mapfile -t PATCH_FILES < <(find "$SCRIPT_DIR" -maxdepth 1 -type f -name '[0-9][0-9]-*.patch' | sort)
if [ "${#PATCH_FILES[@]}" -eq 0 ]; then
  echo "[audit-upstream] No active patches found."
  jq -n \
    --arg audited_at "$AUDITED_AT" \
    --arg upstream_ref "$UPSTREAM_REF" \
    --arg upstream_sha "$UPSTREAM_SHA" \
    '{version:1,audited_at:$audited_at,upstream_ref:$upstream_ref,upstream_sha:$upstream_sha,patches:[]}' \
    | tee "$STATE_FILE" >/dev/null
  exit 0
fi

blocked_by=""
drift_count=0
upstreamed_count=0
needed_count=0
blocked_count=0

for patch_path in "${PATCH_FILES[@]}"; do
  patch_name="$(basename "$patch_path")"
  patch_number="${patch_name%%-*}"
  previous_status="$(jq -r --arg patch "$patch_name" '.patches[]? | select(.patch == $patch) | .status // empty' "$PREVIOUS_STATE_FILE")"
  tracked_prs_json='[]'
  track_upstream='false'
  patch_label="$patch_name"
  if [ -f "$SCRIPT_DIR/manifest.json" ]; then
    tracked_prs_json="$(jq -c --arg number "$patch_number" '.patches[$number].upstream_prs // []' "$SCRIPT_DIR/manifest.json")"
    track_upstream="$(jq -r --arg number "$patch_number" '.patches[$number].track_upstream // false' "$SCRIPT_DIR/manifest.json")"
    patch_label="$(jq -r --arg number "$patch_number" '.patches[$number].name // empty' "$SCRIPT_DIR/manifest.json")"
    if [ -z "$patch_label" ] || [ "$patch_label" = "null" ]; then
      patch_label="$patch_name"
    fi
  fi

  if [ -n "$blocked_by" ]; then
    status="blocked"
    detail="blocked by earlier drifted patch ${blocked_by}"
    blocked_count=$((blocked_count + 1))
    icon="⏭️"
  elif git_apply_patch "$REPO_DIR" "$patch_path" --check >/dev/null 2>&1; then
    status="needed"
    detail="forward apply clean"
    git_apply_patch "$REPO_DIR" "$patch_path" >/dev/null
    needed_count=$((needed_count + 1))
    icon="✅"
  elif git_apply_patch "$REPO_DIR" "$patch_path" --reverse --check >/dev/null 2>&1; then
    status="upstreamed"
    detail="reverse apply clean; retire candidate"
    upstreamed_count=$((upstreamed_count + 1))
    icon="⬆️"
  else
    status="drifted"
    detail="neither forward nor reverse apply clean"
    blocked_by="$patch_name"
    drift_count=$((drift_count + 1))
    icon="❌"
  fi

  changed=0
  if [ -n "$previous_status" ] && [ "$previous_status" != "$status" ]; then
    changed=1
  fi

  printf '  %s %s — %s\n' "$icon" "$patch_name" "$detail"

  jq -cn \
    --arg patch "$patch_name" \
    --arg number "$patch_number" \
    --arg label "$patch_label" \
    --arg status "$status" \
    --arg detail "$detail" \
    --arg previous_status "$previous_status" \
    --argjson changed "$changed" \
    --argjson track_upstream "$track_upstream" \
    --argjson tracked_prs "$tracked_prs_json" \
    '{
      patch: $patch,
      number: $number,
      label: $label,
      status: $status,
      detail: $detail,
      previous_status: (if $previous_status == "" then null else $previous_status end),
      changed: ($changed == 1),
      track_upstream: $track_upstream,
      tracked_prs: $tracked_prs
    }' >> "$RESULTS_NDJSON"
done

jq -s \
  --arg audited_at "$AUDITED_AT" \
  --arg upstream_ref "$UPSTREAM_REF" \
  --arg upstream_sha "$UPSTREAM_SHA" \
  '{version:1,audited_at:$audited_at,upstream_ref:$upstream_ref,upstream_sha:$upstream_sha,patches:.}' \
  "$RESULTS_NDJSON" > "$RESULTS_JSON"
cp "$RESULTS_JSON" "$NEXT_STATE"
mv "$NEXT_STATE" "$STATE_FILE"

changed_count="$(jq '[.patches[] | select(.changed)] | length' "$STATE_FILE")"
printf '[audit-upstream] Summary: %s needed, %s upstreamed, %s drifted, %s blocked\n' \
  "$needed_count" "$upstreamed_count" "$drift_count" "$blocked_count"

if [ "$changed_count" -gt 0 ]; then
  echo "[audit-upstream] Status changes:"
  jq -r '.patches[] | select(.changed) | "  - \(.patch): \(.previous_status) -> \(.status)"' "$STATE_FILE"
fi

if [ "$PRINT_JSON" -eq 1 ]; then
  cat "$STATE_FILE"
fi

if [ "$drift_count" -gt 0 ] || [ "$blocked_count" -gt 0 ]; then
  exit 3
fi

exit 0
