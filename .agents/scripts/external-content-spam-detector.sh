#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# external-content-spam-detector.sh — t2884 (Phase C of parent #20983)
#
# Combines the unsolicited_disclosure_marketing pattern category (Phase A,
# .agents/configs/prompt-injection-patterns.yaml) with structural signals
# (author association, single-domain repetition, evidence-styled file:line
# refs) to flag scanner-spam reports filed by drive-by external authors.
#
# Canonical incident: marcusquinn/aidevops#20978 — "responsible disclosure"
# from a NONE-association author, multiple pip-install / curl-pipe-bash CTAs,
# repeated vendor URLs, and dozens of fabricated file:line evidence claims.
# Verification falsified nearly every cited finding; the install/URL/email
# invitations were the actual payload.
#
# Pattern matching alone is insufficient — `pip install aidevops` in a
# legitimate README would match. The signal that distinguishes scanner-spam
# from legitimate content is the COMBINATION of:
#   - non-collaborator author       (author_association not OWNER/MEMBER/COLLABORATOR)
#   - single-domain repetition      (one external non-GitHub host appears >=3 times)
#   - pattern category matches      (pip install / curl-pipe-bash / out-clauses / footers)
#   - evidence-styled file:line refs (>=3 file.ext:NNN occurrences)
#
# Composite score >=5 = spam-likely, 3-4 = ambiguous, <3 = clean.
#
# The output is consumed by maintainer triage (e.g., issues parked in
# `needs-maintainer-review`). Pulse pre-dispatch integration is out of scope
# for this phase — it touches the dispatch path and warrants its own task
# with no-auto-dispatch + #interactive (see "Dispatch-path default" in
# .agents/AGENTS.md).
#
# Usage:
#   external-content-spam-detector.sh check <issue|pr> <number> [--repo SLUG]
#     Exit 0=clean, 1=spam-likely, 2=ambiguous, 3=error.
#
#   external-content-spam-detector.sh score <issue|pr> <number> [--repo SLUG] [--json]
#     Print composite score and breakdown for programmatic use.
#
#   external-content-spam-detector.sh batch [--repo SLUG] [--label LABEL] [--apply]
#     Iterate issues carrying LABEL (default: needs-maintainer-review) and
#     print one-line verdicts. Default is dry-run; --apply suggests labels
#     but does NOT modify issues — that decision stays with the maintainer.
#
#   external-content-spam-detector.sh help
#
# Env overrides:
#   ECSD_SPAM_THRESHOLD       (default 5)   composite >= => spam-likely
#   ECSD_AMBIGUOUS_THRESHOLD  (default 3)   composite >= => ambiguous
#   ECSD_DOMAIN_REPEAT_MIN    (default 3)   host occurrences to count
#   ECSD_FILELINE_MIN         (default 3)   file:line refs to count
#   ECSD_EXCLUDE_HOSTS        comma list of hosts to exclude from repetition
#                             (default: github.com,githubusercontent.com)

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

PROMPT_GUARD_HELPER="${SCRIPT_DIR}/prompt-guard-helper.sh"
SCAN_CATEGORY="unsolicited_disclosure_marketing"

# Sentinel for author_association lookups that can't be resolved (404, gh
# offline, missing field). Treated as non-collaborator by _priv_is_non_collaborator.
readonly ECSD_UNKNOWN_ASSOC="UNKNOWN"

# Trusted associations — anything else is treated as non-collaborator.
TRUSTED_ASSOCIATIONS=("OWNER" "MEMBER" "COLLABORATOR")

# Tunable weights (see brief — composite >=5 spam, 3-4 ambiguous, <3 clean).
SPAM_THRESHOLD="${ECSD_SPAM_THRESHOLD:-5}"
AMBIGUOUS_THRESHOLD="${ECSD_AMBIGUOUS_THRESHOLD:-3}"
DOMAIN_REPEAT_MIN="${ECSD_DOMAIN_REPEAT_MIN:-3}"
FILELINE_MIN="${ECSD_FILELINE_MIN:-3}"

