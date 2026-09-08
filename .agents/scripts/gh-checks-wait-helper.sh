#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# gh-checks-wait-helper.sh - Delta-aware required-check polling for AI sessions

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

LOG_PREFIX="GH-CHECKS-WAIT"
_GCW_DEFAULT_TIMEOUT="${AIDEVOPS_GH_CHECKS_TIMEOUT_SECONDS:-1800}"
_GCW_DEFAULT_INITIAL_INTERVAL="${AIDEVOPS_GH_CHECKS_INITIAL_INTERVAL_SECONDS:-15}"
_GCW_DEFAULT_MAX_INTERVAL="${AIDEVOPS_GH_CHECKS_MAX_INTERVAL_SECONDS:-120}"
_GCW_DEFAULT_HEARTBEAT_INTERVAL="${AIDEVOPS_GH_CHECKS_HEARTBEAT_SECONDS:-120}"
readonly _GCW_BUCKET_PASS="pass" _GCW_BUCKET_PENDING="pending" _GCW_BUCKET_SKIPPING="skipping"
_GCW_ACTIVE_DEFERRAL=""
_GCW_API_ERROR_VISIBLE=0
_GCW_NEXT_INTERVAL=""

usage() {
	cat <<'EOF'
Usage:
  gh-checks-wait-helper.sh wait PR_NUMBER [options]

Options:
  --repo OWNER/REPO          Repository (auto-detected when omitted)
  --all                      Include optional checks (default: required only)
  --timeout SECONDS          Overall timeout (default: 1800)
  --initial-interval SECONDS First and post-transition poll interval (default: 15)
  --max-interval SECONDS     Maximum unchanged-state interval (default: 120)
  --heartbeat SECONDS        Sparse unchanged-state message interval (default: 120)

The initial state is printed once. Later polls emit only state transitions,
sparse heartbeats, and the terminal result. Pending timeouts return exit 8,
terminal failures return exit 1, and indeterminate API failures return exit 2.
EOF
	return 0
}

validate_nonnegative_integer() {
	local value="$1"
	[[ "$value" =~ ^[0-9]+$ ]]
	return $?
}

validate_positive_integer() {
	local value="$1"
	[[ "$value" =~ ^[1-9][0-9]*$ ]]
	return $?
}

resolve_repo() {
	local repo="$1"
	if [[ -n "$repo" ]]; then
		printf '%s\n' "$repo"
		return 0
	fi
	gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null
	return $?
}

fixture_for_poll() {
	local fixture_dir="$1"
	local poll_number="$2"
	local requested="${fixture_dir}/poll-${poll_number}.json"
	if [[ -f "$requested" ]]; then
		printf '%s\n' "$requested"
		return 0
	fi
	local candidate=""
	local path=""
	for path in "${fixture_dir}"/poll-*.json; do
		[[ -f "$path" ]] || continue
		candidate="$path"
	done
	[[ -n "$candidate" ]] || return 1
	printf '%s\n' "$candidate"
	return 0
}

