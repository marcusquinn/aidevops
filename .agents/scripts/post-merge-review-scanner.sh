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
#        SCANNER_NEEDS_REVIEW (default false) — opt-in escape hatch to apply
#          needs-maintainer-review at creation time. Normally the worker
#          itself triages (verify premise → implement / close-wontfix /
#          escalate-with-recommendation), so this should stay off. Flip to
#          true only for pipelines where every bot finding genuinely needs
#          human sign-off before any automated action.
#
# Worker-is-triager philosophy (GH#18538):
#   A review-followup issue is not a human-only inbox item. The dispatched
#   worker IS the triager. It must:
#     1. Verify the bot's premise by reading the cited file:line.
#     2. If premise is falsified → close the issue with a rationale comment
#        explaining what the bot got wrong (this mentors the next session
#        reading the thread and trains the noise filter).
#     3. If premise is correct + fix is obvious → implement and open a PR
#        with `Resolves #NNN`.
#     4. ONLY if premise is correct but the approach requires a genuine
#        judgment call the worker cannot make (architecture / policy /
#        breaking change) → post a decision comment containing analysis,
#        a recommended path, and the specific question that needs input,
#        then apply needs-maintainer-review. The human reads a ready-to-
#        approve recommendation, not a blank triage task.
#
#   This is the same rule as prompts/build.txt "Reasoning responsibility":
#   the model does the thinking and delivers a recommendation. Applying
#   needs-maintainer-review unconditionally at creation time is that
#   anti-pattern at the dispatch layer — punting analysis to a human who
#   then just hands it back to an AI anyway. Original GH#18538 was caused
#   by a bot finding with a false premise (Gemini claimed TODO.md's
#   "## Ready" section is auto-generated; todo-ready.sh is read-only).
#   Under this model the worker reads the section header, greps the
#   helper, closes with "premise falsified — no write path exists" — done
#   in minutes, with zero human touches.
#
# Prior art for the false-premise risk: prompts/build.txt section 6a
# (AI-generated issue quality, GH#17832-17835). The prompts/build.txt
# principle "Reasoning responsibility" and AGENTS.md "origin:interactive
# implies maintainer approval" are both echoes of the same rule: humans
# approve decisions, they don't re-do analysis.
#
# t1386: https://github.com/marcusquinn/aidevops/issues/2785
# GH#18538: workers timed out on review-followup issues with truncated bodies.
# GH#18538 follow-up: worker-is-triager model replaces default-gate model.
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
SCANNER_NEEDS_REVIEW="${SCANNER_NEEDS_REVIEW:-false}"
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

### You are the triager (worker-is-triager rule)

This issue is **auto-created from review bot output** and dispatched
directly to you. Review bots can be wrong: hallucinated line refs, false
premises about codebase structure, template-driven sweeps without
measurements (see GH#17832-17835 for prior art and \`prompts/build.txt\`
section 6a). **Do not assume the bot is correct.** Verify before acting.

You must end in exactly one of three outcomes — no fourth "hand it back
to the human" path exists. Humans approve decisions; they do not re-do
analysis.

#### Outcome A — Premise falsified → close the issue

1. Read the cited \`file:line\` (listed under *Files to modify* below).
2. If the bot's claim is factually wrong (file doesn't exist at that
   line, function doesn't behave as described, "auto-generated" section
   isn't actually auto-generated, etc.), **close the issue** with a
   comment in this shape:

   > **Premise falsified.** \<what the bot claimed\>. \<what the code
   > actually shows, with a \`file:line\` citation or one-line quote\>.
   > Not acting.

   No PR. No further dispatch. The closing comment trains the next
   session reading this thread and the noise filter.

#### Outcome B — Premise correct + fix is obvious → implement and PR

1. Verify the bot's premise as above.
2. Read the Worker Guidance section below, open a worktree, implement.
3. Open a PR with \`Resolves #<this-issue-number>\` in the body
   (use THIS issue's number, not the source PR's) so merge auto-closes it.
4. Follow the normal Lifecycle Gate (brief, tests, review-bot-gate,
   merge, postflight).

#### Outcome C — Premise correct but approach is a genuine judgment call

Only use this path if you reach it after Outcomes A and B don't apply:
the bot's finding is real, but the fix requires a decision that is
architectural, policy, breaking-change, or otherwise genuinely outside
what you can resolve autonomously. In that case, post a **decision
comment** with exactly these fields:

- **Premise check:** one line, confirming the finding is real.
- **Analysis:** 2-4 bullets on the trade-offs.
- **Recommended path:** the option you would take if the decision were
  yours, with rationale.
- **Specific question:** the single decision the human needs to make
  (yes/no or pick-one, not open-ended).

Then apply \`needs-maintainer-review\` and stop. The human wakes up to a
ready-to-approve recommendation, not a blank task.

> **Ambiguity about scope or style is not Outcome C.** Per
> \`prompts/build.txt\` "Reasoning responsibility", the model does the
> thinking and delivers a recommendation. Only escalate what is genuinely
> a maintainer-only decision.

### Worker Guidance

**Files to modify:**

${refs_section}

**Implementation steps (Outcome B path):**

1. Read each file at the specified \`:line\` (read ~20 lines around for context).
2. Read the bot's full comment below — it contains the rationale and suggested change.
3. Verify the premise before implementing (see Outcome A).
4. If multiple comments target the same file, group edits into one logical commit.
5. Run \`shellcheck\` / \`markdownlint-cli2\` / project tests as appropriate.

**Verification:**

- Open the new PR with \`Resolves #<this-issue>\` so this followup is auto-closed on merge.
- If the bot's suggestion was incorrect, close this issue with a Outcome A comment — do not open a no-op PR.

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

	# GH#18538 follow-up: worker-is-triager model (see header comment).
	# The worker itself verifies the bot's premise and picks one of three
	# outcomes: close-as-falsified (Outcome A), implement-and-PR (B), or
	# escalate-with-recommendation (C). We do NOT apply
	# needs-maintainer-review unconditionally — that would be the exact
	# "punt analysis to a human who hands it back to an AI" anti-pattern
	# this script is meant to avoid. SCANNER_NEEDS_REVIEW is an opt-in
	# escape hatch; the worker guidance inside the issue body carries the
	# enforcement.
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