# WEIGHT_NON_COLLAB tuned to 2 (down from the spec's starting value of 3) so
# that ordinary non-collaborator bug reports score below the ambiguous threshold
# unless they also carry a structural signal (install CTAs, domain repetition,
# evidence-styled refs). Verified against marcusquinn/aidevops issue history:
# robstiles (NONE) detailed bug reports #20727, #20637, #20611 all score 2
# (clean); spam #20978 still scores 7 (spam-likely). Within the brief's stated
# +-1 tuning latitude per weight.
WEIGHT_NON_COLLAB=2
WEIGHT_DOMAIN_REPEAT=2
WEIGHT_PATTERN_MATCH=1
WEIGHT_FILELINE_REFS=1

# Hosts excluded from single-domain repetition (always lowercased).
DEFAULT_EXCLUDE_HOSTS="github.com,githubusercontent.com"
EXCLUDE_HOSTS_RAW="${ECSD_EXCLUDE_HOSTS:-${DEFAULT_EXCLUDE_HOSTS}}"

# ============================================================
# LOGGING
# ============================================================

_ecsd_log_info() {
	[[ "${ECSD_QUIET:-0}" == "1" ]] && return 0
	echo -e "${BLUE}[ECSD]${NC} $*" >&2
	return 0
}

_ecsd_log_warn() {
	[[ "${ECSD_QUIET:-0}" == "1" ]] && return 0
	echo -e "${YELLOW}[ECSD]${NC} $*" >&2
	return 0
}

_ecsd_log_error() {
	echo -e "${RED}[ECSD ERROR]${NC} $*" >&2
	return 0
}

# ============================================================
# PRIVATE HELPERS
# ============================================================

# Print one normalized lowercase external host per line, or nothing.
# Excludes hosts in EXCLUDE_HOSTS_RAW (matched as full host or subdomain).
# Args: $1 = body text
_priv_extract_external_hosts() {
	local body="$1"
	[[ -z "$body" ]] && return 0

	# Build a grep -E exclusion alternation from EXCLUDE_HOSTS_RAW.
	# Each entry matches the full host or any subdomain ending in .HOST.
	local excl_re=""
	local IFS=','
	local h
	for h in $EXCLUDE_HOSTS_RAW; do
		[[ -z "$h" ]] && continue
		# Escape dots in the literal host before assembling the alternation.
		local escaped="${h//./\\.}"
		if [[ -z "$excl_re" ]]; then
			excl_re="(^|\.)${escaped}\$"
		else
			excl_re="${excl_re}|(^|\.)${escaped}\$"
		fi
	done

	# Extract URLs (http/https), strip scheme, take the host portion (up to
	# first / : ? # ), lowercase, then drop excluded hosts.
	printf '%s' "$body" |
		grep -oEi 'https?://[A-Za-z0-9.-]+' 2>/dev/null |
		sed -E 's|^https?://||I' |
		tr '[:upper:]' '[:lower:]' |
		grep -vE "${excl_re}" 2>/dev/null || true
	return 0
}

# Output max repetition count of any external host (integer).
# Args: $1 = body text
_priv_max_host_repetition() {
	local body="$1"
	local hosts
	hosts=$(_priv_extract_external_hosts "$body")
	if [[ -z "$hosts" ]]; then
		echo 0
		return 0
	fi
	# sort | uniq -c outputs "  COUNT host"; take the largest count.
	local max
	max=$(printf '%s\n' "$hosts" | sort | uniq -c | sort -rn | awk 'NR==1 {print $1; exit}')
	[[ "$max" =~ ^[0-9]+$ ]] || max=0
	echo "$max"
	return 0
}

# Count evidence-styled file:line refs (e.g., src/foo.sh:42, package.json:10).
# Recognises common code/data extensions; intentionally narrow to avoid
# matching version strings like "v3.6.187:".
# Args: $1 = body text
_priv_count_fileline_refs() {
	local body="$1"
	[[ -z "$body" ]] && {
		echo 0
		return 0
	}
	local count
	count=$(printf '%s' "$body" |
		grep -oE '\b[A-Za-z0-9_][A-Za-z0-9_/.-]*\.(sh|bash|zsh|py|ts|tsx|js|jsx|mjs|md|yaml|yml|json|toml|rb|go|rs|java|kt|swift|c|h|cpp|hpp|cs|php|sql|html|css|conf|ini)[:][0-9]+\b' 2>/dev/null |
		wc -l | tr -d ' ')
	[[ "$count" =~ ^[0-9]+$ ]] || count=0
	echo "$count"
	return 0
}