fetch_checks() {
	local pr_number="$1"
	local repo="$2"
	local required_only="$3"
	local poll_number="$4"
	local expected_head_sha="$5"
	local fixture_dir="${AIDEVOPS_GH_CHECKS_FIXTURE_DIR:-}"
	if [[ -n "$fixture_dir" ]]; then
		local fixture=""
		fixture=$(fixture_for_poll "$fixture_dir" "$poll_number") || return 1
		python3 - "$fixture" <<'PY'
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    sys.stdout.write(source.read())
PY
		return 0
	fi
	local selection_mode="all"
	if [[ "$required_only" -eq 1 ]]; then
		selection_mode="required"
	fi
	local rc=0
	local checks=""
	local checks_stderr=""
	local checks_stderr_file=""
	checks_stderr_file=$(mktemp "${TMPDIR:-/tmp}/aidevops-gh-checks-wait.XXXXXX") || return 1
	if declare -F gh_pr_checks_observed_json >/dev/null 2>&1; then
		checks=$(gh_pr_checks_observed_json "$repo" "$pr_number" "$selection_mode" "$expected_head_sha" \
			2>"$checks_stderr_file") || rc=$?
	else
		checks=$(gh_pr_checks_exact_json "$repo" "$pr_number" "$selection_mode" "$expected_head_sha" \
			2>"$checks_stderr_file") || rc=$?
	fi
	checks_stderr=$(<"$checks_stderr_file")
	rm -f "$checks_stderr_file"
	if [[ "$required_only" -eq 1 && "$rc" -eq 1 && -z "$checks" && "$checks_stderr" =~ ^no\ required\ checks\ reported\ on\ the\ \'[^\']+\'\ branch$ ]]; then
		printf '[]\n'
		return 0
	fi
	if [[ -n "$checks_stderr" ]]; then
		printf '%s\n' "$checks_stderr" >&2
		return "$rc"
	fi
	if [[ "$rc" -eq 0 || "$rc" -eq 1 || "$rc" -eq 8 ]]; then
		printf '%s' "$checks"
		return 0
	fi
	return "$rc"
}

current_epoch() {
	if [[ "${AIDEVOPS_GH_CHECKS_TEST_NOW_EPOCH:-}" =~ ^[0-9]+$ ]]; then
		printf '%s\n' "$AIDEVOPS_GH_CHECKS_TEST_NOW_EPOCH"
		return 0
	fi
	date +%s
	return $?
}

classify_fetch_diagnostic() {
	local diagnostic="$1"
	local deadline="unknown"
	if [[ "$diagnostic" == *"error_kind=github-api-read-deferred attempted=false deferred_by=local_admission "* ]]; then
		[[ ! "$diagnostic" =~ retry_at=([0-9]+([.][0-9]+)?) ]] || deadline="${BASH_REMATCH[1]}"
		printf 'local-admission\t%s\n' "$deadline"
		return 0
	fi
	if [[ "$diagnostic" == *"error_kind=github-api-cooldown"* ]]; then
		[[ ! "$diagnostic" =~ expires_at=([0-9]+([.][0-9]+)?) ]] || deadline="${BASH_REMATCH[1]}"
		printf 'cooldown\t%s\n' "$deadline"
		return 0
	fi
	if [[ "$diagnostic" == *"malformed"* || "$diagnostic" == *"partial"* ||
		"$diagnostic" == *"incomplete"* || "$diagnostic" == *"aggregation failed"* ]]; then
		printf 'malformed\tunknown\n'
		return 0
	fi
	if [[ "$diagnostic" == *"attempted=true"* ]]; then
		printf 'api-failure\tunknown\n'
		return 0
	fi
	printf 'unavailable\tunknown\n'
	return 0
}

deferral_delay() {
	local deadline="$1" now_epoch="$2" remaining="$3"
	local jitter="${AIDEVOPS_GH_CHECKS_DEFERRAL_JITTER_SECONDS:-$((RANDOM % 3))}"
	[[ "$jitter" =~ ^[0-5]$ ]] || jitter=0
	python3 - "$deadline" "$now_epoch" "$remaining" "$jitter" <<'PY'
import math
import sys

try:
    deadline = float(sys.argv[1])
    now = int(sys.argv[2])
    remaining = int(sys.argv[3])
    jitter = int(sys.argv[4])
except (ValueError, IndexError):
    raise SystemExit(2)

if not math.isfinite(deadline):
    raise SystemExit(2)
delay = max(0, math.ceil(deadline - now)) + jitter
if delay >= remaining:
    raise SystemExit(2)
print(delay)
PY
	return $?
}

handle_unavailable_fetch() {
	local diagnostic="$1" elapsed="$2" timeout="$3" now_epoch="$4"
	local interval="$5" max_interval="$6"
	local fetch_kind="" fetch_deadline="unknown" classification="" delay="" remaining=0 deferral_key=""
	classification=$(classify_fetch_diagnostic "$diagnostic")
	IFS=$'\t' read -r fetch_kind fetch_deadline <<<"$classification"
	if [[ ("$fetch_kind" == "local-admission" || "$fetch_kind" == "cooldown") && "$fetch_deadline" != "unknown" ]]; then
		remaining=$((timeout - elapsed))
		delay=$(deferral_delay "$fetch_deadline" "$now_epoch" "$remaining" 2>/dev/null || true)
		if [[ -z "$delay" ]]; then
			printf 'INDETERMINATE: GitHub check observation deferred until %s beyond the remaining %ss timeout\n' "$fetch_deadline" "$remaining" >&2
			return 2
		fi
		deferral_key="${fetch_kind}:${fetch_deadline}"
		if [[ "$_GCW_ACTIVE_DEFERRAL" != "$deferral_key" ]]; then
			printf 'GitHub check observation deferred by %s until epoch %s; pausing without intermediate calls\n' "$fetch_kind" "$fetch_deadline" >&2
			_GCW_ACTIVE_DEFERRAL="$deferral_key"
		fi
		poll_sleep "$delay"
		_GCW_NEXT_INTERVAL="$interval"
		return 0
	fi
	if [[ "$_GCW_API_ERROR_VISIBLE" -eq 0 ]]; then
		case "$fetch_kind" in
		malformed) printf 'WARN: required-check evidence was malformed; retaining the last verified state and retrying\n' >&2 ;;
		api-failure) printf 'WARN: attempted GitHub/API read failed; retaining the last verified state and retrying\n' >&2 ;;
		*) printf 'WARN: required-check state unavailable; retaining the last verified state and retrying\n' >&2 ;;
		esac
		_GCW_API_ERROR_VISIBLE=1
	fi
	if [[ "$elapsed" -ge "$timeout" ]]; then
		printf 'INDETERMINATE: required-check state unavailable after %ss\n' "$elapsed" >&2
		return 2
	fi
	poll_sleep "$interval"
	_GCW_NEXT_INTERVAL=$(next_interval "$interval" "$max_interval")
	return 0
}

