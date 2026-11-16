#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# pulse-fix-the-fixer-detector.sh — Periodic LLM-driven detector that
# classifies pending dispatches as "fix-the-fixer" (touches dispatch system
# itself) or normal, applying the `fix-the-fixer` label + advisory comment
# before workers spawn. (t3077 / GH#21841)
#
# Why this exists (t3077):
#   The deterministic t2819 self-hosting detector pattern-matches paths in
#   .agents/configs/self-hosting-files.conf to auto-elevate dispatch-path
#   tasks to opus. That works for tasks that explicitly name dispatch files,
#   but cannot catch:
#     - Indirect changes via shared lib edits (shared-constants.sh) that
#       cascade into the dispatch path.
#     - Briefs that imply dispatch-system risk without naming files
#       ("fix the worker exit semantics" with no Files Scope block).
#     - Combination tasks where one part is dispatch-system and one is not.
#   When a worker fixing a dispatch bug is killed BY that bug before
#   producing output, the failure is invisible and the task re-dispatches
#   indefinitely (canonical: #21707 → PR #21741, six wasted opus dispatches).
#
# What this does:
#   For each pending auto-dispatch issue without `fix-the-fixer` label:
#     1. Reads the issue body + linked task brief (if any).
#     2. Calls a thinking-tier LLM with a binary classification prompt.
#     3. On YES verdict, applies the `fix-the-fixer` label and posts an
#        advisory comment naming the rationale.
#   The dispatch path (headless-runtime-helper.sh, t3077 changes) reads
#   the label and enables verbose lifecycle, tighter watchdog, and a
#   preflight sentinel write.
#
# Design constraints:
#   - Idempotent: skips issues already carrying the label.
#   - Fail-open: any internal error returns 0 — the deterministic
#     t2819 detector remains the primary safety net.
#   - Relevant scope: only repositories whose local checkout contains the
#     dispatch system (.agents/scripts/pulse-wrapper.sh) are scanned;
#     an explicit --repo bypasses that gate.
#   - Capped scope: --limit caps LLM classifications per run (default 10).
#   - Bounded: each run stops taking work after a wall-clock budget below
#     the Pulse stage timeout, writes its summary, and resumes from the
#     next unscanned repository on the following run.
#   - Remembered: completed YES/NO verdicts are cached per issue content
#     hash; an edited title/body is classified again.
#   - Cheap: defaults to the `simple` tier; env override.
#
# Usage:
#   pulse-fix-the-fixer-detector.sh run [--repo OWNER/REPO] [--limit N]
#   pulse-fix-the-fixer-detector.sh run --dry-run   # classify but don't apply
#   pulse-fix-the-fixer-detector.sh check <issue-number> <slug>
#   pulse-fix-the-fixer-detector.sh help
#
# Bypass:
#   AIDEVOPS_FIX_THE_FIXER_DETECTOR_DISABLE=1   — exit 0 immediately
#   AIDEVOPS_FIX_THE_FIXER_DETECTOR_DRY_RUN=1   — classify, don't write
#
# Tunables:
#   AIDEVOPS_FIX_THE_FIXER_DETECTOR_MODEL           (default: simple)
#   AIDEVOPS_FIX_THE_FIXER_DETECTOR_LIMIT           (default: 10)
#   AIDEVOPS_FIX_THE_FIXER_DETECTOR_BUDGET_SECONDS  (default: 40)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 1

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh"

readonly FIX_THE_FIXER_LABEL="fix-the-fixer"
readonly FIX_THE_FIXER_LABEL_COLOR="e4e669"
readonly FIX_THE_FIXER_LABEL_DESCRIPTION="Worker dispatch self-referential task"
readonly FIX_THE_FIXER_MARKER="<!-- aidevops:fix-the-fixer-detector -->"
# GH#23594: test override path. Production callers leave the env var unset
# and pick up the sibling helper; regression tests can point at a stub that
# deterministically returns a specific exit code.
readonly AI_RESEARCH_HELPER="${PULSE_AI_RESEARCH_HELPER_OVERRIDE:-${SCRIPT_DIR}/ai-research-helper.sh}"
readonly REPOS_JSON="${HOME}/.config/aidevops/repos.json"
readonly AUTH_COOLDOWN_FILE="${HOME}/.aidevops/cache/fix-the-fixer-detector-auth.cooldown"
readonly AUTH_COOLDOWN_SECONDS_DEFAULT=21600
readonly AUTH_ERROR_REASON="AI research credentials invalid"
# GH#38673: completed YES/NO verdicts keyed by slug, issue and content hash.
# Without this, every cold run re-classified the same first issues and the
# Pulse stage bound killed it before later issues (or the summary) were reached.
readonly VERDICT_CACHE_FILE="${HOME}/.aidevops/cache/fix-the-fixer-verdicts.tsv"
readonly VERDICT_CACHE_MAX_ROWS=2000
# Next repository to scan; a run that stops early resumes there next time.
readonly REPO_CURSOR_FILE="${HOME}/.aidevops/cache/fix-the-fixer-detector-cursor"
# Must stay below the Pulse stage bound (PULSE_FIX_THE_FIXER_TIMEOUT_SECONDS=60)
# with headroom for one in-flight classification plus the summary write.
readonly RUN_BUDGET_SECONDS_DEFAULT=40
# Only a repository that contains the worker dispatch system can host a
# fix-the-fixer task. Product repositories were listed and classified every
# run (69 of 70 on one runner) although they can never be YES.
readonly DISPATCH_SYSTEM_MARKER=".agents/scripts/pulse-wrapper.sh"
# One jq expression for the content key, so the list and view paths hash the
# same bytes.
readonly CONTENT_KEY_JQ='(((.title // "") + "\n" + (.body // "")) | @base64)'
# Sentinels used by the GitHub issue API. Extracted as constants so the
# literal strings appear once (codebase ratchet flags repeated literals).
readonly ISSUE_STATE_OPEN="OPEN"
# Log-level tokens (ditto — extracted to satisfy the repeated-literals gate).
readonly _LL_INFO="INFO"
readonly _LL_WARN="WARN"