# Look up GitHub author_association via REST. The REST endpoint is in a
# separate rate-limit pool from GraphQL, which keeps this resilient when
# GraphQL is exhausted (t2574, t2744).
# Args: $1 = type (issue|pr), $2 = number, $3 = slug
# Output: assoc string (UPPERCASE) or "UNKNOWN" on error.
_priv_get_author_association() {
	local type="$1" num="$2" slug="$3"
	local endpoint
	case "$type" in
	pr | pull) endpoint="repos/${slug}/pulls/${num}" ;;
	*) endpoint="repos/${slug}/issues/${num}" ;;
	esac
	local assoc
	assoc=$(gh api "$endpoint" --jq ".author_association // \"${ECSD_UNKNOWN_ASSOC}\"" 2>/dev/null || echo "$ECSD_UNKNOWN_ASSOC")
	[[ -z "$assoc" ]] && assoc="$ECSD_UNKNOWN_ASSOC"
	echo "$assoc"
	return 0
}

# Return 1 if association is non-collaborator (untrusted), 0 if trusted.
# Args: $1 = association string
_priv_is_non_collaborator() {
	local assoc="$1"
	local trusted
	for trusted in "${TRUSTED_ASSOCIATIONS[@]}"; do
		[[ "$assoc" == "$trusted" ]] && {
			echo 0
			return 0
		}
	done
	echo 1
	return 0
}

# Count matches of SCAN_CATEGORY in the body via prompt-guard-helper scan-file.
# We grep the colorized stderr findings for "<category>:" lines — ANSI codes
# do not interfere with the literal string match.
# Args: $1 = body text
_priv_count_pattern_matches() {
	local body="$1"
	[[ -z "$body" ]] && {
		echo 0
		return 0
	}
	if [[ ! -x "$PROMPT_GUARD_HELPER" ]]; then
		_ecsd_log_warn "prompt-guard-helper.sh not found at ${PROMPT_GUARD_HELPER}; pattern signal=0"
		echo 0
		return 0
	fi
	local tmp
	tmp=$(mktemp 2>/dev/null) || {
		echo 0
		return 0
	}
	printf '%s' "$body" >"$tmp"
	local count
	count=$(PROMPT_GUARD_QUIET=true "$PROMPT_GUARD_HELPER" scan-file "$tmp" 2>&1 |
		grep -c "${SCAN_CATEGORY}:" 2>/dev/null || true)
	[[ "$count" =~ ^[0-9]+$ ]] || count=0
	rm -f "$tmp"
	echo "$count"
	return 0
}

# Fetch issue/PR body via the rate-limit-aware wrapper.
# Args: $1 = type (issue|pr), $2 = number, $3 = slug
_priv_get_body() {
	local type="$1" num="$2" slug="$3"
	if [[ "$type" == "pr" || "$type" == "pull" ]]; then
		gh pr view "$num" --repo "$slug" --json body --jq '.body' 2>/dev/null || true
	else
		# gh_issue_view comes from shared-gh-wrappers.sh and has REST fallback.
		gh_issue_view "$num" --repo "$slug" --json body --jq '.body' 2>/dev/null || true
	fi
	return 0
}

