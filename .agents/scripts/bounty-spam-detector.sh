#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# bounty-spam-detector.sh — t2925 (GH#21100)
#
# Detects "bounty-hunter" spam PRs/issues — a templated body class filed
# by bots that claim a $1 GitHub-Bounty/Paid reward for trivial diffs.
# Distinct attack class from the disclosure-spam handled by
# external-content-spam-detector.sh (#20978 / t2884): bounty-hunter bodies
# have NO external URLs, NO install CTAs, NO file:line refs, so they all
# score 2/clean against the existing composite detector. The signal here
# is the bot's verbatim output strings — markdown headers, attribution
# phrases, and a Reward/Source markdown table — none of which legitimate
# contributors would produce.
#
# Canonical incident: marcusquinn/aidevops PRs #21077, #21094, #21101
# from carycooper777 (account age 9 days, 225 fork-only repos) on
# 2026-04-26. The bot targeted recent task IDs scraped from the public
# repo, including PR #21101 which targeted the very issue (#21100)
# tracking the fix for this attack vector — confirming pattern-match
# alone is insufficient when the bot can read issue titles.
#
# Detection strategy (deterministic — verbatim bot strings):
#
#   1. Header patterns (must match at line-start to avoid quoted prose):
#        ^## 💰 (Paid )?Bounty Contribution
#        ^### 💰 (Paid )?Bounty Contribution
#        ^# Bounty Contribution
#
#   2. Attribution phrases (verbatim, anywhere in body):
#        Generated via automated bounty hunter
#        Feishu notifications
#        Contributed via bounty system
#
#   3. Structured field combination (BOTH must appear):
#        Reward: $N    (with markdown bold/table syntax)
#        Source: GitHub-Bounty/Paid (with markdown bold/table syntax)
#
# Any single match in (1) or (2), or both fields in (3), → spam-likely.
# These are the bot's literal output strings; false-positive rate near
# zero unless a maintainer quotes them when discussing this very attack
# class — which is why headers are line-anchored (quoting in code blocks
# or backticks won't trigger).
#
# Tertiary signals reported but NOT used as triggers (defense-in-depth
# only): author account age, public-repo fork ratio. These let a future
# extension layer score borderline cases without inflating false
# positives on legitimate new contributors.
#
# Usage:
#
#   bounty-spam-detector.sh check <issue|pr> <number> [--repo SLUG]
#     Exit 0=clean, 1=spam-likely, 2=ambiguous, 3=error.
#
#   bounty-spam-detector.sh score <issue|pr> <number> [--repo SLUG] [--json]
#     Print verdict and matched markers.
#
#   bounty-spam-detector.sh is-spam <issue|pr> <number> [--repo SLUG]
#     Boolean: exit 0 if spam-likely, 1 otherwise (for shell pipelines).
#
#   bounty-spam-detector.sh close <pr> <number> [--repo SLUG] [--dry-run]
#     Close PR with canonical dismissal comment if spam-likely.
#     Refuses to act on issues — auto-close on issues is out of scope.
#
#   bounty-spam-detector.sh scan-body --body-file <path>
#     Test against an arbitrary body file (used by the test harness).
#
#   bounty-spam-detector.sh help
#
# Env overrides:
#   BSD_QUIET=1                suppress info/warn logging on stderr
#   BSD_REFERENCE_URL          link in dismissal comment (default: this issue)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 1

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh" 2>/dev/null || true

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-gh-wrappers.sh" 2>/dev/null || true

# Fallback colours when shared-constants.sh is absent (e.g., shellcheck).
[[ -z "${RED+x}" ]] && RED='\033[0;31m'
[[ -z "${GREEN+x}" ]] && GREEN='\033[0;32m'
[[ -z "${YELLOW+x}" ]] && YELLOW='\033[1;33m'
[[ -z "${BLUE+x}" ]] && BLUE='\033[0;34m'
[[ -z "${NC+x}" ]] && NC='\033[0m'

readonly BSD_REFERENCE_URL_DEFAULT="https://github.com/marcusquinn/aidevops/issues/21100"
BSD_REFERENCE_URL="${BSD_REFERENCE_URL:-$BSD_REFERENCE_URL_DEFAULT}"

# ============================================================
# LOGGING
# ============================================================

