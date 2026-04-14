#!/usr/bin/env bash
# Watch tracked upstream PRs for active patches.
# Intended for frequent polling. When a tracked PR transitions to merged,
# this script reruns audit-upstream.sh so the patch stack can be retired/refreshed promptly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_FILE="${SCRIPT_DIR}/manifest.json"
STATE_FILE="${SCRIPT_DIR}/.state/upstream-pr-watch-state.json"
RUN_AUDIT_ON_MERGE=1
PRINT_JSON=0

usage() {
	cat <<'EOF'
Usage: watch-upstream-prs.sh [--manifest PATH] [--state-file PATH] [--no-audit] [--json]

Options:
  --manifest PATH    Patch metadata manifest (default: patches/manifest.json)
  --state-file PATH  Persist watcher state here (default: patches/.state/upstream-pr-watch-state.json)
  --no-audit         Do not run audit-upstream.sh after merge transitions
  --json             Print the resulting watcher state JSON to stdout
  -h, --help         Show this help text
EOF
}

while [ "$#" -gt 0 ]; do
	case "$1" in
	--manifest)
		MANIFEST_FILE="$2"
		shift 2
		;;
	--state-file)
		STATE_FILE="$2"
		shift 2
		;;
	--no-audit)
		RUN_AUDIT_ON_MERGE=0
		shift
		;;
	--json)
		PRINT_JSON=1
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		echo "[watch-upstream-prs] ERROR: unknown argument: $1" >&2
		usage >&2
		exit 1
		;;
	esac
done

require_command() {
	if ! command -v "$1" >/dev/null 2>&1; then
		echo "[watch-upstream-prs] ERROR: required command not found: $1" >&2
		exit 1
	fi
}

require_command curl
require_command jq

if [ ! -f "$MANIFEST_FILE" ]; then
	echo "[watch-upstream-prs] ERROR: manifest not found: $MANIFEST_FILE" >&2
	exit 1
fi

mkdir -p "$(dirname "$STATE_FILE")"
WORK_DIR="$(mktemp -d)"
RESULTS_NDJSON="$WORK_DIR/results.ndjson"
NEXT_STATE="$WORK_DIR/state.json"
PREVIOUS_STATE_FILE="$WORK_DIR/previous-state.json"
trap 'rm -rf "$WORK_DIR"' EXIT

if [ -f "$STATE_FILE" ]; then
	cp "$STATE_FILE" "$PREVIOUS_STATE_FILE"
else
	printf '{"version":1,"entries":[]}\n' >"$PREVIOUS_STATE_FILE"
fi

GITHUB_REPO="$(jq -r '.github_repo // empty' "$MANIFEST_FILE")"
if [ -z "$GITHUB_REPO" ]; then
	echo "[watch-upstream-prs] ERROR: manifest is missing github_repo" >&2
	exit 1
fi