_log() {
	local level="$1"
	shift
	printf '[fix-the-fixer-detector] %s: %s\n' "$level" "$*" >&2
	return 0
}

_log_info() {
	_log "$_LL_INFO" "$@"
	return 0
}

_log_warn() {
	_log "$_LL_WARN" "$@"
	return 0
}

_auth_item_logs_suppressed() {
	[[ "${AIDEVOPS_FIX_THE_FIXER_DETECTOR_SUPPRESS_AUTH_ITEM_LOGS:-0}" == "1" ]] || return 1
	return 0
}

_log_auth_skip() {
	if _auth_item_logs_suppressed; then
		return 0
	fi
	_log_warn "$@"
	return $?
}

_auth_cooldown_seconds() {
	local configured="${AIDEVOPS_FIX_THE_FIXER_DETECTOR_AUTH_COOLDOWN_SECONDS:-$AUTH_COOLDOWN_SECONDS_DEFAULT}"
	[[ "$configured" =~ ^[0-9]+$ && "$configured" -gt 0 ]] || configured="$AUTH_COOLDOWN_SECONDS_DEFAULT"
	printf '%s\n' "$configured"
	return 0
}

_hash_text() {
	local value="$1"
	if command -v sha256sum >/dev/null 2>&1; then
		printf '%s' "$value" | sha256sum | awk '{ print $1 }'
		return 0
	fi
	printf '%s' "$value" | shasum -a 256 | awk '{ print $1 }'
	return 0
}

_file_mtime() {
	local path="$1"
	[[ -e "$path" ]] || {
		printf 'missing\n'
		return 0
	}
	local mtime
	mtime=$(_file_mtime_epoch "$path" 2>/dev/null) || {
		local rc=$?
		printf 'unknown\n'
		return "$rc"
	}
	printf '%s\n' "$mtime"
	return 0
}

_auth_config_stamp() {
	local creds_file="${HOME}/.config/aidevops/credentials.sh"
	local env_state="unset"
	[[ -n "${ANTHROPIC_API_KEY:-}" ]] && env_state="set:$(_hash_text "$ANTHROPIC_API_KEY")"
	printf 'env=%s;creds=%s;helper=%s\n' \
		"$env_state" \
		"$(_file_mtime "$creds_file")" \
		"$(_file_mtime "$AI_RESEARCH_HELPER")"
	return 0
}

_is_auth_error() {
	local message="$1"
	local normalized
	normalized=$(printf '%s' "$message" | tr '[:upper:]' '[:lower:]')
	case "$normalized" in
		*"invalid x-api-key"*|*"invalid api key"*|*"authentication_error"*|*"unauthorized"*) return 0 ;;
		*) return 1 ;;
	esac
}

_is_runtime_auth_error() {
	local message="$1"
	local normalized
	normalized=$(printf '%s' "$message" | tr '[:upper:]' '[:lower:]')
	case "$normalized" in
		*"isolated opencode runtime cannot authenticate"*|*"does not load the provider-auth plugin"*) return 0 ;;
		*) return 1 ;;
	esac
}

# Only persist fixed diagnostics, never provider stderr or credential values.
_auth_failure_reason() {
	if [[ -f "$AUTH_COOLDOWN_FILE" ]] && grep -q '^reason=runtime_auth_unavailable$' "$AUTH_COOLDOWN_FILE"; then
		printf 'runtime_auth_unavailable: isolated runtime cannot load provider-auth plugin; action: aidevops secret set ANTHROPIC_API_KEY\n'
	else
		printf 'auth_error: %s or missing; action: aidevops secret set ANTHROPIC_API_KEY\n' "$AUTH_ERROR_REASON"
	fi
	return 0
}

_record_auth_cooldown() {
	local reason="$1"
	local now
	now=$(date +%s 2>/dev/null || printf '0')
	mkdir -p "$(dirname "$AUTH_COOLDOWN_FILE")" 2>/dev/null || return 0
	{
		printf 'created_at=%s\n' "$now"
		printf 'cooldown_seconds=%s\n' "$(_auth_cooldown_seconds)"
		printf 'config_stamp=%s\n' "$(_auth_config_stamp)"
		printf 'reason=%s\n' "$reason"
	} >"$AUTH_COOLDOWN_FILE" 2>/dev/null || true
	return 0
}

_auth_cooldown_active() {
	[[ -f "$AUTH_COOLDOWN_FILE" ]] || return 1
	local created_at=""
	local cooldown_seconds=""
	local config_stamp=""
	local line=""
	while IFS= read -r line; do
		case "$line" in
			created_at=*) created_at="${line#created_at=}" ;;
			cooldown_seconds=*) cooldown_seconds="${line#cooldown_seconds=}" ;;
			config_stamp=*) config_stamp="${line#config_stamp=}" ;;
		esac
	done <"$AUTH_COOLDOWN_FILE"

	[[ "$created_at" =~ ^[0-9]+$ ]] || return 1
	[[ "$cooldown_seconds" =~ ^[0-9]+$ ]] || cooldown_seconds="$(_auth_cooldown_seconds)"
	if [[ "$config_stamp" != "$(_auth_config_stamp)" ]]; then
		rm -f "$AUTH_COOLDOWN_FILE" 2>/dev/null || true
		return 1
	fi

	local now
	now=$(date +%s 2>/dev/null || printf '0')
	[[ "$now" =~ ^[0-9]+$ ]] || return 1
	if [[ $((now - created_at)) -lt "$cooldown_seconds" ]]; then
		return 0
	fi
	rm -f "$AUTH_COOLDOWN_FILE" 2>/dev/null || true
	return 1
}