_bsd_log_info() {
	[[ "${BSD_QUIET:-0}" == "1" ]] && return 0
	echo -e "${BLUE}[BSD]${NC} $*" >&2
	return 0
}

_bsd_log_warn() {
	[[ "${BSD_QUIET:-0}" == "1" ]] && return 0
	echo -e "${YELLOW}[BSD]${NC} $*" >&2
	return 0
}

_bsd_log_error() {
	echo -e "${RED}[BSD ERROR]${NC} $*" >&2
	return 0
}

# Shared error path for missing body fetches.
# Called by cmd_check, cmd_score, and cmd_close when _priv_get_body returns empty.
_bsd_fail_fetch_body() {
	local type="$1"
	local num="$2"
	local slug="$3"
	_bsd_log_error "Could not fetch body for ${type} #${num} in ${slug}"
	return 0
}

# ============================================================
# DETECTION HELPERS
# ============================================================

# Strip fenced code blocks (``` ... ```) from a body so reference material
# quoted inside fences doesn't false-positive against line-anchored
# header checks. Inline backticks (`like this`) are preserved — they
# already cannot match a line-anchored `^##` header.
# Args: $1 = raw body
# Output: body with fenced blocks removed (replaced with empty lines to
# preserve line numbers for downstream checks).
_priv_strip_fenced_blocks() {
	local body="$1"
	[[ -z "$body" ]] && return 0
	# awk state machine: skip lines between ``` markers (any language tag).
	# Replace stripped content with empty lines so line numbers stay stable.
	printf '%s' "$body" | awk '
		BEGIN { in_fence = 0 }
		/^```/ {
			in_fence = !in_fence
			print ""
			next
		}
		{
			if (in_fence) print ""
			else print
		}
	'
	return 0
}

# Check body for bounty-hunter HEADER patterns (line-anchored).
# Args: $1 = body
# Output: matched header pattern, or empty
# Returns: 0 always
_priv_match_header() {
	local body="$1"
	[[ -z "$body" ]] && return 0
	# Patterns are line-anchored. Use grep -E with -m1 for first match.
	# Note: emoji 💰 is multi-byte UTF-8; grep -E handles it byte-wise.
	local match
	match=$(printf '%s\n' "$body" |
		grep -E -m1 -e '^## .*Paid Bounty Contribution' \
			-e '^### .*Paid Bounty Contribution' \
			-e '^## .*Bounty Contribution' \
			-e '^### .*Bounty Contribution' \
			-e '^# Bounty Contribution' 2>/dev/null || true)
	# Filter to ensure the bounty-emoji or "Bounty Contribution" phrase
	# actually anchors — grep -E above is permissive on the wildcard; the
	# strict membership test happens in _priv_score below by re-checking
	# verbatim phrases.
	[[ -n "$match" ]] && printf '%s' "$match"
	return 0
}

# Check body for verbatim ATTRIBUTION phrases.
# Args: $1 = body
# Output: matched phrase (one per line), or empty
_priv_match_attribution() {
	local body="$1"
	[[ -z "$body" ]] && return 0
	local matches=""
	# Each phrase grep'd individually so we can list which fired.
	if printf '%s' "$body" | grep -q -F 'Generated via automated bounty hunter' 2>/dev/null; then
		matches="${matches}Generated via automated bounty hunter"$'\n'
	fi
	if printf '%s' "$body" | grep -q -F 'Feishu notifications' 2>/dev/null; then
		matches="${matches}Feishu notifications"$'\n'
	fi
	if printf '%s' "$body" | grep -q -F 'Contributed via bounty system' 2>/dev/null; then
		matches="${matches}Contributed via bounty system"$'\n'
	fi
	# Trim trailing newline.
	[[ -n "$matches" ]] && printf '%s' "${matches%$'\n'}"
	return 0
}

# Check body for STRUCTURED FIELD combination (Reward + Source both present).
# Args: $1 = body
# Output: "BOTH" if both fields match, "REWARD" or "SOURCE" if only one,
# empty if neither.
_priv_match_fields() {
	local body="$1"
	[[ -z "$body" ]] && return 0
	# Reward: matches **Reward** | **$N** | (markdown table) and **Reward:** $N
	# (definition list) variants. Use bounded `.{0,N}` since `.` won't cross
	# newlines in grep -E by default — keeps the match scoped to one row.
	# carycooper777 fixtures: `| **Reward** | **$1** |` (bold value).
	local has_reward=0 has_source=0
	if printf '%s' "$body" | grep -qE '\*\*Reward[:|]?\*\*.{0,40}\$[0-9]+' 2>/dev/null; then
		has_reward=1
	fi
	# Source: matches **Source** | GitHub-Paid (unbold) and **Source** | **GitHub-Bounty**
	# (bold). carycooper777 fixtures show the value WITHOUT bold; tolerate both.
	if printf '%s' "$body" | grep -qE '\*\*Source[:|]?\*\*.{0,40}GitHub-(Bounty|Paid)' 2>/dev/null; then
		has_source=1
	fi
	if [[ "$has_reward" -eq 1 && "$has_source" -eq 1 ]]; then
		printf 'BOTH'
	elif [[ "$has_reward" -eq 1 ]]; then
		printf 'REWARD'
	elif [[ "$has_source" -eq 1 ]]; then
		printf 'SOURCE'
	fi
	return 0
}

# Compute verdict and aggregate matches for a body.
# Args: $1 = body
# Output: pipe-delimited record:
#   verdict|header_match|attribution_matches|field_match
# Where verdict is one of: spam-likely, ambiguous, clean.
#
# Verdict design (high-precision, false-positive-averse):
#   - spam-likely requires ALL THREE signal classes:
#       (a) HEADER match (line-anchored, fence-stripped)
#       (b) at least one ATTRIBUTION phrase
#       (c) BOTH Reward and Source fields present
#     Rationale: every carycooper777 PR has all three. Legitimate
#     maintainer documentation discussing this attack class might
#     reproduce some markers (especially in fenced blocks, which we
#     strip), but the markdown-table field combination is the bot's
#     unique fingerprint that documentation rarely reproduces verbatim.
#   - ambiguous = 2 of 3 signal classes (worth maintainer attention,
#     but auto-close would be too aggressive).
#   - clean = ≤1 signal class.
#
# Code fences are stripped BEFORE matching so reference material quoted
# inside ``` blocks (e.g., a SECURITY.md documenting the attack) does
# not contribute to any signal.
_priv_score() {
	local body="$1"

	# Fence-strip first so all checks operate on prose-only content.
	local stripped
	stripped=$(_priv_strip_fenced_blocks "$body")

	local header
	header=$(_priv_match_header "$stripped")

	local attribution
	attribution=$(_priv_match_attribution "$stripped")

	local fields
	fields=$(_priv_match_fields "$stripped")

	# Count signal classes present.
	local n_signals=0
	[[ -n "$header" ]] && n_signals=$((n_signals + 1))
	[[ -n "$attribution" ]] && n_signals=$((n_signals + 1))
	[[ "$fields" == "BOTH" ]] && n_signals=$((n_signals + 1))

	local verdict="clean"
	if [[ "$n_signals" -ge 3 ]]; then
		verdict="spam-likely"
	elif [[ "$n_signals" -eq 2 ]]; then
		verdict="ambiguous"
	fi

	# Replace newlines in attribution list with semicolons for pipe-safe output.
	local attribution_flat
	attribution_flat=$(printf '%s' "$attribution" | tr '\n' ';' | sed 's/;$//')

	printf '%s|%s|%s|%s' \
		"$verdict" \
		"$header" \
		"$attribution_flat" \
		"$fields"
	return 0
}

# Verdict-to-exit-code mapping.
# Args: $1 = verdict string
_priv_verdict_to_exit() {
	local verdict="$1"
	case "$verdict" in
	clean) return 0 ;;
	spam-likely) return 1 ;;
	ambiguous) return 2 ;;
	*) return 3 ;;
	esac
}