# Compose composite score and pipe-delimited breakdown.
# Args: $1 = body, $2 = type, $3 = number, $4 = slug
# Output: score|verdict|assoc=X|domain_max=N|patterns=N|fileline=N
_priv_compute_score() {
	local body="$1" type="$2" num="$3" slug="$4"

	local assoc
	assoc=$(_priv_get_author_association "$type" "$num" "$slug")
	local non_collab
	non_collab=$(_priv_is_non_collaborator "$assoc")

	local domain_max
	domain_max=$(_priv_max_host_repetition "$body")
	local domain_signal=0
	[[ "$domain_max" -ge "$DOMAIN_REPEAT_MIN" ]] && domain_signal=1

	local patterns
	patterns=$(_priv_count_pattern_matches "$body")

	local fileline
	fileline=$(_priv_count_fileline_refs "$body")
	local fileline_signal=0
	[[ "$fileline" -ge "$FILELINE_MIN" ]] && fileline_signal=1

	local score=0
	score=$((score + non_collab * WEIGHT_NON_COLLAB))
	score=$((score + domain_signal * WEIGHT_DOMAIN_REPEAT))
	score=$((score + patterns * WEIGHT_PATTERN_MATCH))
	score=$((score + fileline_signal * WEIGHT_FILELINE_REFS))

	local verdict
	if [[ "$score" -ge "$SPAM_THRESHOLD" ]]; then
		verdict="spam-likely"
	elif [[ "$score" -ge "$AMBIGUOUS_THRESHOLD" ]]; then
		verdict="ambiguous"
	else
		verdict="clean"
	fi

	printf '%d|%s|assoc=%s|domain_max=%d|patterns=%d|fileline=%d\n' \
		"$score" "$verdict" "$assoc" "$domain_max" "$patterns" "$fileline"
	return 0
}

# Resolve --repo from args or fallback to current git remote.
# Echoes the slug. Returns 1 with an error message if it can't be resolved.
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
	_ecsd_log_error "Cannot resolve --repo (no value passed and gh repo view failed)."
	return 1
}

# Verdict-to-exit-code mapping. Used by cmd_check. Returns the exit code
# directly (does NOT echo) so callers can `return $?` cleanly.
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

# ============================================================
# COMMANDS
# ============================================================

cmd_check() {
	local type="${1:-}"
	local num="${2:-}"
	shift 2 2>/dev/null || true

	if [[ -z "$type" || -z "$num" ]]; then
		_ecsd_log_error "Usage: check <issue|pr> <number> [--repo SLUG]"
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
		_ecsd_log_error "Could not fetch body for ${type} #${num} in ${slug}"
		return 3
	fi

	local result
	result=$(_priv_compute_score "$body" "$type" "$num" "$slug")
	local verdict
	verdict=$(printf '%s' "$result" | cut -d'|' -f2)

	_ecsd_log_info "${type}#${num} (${slug}): ${result}"
	# `set -e` would terminate before `return $?` if we relied on the helper's
	# non-zero exit, so capture explicitly with `||`.
	local rc=0
	_priv_verdict_to_exit "$verdict" || rc=$?
	return "$rc"
}

cmd_score() {
	local type="${1:-}"
	local num="${2:-}"
	shift 2 2>/dev/null || true

	if [[ -z "$type" || -z "$num" ]]; then
		_ecsd_log_error "Usage: score <issue|pr> <number> [--repo SLUG] [--json]"
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
		_ecsd_log_error "Could not fetch body for ${type} #${num} in ${slug}"
		return 3
	fi

	local result
	result=$(_priv_compute_score "$body" "$type" "$num" "$slug")

	if [[ "$json" -eq 1 ]]; then
		# Convert pipe-delimited output to JSON object for programmatic use.
		local score verdict assoc domain patterns fileline
		score=$(printf '%s' "$result" | cut -d'|' -f1)
		verdict=$(printf '%s' "$result" | cut -d'|' -f2)
		assoc=$(printf '%s' "$result" | cut -d'|' -f3 | cut -d'=' -f2)
		domain=$(printf '%s' "$result" | cut -d'|' -f4 | cut -d'=' -f2)
		patterns=$(printf '%s' "$result" | cut -d'|' -f5 | cut -d'=' -f2)
		fileline=$(printf '%s' "$result" | cut -d'|' -f6 | cut -d'=' -f2)
		printf '{"type":"%s","number":%d,"repo":"%s","score":%d,"verdict":"%s","author_association":"%s","domain_max":%d,"patterns":%d,"fileline_refs":%d}\n' \
			"$type" "$num" "$slug" "$score" "$verdict" "$assoc" "$domain" "$patterns" "$fileline"
	else
		printf '%s\n' "$result"
	fi
	return 0
}