# Hash the CONTENT_KEY_JQ projection of one issue JSON object.
_issue_content_hash() {
	local issue_json="$1"
	local content_key=""
	content_key=$(jq -r "$CONTENT_KEY_JQ" <<<"$issue_json" 2>/dev/null) || return 1
	[[ -n "$content_key" ]] || return 1
	_hash_text "$content_key"
	return 0
}

_verdict_cache_hit() {
	local slug="$1"
	local issue_num="$2"
	local content_hash="$3"
	[[ -f "$VERDICT_CACHE_FILE" && -n "$content_hash" ]] || return 1
	awk -F'\t' -v s="$slug" -v n="$issue_num" -v h="$content_hash" \
		'$1 == s && $2 == n && $3 == h { found = 1; exit } END { exit(found ? 0 : 1) }' \
		"$VERDICT_CACHE_FILE" 2>/dev/null
	return $?
}

# Only completed YES/NO verdicts are recorded; SKIP/SKIP_AUTH must retry.
_record_verdict() {
	local slug="$1"
	local issue_num="$2"
	local content_hash="$3"
	local verdict="$4"
	[[ "${AIDEVOPS_FIX_THE_FIXER_DETECTOR_DRY_RUN:-0}" == "1" ]] && return 0
	[[ -n "$content_hash" ]] || return 0
	mkdir -p "$(dirname "$VERDICT_CACHE_FILE")" 2>/dev/null || return 0
	printf '%s\t%s\t%s\t%s\t%s\n' "$slug" "$issue_num" "$content_hash" "$verdict" "$(date +%s)" \
		>>"$VERDICT_CACHE_FILE" 2>/dev/null || return 0
	local rows=""
	rows=$(wc -l <"$VERDICT_CACHE_FILE" 2>/dev/null | tr -d ' ') || rows=""
	[[ "$rows" =~ ^[0-9]+$ && "$rows" -gt $((VERDICT_CACHE_MAX_ROWS + 500)) ]] || return 0
	local temporary=""
	temporary=$(mktemp "${VERDICT_CACHE_FILE}.XXXXXX" 2>/dev/null) || return 0
	if tail -n "$VERDICT_CACHE_MAX_ROWS" "$VERDICT_CACHE_FILE" >"$temporary" 2>/dev/null; then
		mv -f "$temporary" "$VERDICT_CACHE_FILE" 2>/dev/null || rm -f "$temporary"
	else
		rm -f "$temporary"
	fi
	return 0
}

# Print the index of the cursor slug among the arguments (0 when absent).
_cursor_start_index() {
	local cursor_slug=""
	[[ -f "$REPO_CURSOR_FILE" ]] && cursor_slug=$(head -n 1 "$REPO_CURSOR_FILE" 2>/dev/null)
	local index=0
	local candidate=""
	for candidate in "$@"; do
		if [[ -n "$cursor_slug" && "$candidate" == "$cursor_slug" ]]; then
			printf '%s\n' "$index"
			return 0
		fi
		index=$((index + 1))
	done
	printf '0\n'
	return 0
}