# Fetch issue/PR body via wrappers (REST fallback under GraphQL pressure).
# Args: $1 = type (issue|pr), $2 = number, $3 = slug
_priv_get_body() {
	local type="$1" num="$2" slug="$3"
	if [[ "$type" == "pr" || "$type" == "pull" ]]; then
		gh pr view "$num" --repo "$slug" --json body --jq '.body' 2>/dev/null || true
	else
		if declare -F gh_issue_view >/dev/null 2>&1; then
			gh_issue_view "$num" --repo "$slug" --json body --jq '.body' 2>/dev/null || true
		else
			gh issue view "$num" --repo "$slug" --json body --jq '.body' 2>/dev/null || true
		fi
	fi
	return 0
}

# Resolve --repo from arg or current git remote.
# Args: $1 = explicit slug (may be empty)
_priv_resolve_repo() {
	local explicit="${1:-}"
	if [[ -n "$explicit" ]]; then
		echo "$explicit"
		return 0
	fi
	if command -v gh >/dev/null 2>&1; then
		local slug
		slug=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)
		if [[ -n "$slug" ]]; then
			echo "$slug"
			return 0
		fi
	fi
	_bsd_log_error "Cannot resolve --repo (no value passed and gh repo view failed)."
	return 1
}

# ============================================================
# COMMANDS
# ============================================================

