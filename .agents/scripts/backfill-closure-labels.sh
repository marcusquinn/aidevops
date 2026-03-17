#!/usr/bin/env bash
# backfill-closure-labels.sh — Apply closure reason labels to existing closed issues
#
# Usage: bash backfill-closure-labels.sh [--repo owner/repo] [--dry-run] [--limit N]
#
# Scans closed issues missing closure reason labels and applies:
#   - duplicate: state_reason=not_planned + closing comment mentions duplicate
#   - already-fixed: closed with "already fixed/resolved/done" in comments
#   - not-planned: state_reason=not_planned (catch-all)
#   - wontfix: closing comment mentions wontfix/won't fix
#
# Issues with status:done (closed by merged PR) are skipped.
# t1533 — one-time backfill, safe to re-run (idempotent).

set -euo pipefail

_repo=""
_dry_run=false
_limit=500

while [[ $# -gt 0 ]]; do
	case "$1" in
	--repo)
		_repo="$2"
		shift 2
		;;
	--dry-run)
		_dry_run=true
		shift
		;;
	--limit)
		_limit="$2"
		shift 2
		;;
	*)
		echo "Unknown option: $1" >&2
		exit 1
		;;
	esac
done

if [[ -z "$_repo" ]]; then
	_repo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "")
	if [[ -z "$_repo" ]]; then
		echo "ERROR: Could not detect repo. Use --repo owner/repo" >&2
		exit 1
	fi
fi

echo "Backfilling closure reason labels for $_repo (limit: $_limit, dry-run: $_dry_run)"

# Ensure labels exist
if [[ "$_dry_run" == "false" ]]; then
	gh label create "not-planned" --repo "$_repo" --force --description "Closed without implementation — not planned" --color "ffffff" 2>/dev/null || true
	gh label create "already-fixed" --repo "$_repo" --force --description "Already fixed by another change" --color "e4e669" 2>/dev/null || true
	# duplicate and wontfix already exist as GitHub defaults
fi

_applied=0
_skipped=0
_page=1
_per_page=100

while [[ "$_applied" -lt "$_limit" && "$_skipped" -lt 2000 ]]; do
	# Fetch closed issues in batches
	_issues=$(gh api "repos/${_repo}/issues?state=closed&per_page=${_per_page}&page=${_page}&direction=desc" \
		--jq '.[] | {number, state_reason, title: .title[:80], labels: [.labels[].name]}' 2>/dev/null || echo "")

	if [[ -z "$_issues" ]]; then
		echo "No more issues to process (page $_page)"
		break
	fi

	# Process each issue (gh --jq '.[]' already outputs one JSON object per line)
	while IFS= read -r _issue; do
		[[ -z "$_issue" ]] && continue

		# Single jq call extracts all fields, NUL-delimited for robustness
		{
			IFS= read -r -d '' local_number
			IFS= read -r -d '' local_reason
			IFS= read -r -d '' local_title
			IFS= read -r -d '' local_labels
		} < <(jq -j -n --argjson issue "$_issue" '$issue | .number, "\u0000", (.state_reason // "completed"), "\u0000", .title, "\u0000", (.labels | join(",")), "\u0000"')

		# Skip if already has a closure reason label
		if echo "$local_labels" | grep -qE 'duplicate|not-planned|already-fixed|wontfix|status:done'; then
			_skipped=$((_skipped + 1))
			continue
		fi

		# Skip completed issues without fetching comments — only not_planned needs labelling
		# (completed issues are either status:done from PR merge, or manually closed as done)
		if [[ "$local_reason" == "completed" || "$local_reason" == "null" ]]; then
			_skipped=$((_skipped + 1))
			continue
		fi

		# Determine label — only not_planned issues reach here
		local_label=""
		local_comment=$(gh api "repos/${_repo}/issues/${local_number}/comments" \
			--jq 'last | .body // ""' 2>/dev/null || echo "")

		if echo "$local_comment" | grep -qiE 'duplicate|dupe|already exists'; then
			local_label="duplicate"
		elif echo "$local_comment" | grep -qiE 'already.*(fixed|resolved|done|merged|implemented)'; then
			local_label="already-fixed"
		elif echo "$local_comment" | grep -qiE 'wontfix|won'\''t fix|will not'; then
			local_label="wontfix"
		else
			local_label="not-planned"
		fi

		if [[ -n "$local_label" ]]; then
			if [[ "$_dry_run" == "true" ]]; then
				echo "[DRY-RUN] #$local_number ($local_reason) -> $local_label — $local_title"
			else
				gh issue edit "$local_number" --repo "$_repo" --add-label "$local_label" 2>/dev/null || true
				echo "#$local_number ($local_reason) -> $local_label — $local_title"
			fi
			_applied=$((_applied + 1))
		else
			_skipped=$((_skipped + 1))
		fi

		# Rate limit: gentle on API
		sleep 0.3

	done <<<"$_issues"

	_page=$((_page + 1))
done

echo ""
echo "Done. Applied: $_applied, Skipped: $_skipped"
exit 0