mapfile -t TRACKED_ROWS < <(
	jq -r '
    .patches
    | to_entries[]
    | select((.value.track_upstream // false) == true)
    | .key as $number
    | (.value.name // ("patch-" + $number)) as $name
    | (.value.upstream_prs // [])[]?
    | [$number, $name, tostring] | @tsv
  ' "$MANIFEST_FILE"
)

if [ "${#TRACKED_ROWS[@]}" -eq 0 ]; then
	echo "[watch-upstream-prs] No tracked upstream PRs configured."
	jq -n \
		--arg checked_at "$(date -Iseconds)" \
		--arg repo "$GITHUB_REPO" \
		'{version:1,checked_at:$checked_at,repo:$repo,entries:[]}' |
		tee "$STATE_FILE" >/dev/null
	if [ "$PRINT_JSON" -eq 1 ]; then
		cat "$STATE_FILE"
	fi
	exit 0
fi

AUTH_HEADER=()
if [ -n "${GITHUB_TOKEN:-}" ]; then
	AUTH_HEADER=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
elif [ -n "${GITHUB_PICLAW_BOT_PAT:-}" ]; then
	AUTH_HEADER=(-H "Authorization: Bearer ${GITHUB_PICLAW_BOT_PAT}")
fi

checked_at="$(date -Iseconds)"
merged_changes=0
other_changes=0

fetch_pr() {
	local pr_number="$1"
	curl -fsSL \
		-H 'Accept: application/vnd.github+json' \
		-H 'X-GitHub-Api-Version: 2022-11-28' \
		"${AUTH_HEADER[@]}" \
		"https://api.github.com/repos/${GITHUB_REPO}/pulls/${pr_number}"
}

echo "[watch-upstream-prs] Checking tracked PRs for ${GITHUB_REPO}..."
for row in "${TRACKED_ROWS[@]}"; do
	patch_number="${row%%$'\t'*}"
	rest="${row#*$'\t'}"
	patch_name="${rest%%$'\t'*}"
	pr_number="${rest##*$'\t'}"

	pr_json="$(fetch_pr "$pr_number")"
	pr_state="$(jq -r '.state // "unknown"' <<<"$pr_json")"
	merged_at="$(jq -r '.merged_at // empty' <<<"$pr_json")"
	title="$(jq -r '.title // empty' <<<"$pr_json")"
	url="$(jq -r '.html_url // empty' <<<"$pr_json")"
	merge_commit_sha="$(jq -r '.merge_commit_sha // empty' <<<"$pr_json")"

	previous_merged_at="$(jq -r --arg patch_number "$patch_number" --arg pr "$pr_number" '.entries[]? | select(.patch_number == $patch_number and (.pr|tostring) == $pr) | .merged_at // empty' "$PREVIOUS_STATE_FILE")"
	previous_state="$(jq -r --arg patch_number "$patch_number" --arg pr "$pr_number" '.entries[]? | select(.patch_number == $patch_number and (.pr|tostring) == $pr) | .state // empty' "$PREVIOUS_STATE_FILE")"

	changed=0
	change_summary=""
	if [ "$previous_state" != "$pr_state" ]; then
		changed=1
		change_summary="state ${previous_state:-unknown} -> ${pr_state}"
		other_changes=$((other_changes + 1))
	fi
	if [ -z "$previous_merged_at" ] && [ -n "$merged_at" ]; then
		changed=1
		change_summary="merged"
		merged_changes=$((merged_changes + 1))
	fi

	if [ -n "$merged_at" ]; then
		echo "  ⬆️ patch ${patch_number} / PR #${pr_number} — merged${title:+: ${title}}"
	else
		echo "  👀 patch ${patch_number} / PR #${pr_number} — ${pr_state}${title:+: ${title}}"
	fi

	jq -cn \
		--arg patch_number "$patch_number" \
		--arg patch_name "$patch_name" \
		--argjson pr "$pr_number" \
		--arg state "$pr_state" \
		--arg merged_at "$merged_at" \
		--arg title "$title" \
		--arg url "$url" \
		--arg merge_commit_sha "$merge_commit_sha" \
		--arg previous_state "$previous_state" \
		--arg previous_merged_at "$previous_merged_at" \
		--arg change_summary "$change_summary" \
		--argjson changed "$changed" \
		'{
      patch_number: $patch_number,
      patch_name: $patch_name,
      pr: $pr,
      state: $state,
      merged_at: (if $merged_at == "" then null else $merged_at end),
      title: (if $title == "" then null else $title end),
      url: (if $url == "" then null else $url end),
      merge_commit_sha: (if $merge_commit_sha == "" then null else $merge_commit_sha end),
      previous_state: (if $previous_state == "" then null else $previous_state end),
      previous_merged_at: (if $previous_merged_at == "" then null else $previous_merged_at end),
      changed: ($changed == 1),
      change_summary: (if $change_summary == "" then null else $change_summary end)
    }' >>"$RESULTS_NDJSON"
done

jq -s \
	--arg checked_at "$checked_at" \
	--arg repo "$GITHUB_REPO" \
	'{version:1,checked_at:$checked_at,repo:$repo,entries:.}' \
	"$RESULTS_NDJSON" >"$NEXT_STATE"
mv "$NEXT_STATE" "$STATE_FILE"

if [ "$other_changes" -gt 0 ]; then
	echo "[watch-upstream-prs] PR state changes detected: $other_changes"
	jq -r '.entries[] | select(.changed) | "  - patch \(.patch_number) / PR #\(.pr): \(.change_summary // "changed")"' "$STATE_FILE"
fi

if [ "$PRINT_JSON" -eq 1 ]; then
	cat "$STATE_FILE"
fi

if [ "$merged_changes" -gt 0 ] && [ "$RUN_AUDIT_ON_MERGE" -eq 1 ]; then
	echo "[watch-upstream-prs] Merge transition detected; running audit-upstream.sh"
	"${SCRIPT_DIR}/audit-upstream.sh"
fi

exit 0