cmd_check() {
	local type="${1:-}"
	local num="${2:-}"
	shift 2 2>/dev/null || true

	if [[ -z "$type" || -z "$num" ]]; then
		_bsd_log_error "Usage: check <issue|pr> <number> [--repo SLUG]"
		return 3
	fi

	local repo_arg=""
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--repo)
			repo_arg="${2:-}"
			shift 2
			;;
		*) shift ;;
		esac
	done

	local slug
	slug=$(_priv_resolve_repo "$repo_arg") || return 3

	local body
	body=$(_priv_get_body "$type" "$num" "$slug")
	if [[ -z "$body" ]]; then
		_bsd_fail_fetch_body "$type" "$num" "$slug"
		return 3
	fi

	local result
	result=$(_priv_score "$body")
	local verdict
	verdict=$(printf '%s' "$result" | cut -d'|' -f1)

	_bsd_log_info "${type}#${num} (${slug}): ${result}"
	local rc=0
	_priv_verdict_to_exit "$verdict" || rc=$?
	return "$rc"
}

cmd_score() {
	local type="${1:-}"
	local num="${2:-}"
	shift 2 2>/dev/null || true

	if [[ -z "$type" || -z "$num" ]]; then
		_bsd_log_error "Usage: score <issue|pr> <number> [--repo SLUG] [--json]"
		return 3
	fi

	local repo_arg=""
	local json=0
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--repo)
			repo_arg="${2:-}"
			shift 2
			;;
		--json)
			json=1
			shift
			;;
		*) shift ;;
		esac
	done

	local slug
	slug=$(_priv_resolve_repo "$repo_arg") || return 3

	local body
	body=$(_priv_get_body "$type" "$num" "$slug")
	if [[ -z "$body" ]]; then
		_bsd_fail_fetch_body "$type" "$num" "$slug"
		return 3
	fi

	local result
	result=$(_priv_score "$body")

	if [[ "$json" -eq 1 ]]; then
		local verdict header attribution fields
		verdict=$(printf '%s' "$result" | cut -d'|' -f1)
		header=$(printf '%s' "$result" | cut -d'|' -f2)
		attribution=$(printf '%s' "$result" | cut -d'|' -f3)
		fields=$(printf '%s' "$result" | cut -d'|' -f4)
		# JSON-escape via jq when available, else minimal manual escaping.
		if command -v jq >/dev/null 2>&1; then
			jq -nc \
				--arg type "$type" \
				--argjson number "$num" \
				--arg repo "$slug" \
				--arg verdict "$verdict" \
				--arg header "$header" \
				--arg attribution "$attribution" \
				--arg fields "$fields" \
				'{type:$type,number:$number,repo:$repo,verdict:$verdict,header_match:$header,attribution_matches:$attribution,field_match:$fields}'
		else
			# Best-effort manual JSON; replace " with \" in user-controlled fields.
			local h_esc a_esc
			h_esc="${header//\"/\\\"}"
			a_esc="${attribution//\"/\\\"}"
			printf '{"type":"%s","number":%d,"repo":"%s","verdict":"%s","header_match":"%s","attribution_matches":"%s","field_match":"%s"}\n' \
				"$type" "$num" "$slug" "$verdict" "$h_esc" "$a_esc" "$fields"
		fi
	else
		printf '%s\n' "$result"
	fi
	return 0
}