# Persist the slug to resume from; an empty slug means the pass completed.
_write_cursor() {
	local next_slug="$1"
	[[ "${AIDEVOPS_FIX_THE_FIXER_DETECTOR_DRY_RUN:-0}" == "1" ]] && return 0
	if [[ -z "$next_slug" ]]; then
		rm -f "$REPO_CURSOR_FILE" 2>/dev/null || true
		return 0
	fi
	mkdir -p "$(dirname "$REPO_CURSOR_FILE")" 2>/dev/null || return 0
	local temporary=""
	temporary=$(mktemp "${REPO_CURSOR_FILE}.XXXXXX" 2>/dev/null) || return 0
	if printf '%s\n' "$next_slug" >"$temporary" 2>/dev/null; then
		mv -f "$temporary" "$REPO_CURSOR_FILE" 2>/dev/null || rm -f "$temporary"
	else
		rm -f "$temporary"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Compose the binary classification prompt.
#
# Returns "YES <one-line rationale>" or "NO <one-line rationale>" — strictly
# 1 line, leading verdict token. Any other response is treated as NO
# (fail-open / fail-conservative — only annotate when the model is confident).
# ---------------------------------------------------------------------------
_compose_classification_prompt() {
	local issue_title="$1"
	local issue_body="$2"

	# Cap body length to keep token cost predictable. The first ~3KB
	# captures What/Why/How/Files Scope which is what classification needs.
	local body_truncated
	# Byte-oriented truncation, while consuming the entire producer stream.
	body_truncated="$(printf '%s' "$issue_body" | LC_ALL=C awk '{ line=$0; if (NR > 1) line="\n" line; if (remaining > 0) { printf "%s", substr(line, 1, remaining); remaining -= length(line) } }' remaining=3000)"

	cat <<EOF
You are classifying a software development task to decide whether it modifies the worker dispatch system itself.

A "fix-the-fixer" task is one where the work touches:
  - The pulse dispatch loop (pulse-wrapper.sh, pulse-dispatch-*.sh)
  - The headless runtime that spawns workers (headless-runtime-helper.sh, headless-runtime-lib.sh)
  - The worker lifecycle (worker-lifecycle-common.sh, worker-activity-watchdog.sh)
  - The dispatch dedup / claim system (dispatch-dedup-helper.sh, shared-claim-lifecycle.sh, shared-dispatch-dedup.sh)
  - Worker exit classification or stuck-detection logic
  - Shared libraries that the above transitively depend on (shared-constants.sh) IF the change affects dispatch behaviour

A non-fix-the-fixer task may touch shell scripts, framework code, docs, tests, or product code without affecting the dispatch path itself.

The risk of mis-classifying a real fix-the-fixer task as non-fix-the-fixer: the worker may be killed by the very bug it is fixing, with no visible failure mode. Six wasted opus dispatches in the canonical incident (PR #21741).

The risk of false positives: extra observability flags + tighter watchdog timeouts on a normal task. Cheap.

Be CONSERVATIVE — output YES only when you have specific evidence (file paths or behaviour described in the body that names the dispatch path).

Issue title:
${issue_title}

Issue body (truncated to 3KB):
${body_truncated}

Respond with EXACTLY one line. Format:
  YES <one-line rationale citing specific evidence>
  NO <one-line rationale>

No markdown, no quotes, no preamble. The rationale is a single sentence.
EOF
	return 0
}

# Print one "VERDICT<TAB>RATIONALE" line. Callers run the classifier in a
# command substitution, so a RATIONALE global set there never reaches them
# (GH#38673: advisories were posted with an empty rationale).
_emit_verdict() {
	local verdict="$1"
	printf '%s\t%s\n' "$verdict" "${RATIONALE:-}"
	return 0
}

# ---------------------------------------------------------------------------
# Call the LLM and parse the verdict.
#
# Output (stdout): one "VERDICT<TAB>RATIONALE" line, where VERDICT is YES, NO,
# SKIP (classifier unavailable or failed) or SKIP_AUTH (credential failure).
# Always returns 0 so `set -e` cannot abort the caller before it accounts
# for a SKIP.
# ---------------------------------------------------------------------------
_classify_via_llm() {
	local issue_title="$1"
	local issue_body="$2"
	local model="${AIDEVOPS_FIX_THE_FIXER_DETECTOR_MODEL:-simple}"

	local prompt
	prompt=$(_compose_classification_prompt "$issue_title" "$issue_body")

	if _auth_cooldown_active; then
		RATIONALE="$(_auth_failure_reason); cooldown active"
		_log_auth_skip "fix-the-fixer detector skipped: ${RATIONALE}"
		_emit_verdict SKIP_AUTH
		return 0
	fi

	if [[ ! -x "$AI_RESEARCH_HELPER" ]]; then
		RATIONALE="ai-research-helper.sh not executable — cannot classify"
		_log_warn "${RATIONALE}"
		_emit_verdict SKIP
		return 0
	fi

	# Capture stderr so we can attribute failures (missing API key,
	# rate-limit, network, etc.) in the run-summary instead of swallowing
	# them and reporting "processed N" as if classification had happened.
	# t3223: detector silent failure — LLM outage masqueraded as 100%
	# verdict=NO output for ~6h before being noticed.
	local raw=""
	local err_log
	err_log=$(mktemp -t fix-the-fixer-llm-err.XXXXXX 2>/dev/null) || err_log=""
	# Note: SKIP paths return 0 (not 1) so set -e doesn't abort cmd_check
	# before it can propagate the SKIP verdict to the caller. SKIP is a
	# valid output of this function — "I cannot classify" is itself a
	# classification result, just a different one from YES/NO.
	if [[ -n "$err_log" ]]; then
		raw=$("$AI_RESEARCH_HELPER" --model "$model" --prompt "$prompt" --max-tokens 200 2>"$err_log") || {
			local helper_rc=$?
			local err_snippet=""
			[[ -s "$err_log" ]] && err_snippet=$(head -c 2000 "$err_log" | tr '\n' ' ')
			rm -f "$err_log"
			# GH#23594: rc=2 is ai-research-helper's documented exit code for
			# "no API key resolved locally" — treat it as an auth class signal
			# regardless of the error message, so the cooldown trips even when
			# the prose message doesn't match _is_auth_error()'s API-response
			# patterns (which are tuned for invalid x-api-key / 401 responses).
			if _is_runtime_auth_error "$err_snippet" || [[ "$helper_rc" -eq 2 ]] || _is_auth_error "$err_snippet"; then
				local cooldown_reason="auth_error"
				_is_runtime_auth_error "$err_snippet" && cooldown_reason="runtime_auth_unavailable"
				_record_auth_cooldown "$cooldown_reason"
				RATIONALE="$(_auth_failure_reason)"
				_log_auth_skip "fix-the-fixer detector skipped: ${RATIONALE}"
				_emit_verdict SKIP_AUTH
				return 0
			fi
			RATIONALE="LLM call failed (model=${model}, rc=${helper_rc}): ${err_snippet:-no stderr}"
			_log_warn "${RATIONALE}"
			_emit_verdict SKIP
			return 0
		}
		rm -f "$err_log"
	else
		# mktemp unavailable — fall back to no stderr capture.
		raw=$("$AI_RESEARCH_HELPER" --model "$model" --prompt "$prompt" --max-tokens 200 2>/dev/null) || {
			RATIONALE="LLM call failed (model=${model}) — stderr capture unavailable"
			_log_warn "${RATIONALE}"
			_emit_verdict SKIP
			return 0
		}
	fi

	# First non-empty line is the verdict.
	local first_line
	first_line=$(printf '%s\n' "$raw" | awk 'NF && !found { print; found=1 }')
	if [[ -z "$first_line" ]]; then
		RATIONALE="empty LLM output (model=${model}) — cannot classify"
		_log_warn "${RATIONALE}"
		_emit_verdict SKIP
		return 0
	fi

	# Parse verdict + rationale. Be lenient on whitespace and case.
	local verdict_token
	verdict_token=$(printf '%s' "$first_line" | awk '{ print toupper($1) }')
	RATIONALE=$(printf '%s' "$first_line" | sed -E 's/^[[:space:]]*[Yy][Ee][Ss][[:space:]:.,-]*//;s/^[[:space:]]*[Nn][Oo][[:space:]:.,-]*//')
	[[ -z "$RATIONALE" ]] && RATIONALE="(no rationale provided)"

	case "$verdict_token" in
		YES|YES.|YES,)
			_emit_verdict YES
			;;
		*)
			# Anything not-YES is treated as NO (conservative — only
			# annotate when confident).
			_emit_verdict NO
			;;
	esac
	return 0
}

