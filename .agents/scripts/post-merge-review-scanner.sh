#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# post-merge-review-scanner.sh — Scan merged PRs for unactioned review bot feedback
#
# Finds actionable suggestions from AI review bots (CodeRabbit, Gemini Code
# Assist, claude-review, gpt-review) on recently merged PRs and creates
# GitHub issues for follow-up. Idempotent — skips PRs with existing issues.
#
# Issue bodies are worker-actionable per the t1901 mandatory rule: each
# includes file:line refs, a Worker Guidance section, and direct links to
# the inline review comments. Workers must be able to fix the issue without
# re-fetching the source PR's review API.
#
# Usage: post-merge-review-scanner.sh {scan|dry-run|help} [REPO]
# Env:   SCANNER_DAYS (default 7), SCANNER_MAX_ISSUES (default 10),
#        SCANNER_LABEL (default review-followup),
#        SCANNER_PR_LIMIT (default 1000),
#        SCANNER_MAX_COMMENTS (default 10) — cap per issue body,
#        SCANNER_NEEDS_REVIEW (default true) — apply needs-maintainer-review
#          label so workers do not auto-dispatch on unverified bot findings;
#          set to "false" to allow direct dispatch.
#
# Why needs-maintainer-review by default (GH#18538 follow-up to PR #18607):
# PR #18607 made the issue body worker-actionable (file:line refs, full bot
# bodies, Worker Guidance), but rich body context cannot rescue a finding
# whose factual premise is wrong. The original #18538 was triggered by a
# Gemini comment claiming the TODO.md "Ready" section is auto-generated
# (it is not — todo-ready.sh is read-only). A worker reading even a
# perfectly-mentored body would still chase a false premise. Routing every
# review-followup through human triage at creation time means the
# maintainer either (a) verifies the premise and removes the label, (b)
# closes as won't-fix with rationale, or (c) reframes the scope before
# dispatch. This pairs with #18607's body work — together they turn 0
# wasted dispatches per false-premise finding instead of #18538's 2.
#
# Prior art for the false-premise risk: prompts/build.txt section 6a
# (AI-generated issue quality, GH#17832-17835).
#
# t1386: https://github.com/marcusquinn/aidevops/issues/2785
# GH#18538: workers timed out on review-followup issues with truncated bodies.
set -euo pipefail

# Source shared-constants for gh_create_issue wrapper (t1756)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"

SCANNER_DAYS="${SCANNER_DAYS:-7}"
SCANNER_MAX_ISSUES="${SCANNER_MAX_ISSUES:-10}"
SCANNER_LABEL="${SCANNER_LABEL:-review-followup}"
SCANNER_PR_LIMIT="${SCANNER_PR_LIMIT:-1000}"
SCANNER_MAX_COMMENTS="${SCANNER_MAX_COMMENTS:-10}"
SCANNER_NEEDS_REVIEW="${SCANNER_NEEDS_REVIEW:-true}"
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

