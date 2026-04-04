#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# post-merge-review-scanner.sh — Scan merged PRs for unactioned review bot feedback
#
# Finds actionable suggestions from AI review bots (CodeRabbit, Gemini Code
# Assist, claude-review, gpt-review) on recently merged PRs and creates
# GitHub issues for follow-up. Idempotent — skips PRs with existing issues.
#
# Usage: post-merge-review-scanner.sh {scan|dry-run|help} [REPO]
# Env:   SCANNER_DAYS (default 7), SCANNER_MAX_ISSUES (default 10),
#        SCANNER_LABEL (default review-followup),
#        SCANNER_PR_LIMIT (default 1000)
#
# t1386: https://github.com/marcusquinn/aidevops/issues/2785
set -euo pipefail

# Source shared-constants for gh_create_issue wrapper (t1756)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"

SCANNER_DAYS="${SCANNER_DAYS:-7}"
SCANNER_MAX_ISSUES="${SCANNER_MAX_ISSUES:-10}"
SCANNER_LABEL="${SCANNER_LABEL:-review-followup}"
SCANNER_PR_LIMIT="${SCANNER_PR_LIMIT:-1000}"
BOT_RE="coderabbitai|gemini-code-assist|claude-review|gpt-review"
ACT_RE="should|consider|fix|change|update|refactor|missing|add"

log() { echo "[scanner] $*" >&2; }

get_lookback_date() {
	local days="$1"
	if date --version >/dev/null 2>&1; then
		date -d "${days} days ago" -u +%Y-%m-%dT%H:%M:%SZ
	else
		date -u -v-"${days}"d +%Y-%m-%dT%H:%M:%SZ
	fi
}

# Fetch actionable bot comments for a PR. Output: "bot|path|snippet" per line.
fetch_actionable() {
	local repo="$1" pr="$2"
	local jq_f='[.[] | select((.user.login // "") | test("'"$BOT_RE"'";"i"))
		| select((.body // "") | test("'"$ACT_RE"'";"i"))
		| "\((.user.login // ""))|\(.path // "")|\((.body // "") | gsub("\n";" ") | .[:200])"] | .[]'
	{ gh api "repos/${repo}/pulls/${pr}/comments" --paginate || echo '[]'; } |
		jq -r "$jq_f"
	local jq_r='[.[] | select((.user.login // "") | test("'"$BOT_RE"'";"i"))
		| select((.body // "") | test("'"$ACT_RE"'";"i"))
		| "\((.user.login // ""))||\((.body // "") | gsub("\n";" ") | .[:200])"] | .[]'
	{ gh api "repos/${repo}/pulls/${pr}/reviews" --paginate || echo '[]'; } |
		jq -r "$jq_r"
}

issue_exists() {
	local repo="$1" pr="$2" count
	local title_query="Review followup: PR #${pr} —"
	count=$(gh issue list --repo "$repo" --label "$SCANNER_LABEL" \
		--search "in:title \"${title_query}\"" --state all --limit 100 \
		--json number --jq 'length' || echo "0")
	[[ "$count" -gt 0 ]]
}

create_issue() {
	local repo="$1" pr="$2" pr_title="$3" summary="$4" dry_run="$5"
	local title="Review followup: PR #${pr} — ${pr_title}"
	if [[ "$dry_run" == "true" ]]; then
		log "[DRY-RUN] Would create: $title"
		return 0
	fi
	gh label create "$SCANNER_LABEL" --repo "$repo" \
		--description "Unaddressed review bot feedback" --color "D4C5F9" || true
	gh label create "source:review-scanner" --repo "$repo" \
		--description "Auto-created by post-merge-review-scanner.sh" --color "C2E0C6" --force || true
	local body
	# Build signature footer
	local sig_footer=""
	local sig_helper
	sig_helper="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/gh-signature-helper.sh"
	if [[ -x "$sig_helper" ]]; then
		sig_footer=$("$sig_helper" footer 2>/dev/null || echo "")
	fi

	body="## Unaddressed review bot suggestions

PR #${pr} was merged with unaddressed review bot feedback.
**Source PR:** https://github.com/${repo}/pull/${pr}

### Actionable comments

${summary}${sig_footer}"
	gh_create_issue --repo "$repo" --title "$title" --label "$SCANNER_LABEL,source:review-scanner" --body "$body"
}

do_scan() {
	local repo="$1" dry_run="$2" since_date
	since_date=$(get_lookback_date "$SCANNER_DAYS")
	log "Scanning ${repo} since ${since_date} (${SCANNER_DAYS}d)"
	local pr_numbers
	pr_numbers=$(gh pr list --state merged --search "merged:>${since_date}" \
		--repo "$repo" --limit "$SCANNER_PR_LIMIT" --json number --jq '.[].number' || echo "")
	if [[ -z "$pr_numbers" ]]; then
		log "No merged PRs found"
		return 0
	fi
	local issues_created=0
	while IFS= read -r pr; do
		[[ -z "$pr" ]] && continue
		if [[ "$issues_created" -ge "$SCANNER_MAX_ISSUES" ]]; then
			log "Max issues reached (${SCANNER_MAX_ISSUES})"
			break
		fi
		if issue_exists "$repo" "$pr"; then
			log "PR #${pr}: issue exists, skip"
			continue
		fi
		local hits
		hits=$(fetch_actionable "$repo" "$pr")
		[[ -z "$hits" ]] && continue
		local pr_title summary=""
		pr_title=$(gh pr view "$pr" --repo "$repo" --json title --jq '.title' || echo "Unknown")
		while IFS='|' read -r bot path snippet; do
			local ref=""
			[[ -n "$path" ]] && ref=" (\`${path}\`)"
			printf -v summary '%s- **%s**%s: %s...\n' "$summary" "$bot" "$ref" "$snippet"
		done <<<"$hits"
		[[ -z "$summary" ]] && continue
		log "PR #${pr}: creating issue"
		create_issue "$repo" "$pr" "$pr_title" "$summary" "$dry_run"
		issues_created=$((issues_created + 1))
	done <<<"$pr_numbers"
	log "Done. Issues created: ${issues_created}"
	return 0
}

main() {
	local command="${1:-}" repo="${2:-}"
	if [[ -z "$command" ]]; then
		echo "Usage: $(basename "$0") {scan|dry-run|help} [REPO]"
		return 2
	fi
	if [[ -z "$repo" ]]; then
		repo=$(gh repo view --json nameWithOwner -q .nameWithOwner || echo "")
		[[ -z "$repo" ]] && {
			echo "ERROR: Cannot determine repo" >&2
			return 1
		}
	fi
	case "$command" in
	scan) do_scan "$repo" "false" ;;
	dry-run) do_scan "$repo" "true" ;;
	-h | --help | help) echo "Usage: $(basename "$0") {scan|dry-run|help} [REPO]" ;;
	*)
		echo "ERROR: Unknown command '$command'" >&2
		return 2
		;;
	esac
}

main "$@"