# ---------------------------------------------------------------------------
# Apply the label + post advisory comment. Idempotent via marker.
# ---------------------------------------------------------------------------
_ensure_fix_the_fixer_label() {
	local slug="$1"
	local api_out=""

	# Direct lookup (not a paged listing, which misses labels past the first page).
	if api_out=$(gh api "repos/${slug}/labels/${FIX_THE_FIXER_LABEL}" 2>&1); then
		return 0
	fi
	if [[ "$api_out" != *404* && "$api_out" != *"Not Found"* ]]; then
		_log_warn "failed to inspect labels in ${slug}; skipping classification"
		return 1
	fi
	if ! gh label create "$FIX_THE_FIXER_LABEL" --repo "$slug" \
		--color "$FIX_THE_FIXER_LABEL_COLOR" \
		--description "$FIX_THE_FIXER_LABEL_DESCRIPTION" >/dev/null 2>&1; then
		_log_warn "failed to create ${FIX_THE_FIXER_LABEL} in ${slug}; skipping classification"
		return 1
	fi
	_log_info "created ${FIX_THE_FIXER_LABEL} label in ${slug}"
	return 0
}

_apply_label_and_comment() {
	local issue_num="$1"
	local slug="$2"
	local rationale="$3"

	if [[ "${AIDEVOPS_FIX_THE_FIXER_DETECTOR_DRY_RUN:-0}" == "1" ]]; then
		_log_info "[dry-run] would apply ${FIX_THE_FIXER_LABEL} on ${slug}#${issue_num}: ${rationale}"
		return 0
	fi

	# Apply label (best-effort; ignore if already present).
	gh issue edit "$issue_num" --repo "$slug" \
		--add-label "$FIX_THE_FIXER_LABEL" >/dev/null 2>&1 || {
		_log_warn "failed to apply ${FIX_THE_FIXER_LABEL} on ${slug}#${issue_num}"
		return 1
	}

	# Idempotency check — skip comment if marker already present.
	local existing=""
	existing=$(gh api "repos/${slug}/issues/${issue_num}/comments" \
		--jq "[.[] | select(.body | contains(\"${FIX_THE_FIXER_MARKER}\"))] | length" \
		2>/dev/null) || existing=""
	if [[ "$existing" =~ ^[1-9][0-9]*$ ]]; then
		_log_info "advisory already present on ${slug}#${issue_num}; label re-applied"
		return 0
	fi

	# Post advisory comment via signed wrapper.
	local comment_body="${FIX_THE_FIXER_MARKER}
## Fix-the-Fixer Classification Applied (t3077)

This issue has been classified as a **fix-the-fixer** task — the work touches the worker dispatch system itself. Workers dispatched on this issue will run with extra observability:

- \`AIDEVOPS_VERBOSE_LIFECYCLE=1\` — emits 5+ lifecycle checkpoints visible in pulse.log.
- \`WORKER_STALL_TIMEOUT=180\` — tighter watchdog (vs 300s default) so silent failure is caught faster.
- \`AIDEVOPS_WORKER_PREFLIGHT_SENTINEL=1\` — worker writes a preflight sentinel before opencode launches; aborts dispatch with clear error if write fails (catches sandbox/FD issues before model invocation).

**Rationale:** ${rationale}

If this classification is wrong, remove the \`${FIX_THE_FIXER_LABEL}\` label and the next worker will dispatch with default settings.

_Automated by \`pulse-fix-the-fixer-detector.sh\` (t3077). Idempotent via the \`${FIX_THE_FIXER_MARKER}\` marker; re-runs on a labelled issue are no-ops._"

	# Use the wrapper if available so the signature is auto-injected.
	if command -v gh_issue_comment >/dev/null 2>&1; then
		gh_issue_comment "$issue_num" --repo "$slug" --body "$comment_body" \
			>/dev/null 2>&1 || _log_warn "advisory comment post failed on ${slug}#${issue_num}"
	else
		# shellcheck source=/dev/null
		source "${SCRIPT_DIR}/shared-gh-wrappers.sh" 2>/dev/null || true
		if command -v gh_issue_comment >/dev/null 2>&1; then
			gh_issue_comment "$issue_num" --repo "$slug" --body "$comment_body" \
				>/dev/null 2>&1 || _log_warn "advisory comment post failed on ${slug}#${issue_num}"
		else
			_log_warn "shared-gh-wrappers.sh not found; advisory comment skipped (label still applied)"
		fi
	fi

	_log_info "applied ${FIX_THE_FIXER_LABEL} + advisory on ${slug}#${issue_num}"
	return 0
}

# ---------------------------------------------------------------------------
# Check a single issue. Classification skips remain non-blocking; write
# prerequisite or label-application failures return 1 for run accounting.
# ---------------------------------------------------------------------------
cmd_check() {
	local issue_num="$1"
	local slug="$2"

	[[ "$issue_num" =~ ^[0-9]+$ ]] || {
		_log_warn "invalid issue number: ${issue_num}"
		return 0
	}
	[[ -n "$slug" ]] || {
		_log_warn "empty slug"
		return 0
	}

	local issue_json
	issue_json=$(gh issue view "$issue_num" --repo "$slug" \
		--json title,body,labels,state 2>/dev/null) || {
		_log_warn "gh issue view failed for ${slug}#${issue_num}"
		return 0
	}

	# Skip closed issues.
	local state
	state=$(printf '%s' "$issue_json" | jq -r --arg D "$ISSUE_STATE_OPEN" '.state // $D' 2>/dev/null) || state="$ISSUE_STATE_OPEN"
	[[ "$state" != "$ISSUE_STATE_OPEN" ]] && return 0

	# Skip if already labeled (idempotent).
	local has_label
	has_label=$(printf '%s' "$issue_json" | \
		jq -r --arg L "$FIX_THE_FIXER_LABEL" \
		'[.labels[].name] | any(. == $L)' 2>/dev/null) || has_label="false"
	if [[ "$has_label" == "true" ]]; then
		_log_info "${slug}#${issue_num} already labeled — skipping"
		return 0
	fi

	# Must carry auto-dispatch (otherwise dispatch path won't fire anyway).
	local has_auto
	has_auto=$(printf '%s' "$issue_json" | \
		jq -r '[.labels[].name] | any(. == "auto-dispatch")' 2>/dev/null) || has_auto="false"
	if [[ "$has_auto" != "true" ]]; then
		return 0
	fi

	local title="" body=""
	title=$(printf '%s' "$issue_json" | jq -r '.title // ""' 2>/dev/null) || title=""
	body=$(printf '%s' "$issue_json" | jq -r '.body // ""' 2>/dev/null) || body=""
	if [[ -z "$body" ]]; then
		_log_info "${slug}#${issue_num} has empty body — skipping"
		return 0
	fi

	# Classify.
	# Return semantics (t3223 — detector silent failure fix):
	#   exit 0 + verdict=YES  → classified, label applied
	#   exit 0 + verdict=NO   → classified, no action
	#   exit 1 + verdict=YES  → classified, label prerequisite/apply failed
	#   exit 2 + verdict=SKIP → LLM unavailable, NOT classified — caller
	#                            must surface this in run summary
	#   exit 0 (other paths)  → skipped pre-classification (closed,
	#                            already labeled, no body, no auto-dispatch)
	# Completed verdicts (NO, and YES once the label is applied) are cached
	# against the content hash so `run` does not classify them again.
	local content_hash=""
	content_hash=$(_issue_content_hash "$issue_json") || content_hash=""
	RATIONALE=""
	local classification="" verdict=""
	classification=$(_classify_via_llm "$title" "$body") || classification=""
	verdict="${classification%%$'\t'*}"
	[[ "$classification" == *$'\t'* ]] && RATIONALE="${classification#*$'\t'}"
	if [[ -z "$verdict" ]]; then
		verdict="SKIP"
		RATIONALE="classifier produced no verdict"
	fi
	if [[ "$verdict" == "SKIP_AUTH" ]]; then
		[[ -n "$RATIONALE" ]] || RATIONALE="$(_auth_failure_reason)"
		_log_auth_skip "${slug}#${issue_num} classification skipped — ${RATIONALE}"
		return 3
	fi
	if [[ "$verdict" == "SKIP" ]]; then
		_log_warn "${slug}#${issue_num} classification skipped — ${RATIONALE}"
		return 2
	fi
	if [[ "$verdict" != "YES" ]]; then
		_log_info "${slug}#${issue_num} verdict=NO ${RATIONALE}"
		_record_verdict "$slug" "$issue_num" "$content_hash" "NO"
		return 0
	fi

	_log_info "${slug}#${issue_num} verdict=YES ${RATIONALE}"
	_ensure_fix_the_fixer_label "$slug" || return 1
	_apply_label_and_comment "$issue_num" "$slug" "$RATIONALE" || return 1
	# A cached YES is never re-applied: if a maintainer later removes the
	# label from unchanged content, that removal stands.
	_record_verdict "$slug" "$issue_num" "$content_hash" "YES"
	return 0
}

# Run accounting shared by cmd_run and _scan_repo (reset per run).
_RUN_PROCESSED=0
_RUN_CLASSIFIED=0
_RUN_APPLY_FAILED=0
_RUN_SKIPPED_LLM=0
_RUN_SKIPPED_AUTH=0
_RUN_CACHED=0
_RUN_LIMIT=10
_RUN_BUDGET="$RUN_BUDGET_SECONDS_DEFAULT"
_RUN_STARTED_AT=0
_RUN_STOP_REASON=""

_log_run_summary() {
	local repo_count="$1"
	local repos_scanned="$2"
	local processed="$_RUN_PROCESSED" classified="$_RUN_CLASSIFIED"
	local apply_failed="$_RUN_APPLY_FAILED" skipped_auth="$_RUN_SKIPPED_AUTH"
	local skipped_llm="$_RUN_SKIPPED_LLM" cached="$_RUN_CACHED"
	local stop_reason="${_RUN_STOP_REASON:-complete}"
	# Atomic, credential-free evidence for pulse-check; successful/empty runs
	# replace prior degradation instead of leaving a stale alarm behind.
	local status_file="${HOME}/.aidevops/cache/fix-the-fixer-detector-status.json"
	local temporary=""
	mkdir -p "$(dirname "$status_file")" 2>/dev/null || true
	temporary=$(mktemp "${status_file}.XXXXXX") || temporary=""
	if [[ -n "$temporary" ]]; then
		if jq -n --argjson timestamp "$(date +%s)" --argjson processed "$processed" \
			--argjson classified "$classified" --argjson skipped_auth "$skipped_auth" \
			--argjson cached "$cached" --argjson repo_count "$repo_count" \
			--argjson repos_scanned "$repos_scanned" --arg stop_reason "$stop_reason" \
			--arg reason "$(_auth_failure_reason)" \
			'{timestamp:$timestamp,processed:$processed,classified:$classified,skipped_auth:$skipped_auth,cached:$cached,repo_count:$repo_count,repos_scanned:$repos_scanned,stop_reason:$stop_reason,budget_exhausted:($stop_reason == "budget"),reason:(if $skipped_auth > 0 then $reason else "" end)}' >"$temporary"; then
			mv -f "$temporary" "$status_file" 2>/dev/null || rm -f "$temporary"
		else
			rm -f "$temporary"
		fi
	fi
	local counts="processed ${processed} issue(s) across ${repo_count} repo(s) — classified=${classified}, apply-failed=${apply_failed}, skipped:auth-error=${skipped_auth}, skipped:LLM-failure=${skipped_llm}, cached=${cached}, scanned=${repos_scanned}/${repo_count} repo(s), stop=${stop_reason}"
	if [[ "$skipped_auth" -gt 0 ]]; then
		_log_warn "${counts} (DEGRADED capability: detector observability degraded; $(_auth_failure_reason))"
	elif [[ "$skipped_llm" -gt 0 ]]; then
		_log_warn "${counts} (detector observability degraded; check ai-research-helper.sh / API credentials)"
	elif [[ "$apply_failed" -gt 0 ]]; then
		_log_warn "${counts} (detector writes degraded; inspect preceding GitHub label/comment errors)"
	else
		_log_info "$counts"
	fi
	return 0
}

_run_reset() {
	local limit="$1"
	local budget="$2"
	_RUN_PROCESSED=0
	_RUN_CLASSIFIED=0
	_RUN_APPLY_FAILED=0
	_RUN_SKIPPED_LLM=0
	_RUN_SKIPPED_AUTH=0
	_RUN_CACHED=0
	_RUN_LIMIT="$limit"
	_RUN_BUDGET="$budget"
	_RUN_STARTED_AT="$SECONDS"
	_RUN_STOP_REASON=""
	return 0
}

# Return 0 (and record why) when the run must stop taking new work.
_run_should_stop() {
	if [[ "$_RUN_PROCESSED" -ge "$_RUN_LIMIT" ]]; then
		_RUN_STOP_REASON="limit"
		return 0
	fi
	if [[ $((SECONDS - _RUN_STARTED_AT)) -ge "$_RUN_BUDGET" ]]; then
		_RUN_STOP_REASON="budget"
		return 0
	fi
	return 1
}

# Classify one repository's uncached candidates. Returns 1 when the run
# stopped mid-repository, so the cursor resumes here next time.
_scan_repo() {
	local slug="$1"
	# Title and body come with the list, so cached issues need no per-issue
	# view and no LLM call.
	local issues_json=""
	issues_json=$(gh issue list --repo "$slug" \
		--label "auto-dispatch" \
		--state open --limit 30 \
		--json number,title,body,labels 2>/dev/null) || return 0
	local rows=""
	rows=$(jq -r --arg L "$FIX_THE_FIXER_LABEL" \
		'.[] | select([.labels[].name] | any(. == $L) | not) | select((.body // "") != "") | [(.number | tostring), '"$CONTENT_KEY_JQ"'] | @tsv' \
		<<<"$issues_json" 2>/dev/null) || rows=""
	[[ -n "$rows" ]] || return 0

	local -a pending=()
	local issue_num="" content_key="" content_hash=""
	while IFS=$'\t' read -r issue_num content_key; do
		[[ "$issue_num" =~ ^[0-9]+$ && -n "$content_key" ]] || continue
		content_hash=$(_hash_text "$content_key")
		if _verdict_cache_hit "$slug" "$issue_num" "$content_hash"; then
			_RUN_CACHED=$((_RUN_CACHED + 1))
			continue
		fi
		pending+=("$issue_num")
	done <<<"$rows"
	[[ "${#pending[@]}" -gt 0 ]] || return 0
	_ensure_fix_the_fixer_label "$slug" || return 0

	for issue_num in "${pending[@]}"; do
		_run_should_stop && return 1
		# `set -e` is on; capture rc explicitly so cmd_check's
		# exit 2 (LLM SKIP) doesn't kill the loop.
		local rc=0
		cmd_check "$issue_num" "$slug" || rc=$?
		case "$rc" in
			3) _RUN_SKIPPED_AUTH=$((_RUN_SKIPPED_AUTH + 1)) ;;
			2) _RUN_SKIPPED_LLM=$((_RUN_SKIPPED_LLM + 1)) ;;
			1) _RUN_APPLY_FAILED=$((_RUN_APPLY_FAILED + 1)) ;;
			*) _RUN_CLASSIFIED=$((_RUN_CLASSIFIED + 1)) ;;
		esac
		_RUN_PROCESSED=$((_RUN_PROCESSED + 1))
	done
	return 0
}

# ---------------------------------------------------------------------------
# Iterate pulse-enabled repos, fetch unlabeled auto-dispatch issues, classify.
# Cached verdicts, the run budget and the repo cursor keep every hourly run
# inside the Pulse stage bound while still advancing through all repos.
# ---------------------------------------------------------------------------
cmd_run() {
	local repo_filter=""
	local limit="${AIDEVOPS_FIX_THE_FIXER_DETECTOR_LIMIT:-10}"
	local dry_run="${AIDEVOPS_FIX_THE_FIXER_DETECTOR_DRY_RUN:-0}"

	# Iterate args as named locals (the codebase ratchet flags direct
	# positional-parameter use inside loops and function bodies).
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		local arg_value="${2:-}"
		case "$arg" in
			--repo) repo_filter="$arg_value"; shift 2 ;;
			--limit) limit="$arg_value"; shift 2 ;;
			--dry-run) dry_run=1; shift ;;
			*) shift ;;
		esac
	done

	[[ "$limit" =~ ^[0-9]+$ ]] || limit=10
	local budget="${AIDEVOPS_FIX_THE_FIXER_DETECTOR_BUDGET_SECONDS:-$RUN_BUDGET_SECONDS_DEFAULT}"
	[[ "$budget" =~ ^[1-9][0-9]*$ ]] || budget="$RUN_BUDGET_SECONDS_DEFAULT"
	export AIDEVOPS_FIX_THE_FIXER_DETECTOR_DRY_RUN="$dry_run"

	if [[ "${AIDEVOPS_FIX_THE_FIXER_DETECTOR_DISABLE:-0}" == "1" ]]; then
		_log_info "AIDEVOPS_FIX_THE_FIXER_DETECTOR_DISABLE=1 — bypassing run"
		return 0
	fi

	# Resolve target repos.
	local -a target_repos=()
	if [[ -n "$repo_filter" ]]; then
		target_repos=("$repo_filter")
	elif [[ -f "$REPOS_JSON" ]]; then
		# Iterate pulse-enabled, non-local-only repos whose local checkout
		# contains the dispatch system.
		local repos_str
		repos_str=$(jq -r '.initialized_repos[]? | select(.maintenance != false) | select(.pulse == true) | select((.local_only // false) == false) | [.slug, (.path // "")] | @tsv' "$REPOS_JSON" 2>/dev/null) || repos_str=""
		local r="" repo_path=""
		while IFS=$'\t' read -r r repo_path; do
			[[ -n "$r" && -n "$repo_path" ]] || continue
			repo_path="${repo_path/#\~/$HOME}"
			[[ -f "${repo_path}/${DISPATCH_SYSTEM_MARKER}" ]] && target_repos+=("$r")
		done <<<"$repos_str"
	fi

	if [[ "${#target_repos[@]}" -eq 0 ]]; then
		_log_info "no target repos resolved — exiting"
		return 0
	fi

	# Track classified vs skipped separately so a 100% LLM outage doesn't
	# masquerade as "processed N issues" — the failure mode this whole
	# fix exists to surface (t3223).
	_run_reset "$limit" "$budget"
	export AIDEVOPS_FIX_THE_FIXER_DETECTOR_SUPPRESS_AUTH_ITEM_LOGS=1
	local repo_total="${#target_repos[@]}"
	local start_index=0
	[[ -n "$repo_filter" ]] || start_index=$(_cursor_start_index "${target_repos[@]}")
	local offset=0 repos_scanned=0 slug="" next_slug=""
	while [[ "$offset" -lt "$repo_total" ]]; do
		slug="${target_repos[$(((start_index + offset) % repo_total))]}"
		if _run_should_stop || ! _scan_repo "$slug"; then
			next_slug="$slug"
			break
		fi
		repos_scanned=$((repos_scanned + 1))
		offset=$((offset + 1))
	done
	if [[ -z "$repo_filter" ]]; then
		_write_cursor "$next_slug"
	fi

	_log_run_summary "$repo_total" "$repos_scanned"
	return 0
}

cmd_help() {
	cat <<'EOF'
pulse-fix-the-fixer-detector.sh — LLM-driven detector for dispatch-system tasks (t3077).

Usage:
  pulse-fix-the-fixer-detector.sh run [--repo OWNER/REPO] [--limit N] [--dry-run]
  pulse-fix-the-fixer-detector.sh check <issue-number> <slug>
  pulse-fix-the-fixer-detector.sh help

Commands:
  run      Iterate pulse-enabled repos (or single --repo), classify pending
           auto-dispatch issues, apply fix-the-fixer label + advisory on YES.
  check    Classify a single issue.
  help     Print this message.

Flags:
  --repo OWNER/REPO     Limit run to one repo (default: pulse-enabled repos
                        whose checkout contains the dispatch system).
  --limit N             Cap LLM classifications per run (default: 10).
  --dry-run             Classify but do not apply labels, comments or
                        cache/cursor state.

Exit codes:
  0   Always (non-blocking by design).

Bypass:
  AIDEVOPS_FIX_THE_FIXER_DETECTOR_DISABLE=1   — exit 0 immediately
  AIDEVOPS_FIX_THE_FIXER_DETECTOR_DRY_RUN=1   — same as --dry-run

Tunables:
  AIDEVOPS_FIX_THE_FIXER_DETECTOR_MODEL           (default: simple)
  AIDEVOPS_FIX_THE_FIXER_DETECTOR_LIMIT           (default: 10)
  AIDEVOPS_FIX_THE_FIXER_DETECTOR_BUDGET_SECONDS  (default: 40; keep below
                                                   the 60s Pulse stage bound)
EOF
	return 0
}

main() {
	local subcmd="${1:-help}"
	shift || true

	case "$subcmd" in
		run)   cmd_run "$@" ;;
		check)
			if [[ $# -lt 2 ]]; then
				_log "ERROR" "check requires <issue-number> <slug>"
				return 2
			fi
			# Assign positionals to named locals (codebase ratchet flags
			# direct $1/$2 use inside function bodies).
			local _check_issue="$1"
			local _check_slug="$2"
			cmd_check "$_check_issue" "$_check_slug"
			;;
		help|--help|-h) cmd_help ;;
		*)
			_log "ERROR" "unknown subcommand: ${subcmd}"
			cmd_help >&2
			return 2
			;;
	esac
}

if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
	main "$@"
fi