# Fetch inline review comments and format each as a markdown block. Each
# block includes the bot login, file:line, a direct link to the comment, and
# the full body (capped at 2000 chars) as a markdown blockquote so workers
# can read the bot's full reasoning without re-fetching the API.
fetch_inline_comments_md() {
	local repo="$1" pr="$2"
	gh api "repos/${repo}/pulls/${pr}/comments" --paginate 2>/dev/null |
		jq -r --arg bots "$BOT_RE" --arg acts "$ACT_RE" --argjson cap "$SCANNER_MAX_COMMENTS" '
			[.[]
				| select((.user.login // "") | test($bots; "i"))
				| select((.body // "") | test($acts; "i"))
			]
			| if length == 0 then "" else
				.[:$cap] | map(
					"#### \(.user.login) on `\(.path // "<no path>"):\(.line // .original_line // "?")`\n\n"
					+ "[View inline comment](\(.html_url))\n\n"
					+ ((.body // "")[:2000] | split("\n") | map("> " + .) | join("\n"))
					+ "\n"
				) | join("\n")
			end
		' 2>/dev/null || true
}

# Fetch top-level PR review summaries (Gemini's "Code Review" body, etc.)
# and format each as a markdown block. Same shape as inline comments but
# without file:line refs.
fetch_review_summaries_md() {
	local repo="$1" pr="$2"
	gh api "repos/${repo}/pulls/${pr}/reviews" --paginate 2>/dev/null |
		jq -r --arg bots "$BOT_RE" --arg acts "$ACT_RE" --argjson cap "$SCANNER_MAX_COMMENTS" '
			[.[]
				| select((.user.login // "") | test($bots; "i"))
				| select((.body // "") | length > 0)
				| select((.body // "") | test($acts; "i"))
			]
			| if length == 0 then "" else
				.[:$cap] | map(
					"#### \(.user.login) review summary\n\n"
					+ "[View review](\(.html_url))\n\n"
					+ ((.body // "")[:2000] | split("\n") | map("> " + .) | join("\n"))
					+ "\n"
				) | join("\n")
			end
		' 2>/dev/null || true
}

# Deduped list of `path:line` refs from inline comments, formatted as a
# markdown bullet list. Used in the Worker Guidance section so workers can
# see the full set of files to read at a glance.
fetch_file_refs_md() {
	local repo="$1" pr="$2"
	gh api "repos/${repo}/pulls/${pr}/comments" --paginate 2>/dev/null |
		jq -r --arg bots "$BOT_RE" --arg acts "$ACT_RE" '
			[.[]
				| select((.user.login // "") | test($bots; "i"))
				| select((.body // "") | test($acts; "i"))
				| select(.path != null)
				| "- `\(.path):\(.line // .original_line // "?")`"
			] | unique | .[]
		' 2>/dev/null || true
}

# Build a worker-actionable issue body for a PR's unaddressed bot feedback.
# Returns 1 (and prints nothing) if there's no actionable content.
build_pr_followup_body() {
	local repo="$1" pr="$2"
	local inline review file_refs refs_section
	inline=$(fetch_inline_comments_md "$repo" "$pr")
	review=$(fetch_review_summaries_md "$repo" "$pr")
	file_refs=$(fetch_file_refs_md "$repo" "$pr")

	if [[ -z "$inline" && -z "$review" ]]; then
		return 1
	fi

	if [[ -n "$file_refs" ]]; then
		refs_section="$file_refs"
	else
		refs_section="- _(No file paths in inline comments — see PR review summaries below for context)_"
	fi

	cat <<MD
## Unaddressed review bot suggestions

PR #${pr} was merged with unaddressed review bot feedback. Each comment
below includes its file path, line number, and a direct link to the
inline review comment. Read the relevant lines, decide whether the
suggestion is correct, and either apply the fix or close this issue
with a wontfix rationale.

**Source PR:** https://github.com/${repo}/pull/${pr}

---

### Triage required (read before dispatching a worker)

This issue is **auto-created from review bot output**. Review bots can be
wrong: hallucinated line refs, false premises about codebase structure,
template-driven sweeps without measurements (see GH#17832-17835 for prior
art and \`prompts/build.txt\` section 6a). The \`needs-maintainer-review\`
label gates this issue from worker auto-dispatch until a human verifies
the bot's premise against the actual code.

Pick one path:

1. **Accept** — verify the bot is right by reading the cited file:line in
   the source PR. Confirm the suggested change makes sense in context.
   Optionally tighten the Worker Guidance section below for the dispatched
   worker. Then remove \`needs-maintainer-review\` and add a tier label
   (\`tier:simple\` / \`tier:standard\` / \`tier:reasoning\`).
2. **Reject** — comment with the falsified premise (e.g. "section X is
   not auto-generated, finding is wrong") and close the issue. Optionally
   file a meta-issue if the bot is producing systemic noise from a
   specific rule.
3. **Modify scope** — edit title and body to reframe (e.g. "this finding
   on file X is wrong, but it surfaced a real issue on file Y"). Then
   follow path 1.

Workers dispatched against an unverified premise burn tokens on
exploration and stale-recover via the t2008 fail-safe — that path works
but is wasteful.

### Worker Guidance

**Files to modify:**

${refs_section}

**Implementation steps:**

1. Read each file at the specified \`:line\` (read ~20 lines around for context).
2. Read the bot's full comment below — it contains the rationale and suggested change.
3. Apply the change if it's correct. If you disagree, close this issue with an explanation rather than burning iterations trying to satisfy a wrong suggestion.
4. If multiple comments target the same file, group your edits into one logical commit.
5. Run \`shellcheck\` / \`markdownlint-cli2\` / project tests as appropriate.

**Verification:**

- Open the new PR with \`Resolves #<this-issue>\` so this followup is auto-closed on merge.
- If the bot's suggestion was incorrect, leave a comment on this issue explaining why before closing — that comment trains the next session reading this thread.

### Inline comments

${inline:-_(none)_}

### PR review summaries

${review:-_(none)_}
MD
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
	local repo="$1" pr="$2" pr_title="$3" body="$4" dry_run="$5"
	local title="Review followup: PR #${pr} — ${pr_title}"
	if [[ "$dry_run" == "true" ]]; then
		log "[DRY-RUN] Would create: $title"
		log "[DRY-RUN] Body length: ${#body} chars"
		return 0
	fi
	gh label create "$SCANNER_LABEL" --repo "$repo" \
		--description "Unaddressed review bot feedback" --color "D4C5F9" || true
	gh label create "source:review-scanner" --repo "$repo" \
		--description "Auto-created by post-merge-review-scanner.sh" --color "C2E0C6" --force || true

	# GH#18538: gate worker dispatch on human triage by default. Bot
	# findings can have false premises that no amount of body context
	# rescues. The maintainer either approves (removes label, adds tier),
	# rejects (closes), or reframes scope before any worker runs.
	#
	# GH#18670 (Fix 7): hardcode origin:worker here as defence in depth
	# against pulse-wrapper.sh forgetting to export AIDEVOPS_HEADLESS=true
	# OR against this script being invoked directly from a dev shell
	# (test runs, manual triage). gh_create_issue deduplicates labels
	# server-side so there is no harm if session_origin_label() also
	# produces origin:worker. The hardcoding is a source-of-truth
	# assertion: this scanner is by definition pulse-only output and
	# should never ship origin:interactive regardless of caller context.
	local label_list="$SCANNER_LABEL,source:review-scanner,origin:worker"
	if [[ "$SCANNER_NEEDS_REVIEW" == "true" ]]; then
		gh label create "needs-maintainer-review" --repo "$repo" \
			--description "Requires human triage before worker dispatch" \
			--color "B60205" || true
		label_list="${label_list},needs-maintainer-review"
	fi

	# Append signature footer
	local sig_footer="" sig_helper
	sig_helper="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/gh-signature-helper.sh"
	if [[ -x "$sig_helper" ]]; then
		sig_footer=$("$sig_helper" footer 2>/dev/null || echo "")
	fi

	gh_create_issue --repo "$repo" --title "$title" \
		--label "$label_list" \
		--body "${body}${sig_footer}"
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
		local body
		body=$(build_pr_followup_body "$repo" "$pr") || {
			log "PR #${pr}: no actionable bot feedback, skip"
			continue
		}
		local pr_title
		pr_title=$(gh pr view "$pr" --repo "$repo" --json title --jq '.title' || echo "Unknown")
		log "PR #${pr}: creating issue"
		create_issue "$repo" "$pr" "$pr_title" "$body" "$dry_run"
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