canonicalize_checks() {
	local raw="$1"
	printf '%s' "$raw" | jq -c '
		if type != "array" then error("checks result is not an array") else . end
		| map({name:(.name // "unnamed"), workflow:(.workflow // ""), state:(.state // "unknown"), bucket:(.bucket // "unknown"), link:(.link // "")})
		| sort_by(.workflow, .name, .link)
	' 2>/dev/null
	return $?
}

state_counts() {
	local checks="$1"
	printf '%s' "$checks" | jq -r '
		group_by(.bucket)
		| map("\(.[0].bucket)=\(length)")
		| if length == 0 then "none=0" else join(" ") end
	'
	return 0
}

emit_initial_state() {
	local checks="$1"
	printf 'CI wait started: %s\n' "$(state_counts "$checks")"
	printf '%s' "$checks" | jq -r '.[] | "  \(.name): \(.bucket)"'
	return 0
}

emit_transitions() {
	local previous="$1"
	local current="$2"
	jq -nr --argjson previous "$previous" --argjson current "$current" '
		def keyed:
			map(. + {key: ((.workflow // "") + "|" + .name + "|" + (.link // ""))})
			| map({key:.key, value:.}) | from_entries;
		($previous | keyed) as $before
		| ($current | keyed) as $after
		| (($before | keys) + ($after | keys) | unique[]) as $key
		| ($before[$key] // null) as $old
		| ($after[$key] // null) as $new
		| if $old == null then "+ \($new.name): added as \($new.bucket)"
		  elif $new == null then "- \($old.name): removed"
		  elif $old.bucket != $new.bucket or $old.state != $new.state then
			"+ \($new.name): \($old.bucket) -> \($new.bucket)"
		  else empty end
	'
	return 0
}

classify_state() {
	local checks="$1"
	local required_only="$2"
	local count=""
	count=$(printf '%s' "$checks" | jq 'length')
	if [[ "$count" -eq 0 ]]; then
		if [[ "$required_only" -eq 1 ]]; then
			printf 'no-required\n'
		else
			printf 'no-checks\n'
		fi
		return 0
	fi
	if printf '%s' "$checks" | jq -e --arg pass "$_GCW_BUCKET_PASS" --arg pending "$_GCW_BUCKET_PENDING" --arg skipping "$_GCW_BUCKET_SKIPPING" \
		'any(.[]; .bucket != $pass and .bucket != $pending and .bucket != $skipping)' >/dev/null; then
		printf 'failure\n'
		return 0
	fi
	if printf '%s' "$checks" | jq -e --arg pass "$_GCW_BUCKET_PASS" --arg skipping "$_GCW_BUCKET_SKIPPING" \
		'all(.[]; .bucket == $pass or .bucket == $skipping)' >/dev/null; then
		printf 'success\n'
		return 0
	fi
	printf 'pending\n'
	return 0
}

emit_failure_details() {
	local checks="$1"
	printf 'FAIL: required checks reached a terminal failure\n'
	printf '%s' "$checks" | jq -r --arg pass "$_GCW_BUCKET_PASS" --arg pending "$_GCW_BUCKET_PENDING" --arg skipping "$_GCW_BUCKET_SKIPPING" \
		'.[] | select(.bucket != $pass and .bucket != $pending and .bucket != $skipping) | "  \(.name): \(.bucket)\(if .link == "" then "" else " " + .link end)"'
	return 0
}

emit_success_details() {
	local classification="$1"
	local required_only="$2"
	local elapsed="$3"
	local checks="$4"
	case "$classification" in
	no-required)
		printf 'PASS: verified no required checks; optional checks were not evaluated (use --all to wait for all checks) in %ss (%s)\n' "$elapsed" "$(state_counts "$checks")"
		;;
	no-checks)
		printf 'PASS: verified no checks reported in %ss (%s)\n' "$elapsed" "$(state_counts "$checks")"
		;;
	success)
		if [[ "$required_only" -eq 1 ]]; then
			printf 'PASS: required checks completed in %ss (%s)\n' "$elapsed" "$(state_counts "$checks")"
		else
			printf 'PASS: all checks completed in %ss (%s)\n' "$elapsed" "$(state_counts "$checks")"
		fi
		;;
	esac
	return 0
}

read_head_sha() {
	local pr_number="$1"
	local repo="$2"
	if [[ -n "${AIDEVOPS_GH_CHECKS_TEST_HEAD+x}" ]]; then
		printf '%s\n' "$AIDEVOPS_GH_CHECKS_TEST_HEAD"
		return 0
	fi
	gh pr view "$pr_number" --repo "$repo" --json headRefOid --jq '.headRefOid // empty' 2>/dev/null
	return $?
}

write_runtime_heartbeat() {
	local heartbeat_file="${AIDEVOPS_FULL_LOOP_HEARTBEAT_FILE:-}"
	[[ -n "$heartbeat_file" ]] || return 0
	local run_id="${AIDEVOPS_FULL_LOOP_RUN_ID:-gh-checks-wait}"
	local timestamp=""
	timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
	printf '%s %s\n' "$run_id" "$timestamp" >"${heartbeat_file}.tmp.$$" 2>/dev/null || return 0
	mv "${heartbeat_file}.tmp.$$" "$heartbeat_file" 2>/dev/null || true
	return 0
}

poll_sleep() {
	local seconds="$1"
	if [[ "${AIDEVOPS_GH_CHECKS_TEST_NO_SLEEP:-0}" == "1" ]]; then
		if [[ -n "${AIDEVOPS_GH_CHECKS_TEST_SLEEP_LOG:-}" ]]; then
			printf '%s\n' "$seconds" >>"$AIDEVOPS_GH_CHECKS_TEST_SLEEP_LOG"
		fi
		return 0
	fi
	sleep "$seconds"
	return 0
}

next_interval() {
	local current="$1"
	local maximum="$2"
	local next=$((current * 2))
	[[ "$next" -le "$maximum" ]] || next="$maximum"
	printf '%s\n' "$next"
	return 0
}

wait_for_checks() {
	local pr_number="$1" repo="$2" required_only="$3" timeout="$4"
	local initial_interval="$5" max_interval="$6" heartbeat_interval="$7"
	local start_epoch=""
	start_epoch=$(current_epoch)
	local next_heartbeat=$((start_epoch + heartbeat_interval))
	local interval="$initial_interval" previous="" initial_head=""
	initial_head=$(read_head_sha "$pr_number" "$repo" 2>/dev/null || true)
	if [[ -z "$initial_head" ]]; then
		printf 'INDETERMINATE: PR head could not be verified before required-check observation\n' >&2
		return 2
	fi
	local poll_number=0 valid_state_seen=0
	_GCW_ACTIVE_DEFERRAL=""
	_GCW_API_ERROR_VISIBLE=0
	_GCW_NEXT_INTERVAL="$interval"
	while true; do
		poll_number=$((poll_number + 1))
		write_runtime_heartbeat
		local raw="" fetch_rc=0 fetch_diagnostic="" fetch_diagnostic_file="" current="" now_epoch="" elapsed=0 changed=0 classification="" final_head=""
		fetch_diagnostic_file=$(mktemp "${TMPDIR:-/tmp}/aidevops-gh-checks-wait-fetch.XXXXXX") || return 2
		raw=$(fetch_checks "$pr_number" "$repo" "$required_only" "$poll_number" "$initial_head" 2>"$fetch_diagnostic_file") || fetch_rc=$?
		fetch_diagnostic=$(<"$fetch_diagnostic_file")
		rm -f "$fetch_diagnostic_file"
		if [[ "$fetch_rc" -eq 0 ]]; then
			current=$(canonicalize_checks "$raw" 2>/dev/null || true)
			if [[ -z "$current" ]]; then
				fetch_diagnostic="error_kind=github-api-malformed attempted=true operation=waiter-check-evidence"
			fi
		fi
		now_epoch=$(current_epoch)
		elapsed=$((now_epoch - start_epoch))
		if [[ -z "$current" ]]; then
			handle_unavailable_fetch "$fetch_diagnostic" "$elapsed" "$timeout" "$now_epoch" "$interval" "$max_interval" || return $?
			interval="$_GCW_NEXT_INTERVAL"
			continue
		fi
		if [[ -n "$_GCW_ACTIVE_DEFERRAL" ]]; then
			printf 'GitHub check observation recovered: %s\n' "$(state_counts "$current")"
			_GCW_ACTIVE_DEFERRAL=""
		fi
		if [[ "$_GCW_API_ERROR_VISIBLE" -eq 1 ]]; then
			printf 'API state recovered: %s\n' "$(state_counts "$current")"
			_GCW_API_ERROR_VISIBLE=0
		fi
		valid_state_seen=1
		if [[ -z "$previous" ]]; then
			emit_initial_state "$current"
			changed=1
		elif [[ "$current" != "$previous" ]]; then
			emit_transitions "$previous" "$current"
			changed=1
		elif [[ "$heartbeat_interval" -gt 0 && "$now_epoch" -ge "$next_heartbeat" ]]; then
			printf 'heartbeat: required checks unchanged for %ss (%s)\n' "$elapsed" "$(state_counts "$current")"
			next_heartbeat=$((now_epoch + heartbeat_interval))
		fi
		if [[ "$changed" -eq 1 ]]; then
			next_heartbeat=$((now_epoch + heartbeat_interval))
		fi

		classification=$(classify_state "$current" "$required_only")
		case "$classification" in
		failure)
			emit_failure_details "$current"
			return 1
			;;
		success | no-required | no-checks)
			final_head=$(read_head_sha "$pr_number" "$repo" 2>/dev/null || true)
			if [[ -z "$final_head" ]]; then
				printf 'INDETERMINATE: PR head could not be verified after required checks completed\n' >&2
				return 2
			fi
			if [[ -n "$initial_head" && -n "$final_head" && "$initial_head" != "$final_head" ]]; then
				printf '+ PR head changed while waiting; restarting required-check observation\n'
				initial_head="$final_head"
				previous=""
				interval="$initial_interval"
				poll_sleep "$interval"
				continue
			fi
			emit_success_details "$classification" "$required_only" "$elapsed" "$current"
			return 0
			;;
		pending | indeterminate) ;;
		esac
		if [[ "$elapsed" -ge "$timeout" ]]; then
			if [[ "$valid_state_seen" -eq 1 ]]; then
				printf 'TIMEOUT: required checks remain non-terminal after %ss (%s)\n' "$elapsed" "$(state_counts "$current")" >&2
				return 8
			fi
			return 2
		fi
		previous="$current"
		if [[ "$changed" -eq 1 ]]; then
			interval="$initial_interval"
		else
			interval=$(next_interval "$interval" "$max_interval")
		fi
		poll_sleep "$interval"
	done
}

cmd_wait() {
	local pr_number="${1:-}"
	[[ "$pr_number" =~ ^[0-9]+$ ]] || {
		log_error "wait requires a numeric PR number"
		return 1
	}
	shift
	local repo=""
	local required_only=1
	local timeout="$_GCW_DEFAULT_TIMEOUT"
	local initial_interval="$_GCW_DEFAULT_INITIAL_INTERVAL"
	local max_interval="$_GCW_DEFAULT_MAX_INTERVAL"
	local heartbeat_interval="$_GCW_DEFAULT_HEARTBEAT_INTERVAL"
	while [[ $# -gt 0 ]]; do
		local opt="$1"
		case "$opt" in
		--repo) local repo_value="$2"; repo="$repo_value"; shift 2 ;;
		--all) required_only=0; shift ;;
		--timeout) local timeout_value="$2"; timeout="$timeout_value"; shift 2 ;;
		--initial-interval) local initial_value="$2"; initial_interval="$initial_value"; shift 2 ;;
		--max-interval) local max_value="$2"; max_interval="$max_value"; shift 2 ;;
		--heartbeat) local heartbeat_value="$2"; heartbeat_interval="$heartbeat_value"; shift 2 ;;
		*) log_error "Unknown wait option: $opt"; return 1 ;;
		esac
	done
	if ! validate_nonnegative_integer "$timeout" || ! validate_nonnegative_integer "$heartbeat_interval" || \
		! validate_positive_integer "$initial_interval" || ! validate_positive_integer "$max_interval"; then
		log_error "timeout/heartbeat must be non-negative and poll intervals must be positive integers"
		return 1
	fi
	if [[ "$initial_interval" -gt "$max_interval" ]]; then
		log_error "initial interval cannot exceed maximum interval"
		return 1
	fi
	repo=$(resolve_repo "$repo") || {
		log_error "Cannot resolve repository; pass --repo OWNER/REPO"
		return 2
	}
	wait_for_checks "$pr_number" "$repo" "$required_only" "$timeout" "$initial_interval" "$max_interval" "$heartbeat_interval"
	return $?
}

main() {
	local command="${1:-help}"
	shift || true
	case "$command" in
	wait) cmd_wait "$@" ;;
	help | --help | -h) usage ;;
	*) log_error "Unknown command: $command"; usage; return 1 ;;
	esac
	return $?
}

main "$@"