cmd_batch() {
	local repo_arg=""
	local label="needs-maintainer-review"
	local apply=0

	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--repo)
			repo_arg="${2:-}"
			shift 2
			;;
		--label)
			label="${2:-}"
			shift 2
			;;
		--apply)
			apply=1
			shift
			;;
		*) shift ;;
		esac
	done

	local slug
	slug=$(_priv_resolve_repo "$repo_arg") || return 3

	_ecsd_log_info "Scanning open issues with label=${label} in ${slug} (dry-run=$([[ $apply -eq 0 ]] && echo yes || echo no))"

	# Use shared wrapper so REST fallback kicks in under GraphQL pressure.
	local issues
	issues=$(gh_issue_list --repo "$slug" --state open --label "$label" \
		--limit 200 --json number --jq '.[].number' 2>/dev/null || true)

	if [[ -z "$issues" ]]; then
		_ecsd_log_info "No open issues with label=${label}"
		return 0
	fi

	local n
	while IFS= read -r n; do
		[[ -z "$n" ]] && continue
		local body
		body=$(_priv_get_body "issue" "$n" "$slug")
		if [[ -z "$body" ]]; then
			printf 'issue#%s\tERROR\tcould not fetch body\n' "$n"
			continue
		fi
		local result
		result=$(_priv_compute_score "$body" "issue" "$n" "$slug")
		local verdict
		verdict=$(printf '%s' "$result" | cut -d'|' -f2)
		printf 'issue#%s\t%s\t%s\n' "$n" "$verdict" "$result"
	done <<<"$issues"

	if [[ "$apply" -eq 1 ]]; then
		_ecsd_log_warn "--apply currently only PRINTS the verdicts. Maintainer action remains manual."
	fi
	return 0
}

cmd_help() {
	cat <<'EOF'
external-content-spam-detector.sh — flag scanner-spam reports filed by
  drive-by external authors (parent #20983, Phase C / t2884).

USAGE:
  external-content-spam-detector.sh check <issue|pr> <number> [--repo SLUG]
  external-content-spam-detector.sh score <issue|pr> <number> [--repo SLUG] [--json]
  external-content-spam-detector.sh batch [--repo SLUG] [--label LABEL] [--apply]
  external-content-spam-detector.sh help

EXIT CODES (check):
  0  clean               composite < ECSD_AMBIGUOUS_THRESHOLD (default 3)
  1  spam-likely         composite >= ECSD_SPAM_THRESHOLD (default 5)
  2  ambiguous           composite in [3, 5)
  3  error               could not fetch body / resolve repo / parse args

SCORING (composed):
  +3  non-collaborator author     (author_association not OWNER/MEMBER/COLLABORATOR)
  +2  any external host appears >=ECSD_DOMAIN_REPEAT_MIN times (default 3)
  +1  per pattern match in unsolicited_disclosure_marketing category
  +1  >=ECSD_FILELINE_MIN evidence-styled file:line refs (default 3)

ENV OVERRIDES:
  ECSD_SPAM_THRESHOLD       (default 5)
  ECSD_AMBIGUOUS_THRESHOLD  (default 3)
  ECSD_DOMAIN_REPEAT_MIN    (default 3)
  ECSD_FILELINE_MIN         (default 3)
  ECSD_EXCLUDE_HOSTS        comma list (default github.com,githubusercontent.com)
  ECSD_QUIET=1              suppress info/warn logging on stderr

EXAMPLES:
  # Check the canonical incident (#20978):
  external-content-spam-detector.sh check issue 20978 --repo marcusquinn/aidevops

  # JSON breakdown for programmatic use:
  external-content-spam-detector.sh score issue 20978 --repo marcusquinn/aidevops --json

  # Sweep a triage queue:
  external-content-spam-detector.sh batch --repo marcusquinn/aidevops \
                                          --label needs-maintainer-review

NOTE:
  This helper does NOT modify issues. It surfaces verdicts; the maintainer
  (or a separate lifecycle helper) decides what to do with them.
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
	batch) cmd_batch "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		_ecsd_log_error "Unknown command: ${cmd}"
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