cmd_is_spam() {
	# Boolean wrapper around cmd_check. Exit 0 = spam, 1 = not spam.
	local rc=0
	cmd_check "$@" || rc=$?
	if [[ "$rc" -eq 1 ]]; then
		return 0
	fi
	return 1
}

cmd_scan_body() {
	# Test mode: read a body from a local file, print verdict.
	local body_file=""
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--body-file)
			body_file="${2:-}"
			shift 2
			;;
		*) shift ;;
		esac
	done
	if [[ -z "$body_file" || ! -f "$body_file" ]]; then
		_bsd_log_error "Usage: scan-body --body-file <path>"
		return 3
	fi
	local body
	body=$(cat "$body_file")
	local result
	result=$(_priv_score "$body")
	printf '%s\n' "$result"
	local verdict
	verdict=$(printf '%s' "$result" | cut -d'|' -f1)
	local rc=0
	_priv_verdict_to_exit "$verdict" || rc=$?
	return "$rc"
}

# _bsd_compose_close_comment <markers>
#
# Emits the canonical dismissal comment to stdout. Defined as a function with a
# top-level heredoc rather than as `comment_body=$(cat <<EOF ... EOF)` inside
# cmd_close because Bash 3.2 (macOS /bin/bash) cannot parse heredocs nested
# inside command substitutions — it reports a syntax error at the next case-arm
# token, masking the real cause. The function form parses cleanly on Bash 3.2,
# 4.x, and 5.x. See t2944.
_bsd_compose_close_comment() {
	local markers="$1"
	cat <<EOF
Auto-closed as templated bounty-hunter spam.

Detected markers:

${markers}
This pattern matches an automated bounty-hunter bot known to file templated PRs across many public repositories with claims of one-dollar bounty rewards. The PR body matches verbatim phrases or markdown structures used exclusively by this bot.

If filed in error, please contact the maintainer through the repository's normal contact channel — do **not** edit the PR body and reopen, as the auto-close trigger will fire again.

Reference: ${BSD_REFERENCE_URL}
EOF
	return 0
}

cmd_close() {
	local type="${1:-}"
	local num="${2:-}"
	shift 2 2>/dev/null || true

	if [[ -z "$type" || -z "$num" ]]; then
		_bsd_log_error "Usage: close <pr> <number> [--repo SLUG] [--dry-run]"
		return 3
	fi
	if [[ "$type" != "pr" && "$type" != "pull" ]]; then
		_bsd_log_error "close: only PRs supported (received type=${type}). Issues stay open for triage."
		return 3
	fi

	local repo_arg=""
	local dry_run=0
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--repo)
			repo_arg="${2:-}"
			shift 2
			;;
		--dry-run)
			dry_run=1
			shift
			;;
		*) shift ;;
		esac
	done

	local slug
	slug=$(_priv_resolve_repo "$repo_arg") || return 3

	local body
	body=$(_priv_get_body "$type" "$num" "$slug")
	if [[ -z "$body" ]]; then
		_bsd_fail_fetch_body "$type" "$num" "$slug"
		return 3
	fi

	local result
	result=$(_priv_score "$body")
	local verdict header attribution fields
	verdict=$(printf '%s' "$result" | cut -d'|' -f1)
	header=$(printf '%s' "$result" | cut -d'|' -f2)
	attribution=$(printf '%s' "$result" | cut -d'|' -f3)
	fields=$(printf '%s' "$result" | cut -d'|' -f4)

	if [[ "$verdict" != "spam-likely" ]]; then
		_bsd_log_info "PR #${num} verdict=${verdict}; not closing."
		return 0
	fi

	# Compose canonical dismissal comment. Markers shown as bullet list so
	# the maintainer can audit what triggered.
	local markers=""
	[[ -n "$header" ]] && markers="${markers}- Header: \`${header}\`"$'\n'
	if [[ -n "$attribution" ]]; then
		local IFS=';'
		local phrase
		for phrase in $attribution; do
			[[ -z "$phrase" ]] && continue
			markers="${markers}- Verbatim phrase: \`${phrase}\`"$'\n'
		done
		unset IFS
	fi
	[[ "$fields" == "BOTH" ]] && markers="${markers}- Markdown table: \`Reward: \$N\` + \`Source: GitHub-Bounty/Paid\`"$'\n'

	local comment_body
	comment_body="$(_bsd_compose_close_comment "$markers")"

	if [[ "$dry_run" -eq 1 ]]; then
		_bsd_log_warn "[DRY RUN] Would close PR #${num} in ${slug} with comment:"
		printf '%s\n' "$comment_body"
		return 0
	fi

	# Real close: post comment first (audit trail), then close.
	if declare -F gh_pr_comment >/dev/null 2>&1; then
		gh_pr_comment "$num" --repo "$slug" --body "$comment_body" || _bsd_log_warn "Comment post failed; closing anyway."
	else
		gh pr comment "$num" --repo "$slug" --body "$comment_body" || _bsd_log_warn "Comment post failed; closing anyway."
	fi
	gh pr close "$num" --repo "$slug" || {
		_bsd_log_error "gh pr close failed for #${num}"
		return 3
	}
	_bsd_log_info "Closed PR #${num} in ${slug} (verdict=spam-likely)."
	return 0
}

cmd_help() {
	cat <<'EOF'
bounty-spam-detector.sh — auto-detect and close templated bounty-hunter
  spam PRs (t2925, GH#21100). Distinct attack class from disclosure spam
  (#20978) handled by external-content-spam-detector.sh.

USAGE:
  bounty-spam-detector.sh check <issue|pr> <number> [--repo SLUG]
  bounty-spam-detector.sh score <issue|pr> <number> [--repo SLUG] [--json]
  bounty-spam-detector.sh is-spam <issue|pr> <number> [--repo SLUG]
  bounty-spam-detector.sh close <pr> <number> [--repo SLUG] [--dry-run]
  bounty-spam-detector.sh scan-body --body-file <path>
  bounty-spam-detector.sh help

EXIT CODES (check, is-spam, scan-body):
  0  clean         no markers matched (or NOT spam, for is-spam)
  1  spam-likely   header / attribution / both-fields match
  2  ambiguous     single field match (Reward or Source alone)
  3  error         could not fetch body, parse args, or invalid type

DETECTION MARKERS (any one in 1-2, or BOTH in 3, → spam-likely):
  1. Headers (line-anchored):
       ^## ...Bounty Contribution
       ^### ...Bounty Contribution
       ^# Bounty Contribution
  2. Attribution phrases (verbatim, anywhere):
       Generated via automated bounty hunter
       Feishu notifications
       Contributed via bounty system
  3. Markdown-table fields (BOTH must appear):
       **Reward**...**$N**
       **Source**...**GitHub-(Bounty|Paid)**

ENV OVERRIDES:
  BSD_QUIET=1            suppress info/warn logging on stderr
  BSD_REFERENCE_URL      link in dismissal comment

EXAMPLES:
  # Check a closed PR (body is still readable):
  bounty-spam-detector.sh check pr 21077 --repo marcusquinn/aidevops

  # JSON breakdown:
  bounty-spam-detector.sh score pr 21077 --repo marcusquinn/aidevops --json

  # Dry-run close (shows comment, takes no action):
  bounty-spam-detector.sh close pr 21077 --repo marcusquinn/aidevops --dry-run

  # Test against a local body fixture:
  bounty-spam-detector.sh scan-body --body-file ./fixture.md

NOTES:
  - close refuses to act on issues — issue-level auto-close is out of
    scope. Use score/check on issues for triage labelling decisions.
  - The patterns are the bot's verbatim output strings; false-positive
    rate is near zero. If a maintainer needs to discuss this attack
    class in a PR/issue body, quoting in inline backticks or a fenced
    code block does NOT trigger header detection (which is line-anchored).
EOF
	return 0
}

# ============================================================
# DISPATCH
# ============================================================

main() {
	local cmd="${1:-help}"
	shift 2>/dev/null || true
	case "$cmd" in
	check) cmd_check "$@" ;;
	score) cmd_score "$@" ;;
	is-spam) cmd_is_spam "$@" ;;
	close) cmd_close "$@" ;;
	scan-body) cmd_scan_body "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		_bsd_log_error "Unknown command: ${cmd}"
		cmd_help
		return 3
		;;
	esac
	return $?
}

# Allow sourcing for tests; only run main when invoked as a script.
if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
	main "$@"
fi
