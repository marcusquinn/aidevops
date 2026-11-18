#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-load-repro-helper.sh - Reproduce flaky tests by running them under load
#
# Usage:
#   test-load-repro-helper.sh run --runs N --concurrency P [--rounds R] -- <command...>
#
# Runs the command N times at concurrency P per round (R rounds, default 1),
# one log per run under ${AIDEVOPS_TEMP_DIR:-~/.aidevops/.agent-workspace/tmp}/test-load-repro/<timestamp>/.
# Records the host load average before/after each round, prints pass/fail
# counts per round, then failures grouped by first error headline with one
# example log per group. Exits 0 only when every run passed.
# Failure-record pattern mirrors _validator_print_failure_log in
# full-loop-helper-commit-validators.sh.

set -u

_trl_usage() {
	cat <<'USAGE'
Usage: test-load-repro-helper.sh run --runs N --concurrency P [--rounds R] -- <command...>
  --runs N         runs per round (positive integer)
  --concurrency P  parallel runs (positive integer)
  --rounds R       number of rounds (default 1)
Example: test-load-repro-helper.sh run --runs 40 --concurrency 40 -- node tests/foo.mjs
USAGE
	return 0
}

_trl_is_posint() {
	local value="$1"
	case "$value" in
	'' | *[!0-9]*) return 1 ;;
	esac
	[[ "$value" -ge 1 ]] || return 1
	return 0
}

_trl_loadavg() {
	local load=""
	if [[ -r /proc/loadavg ]]; then
		load=$(awk '{print $1}' /proc/loadavg 2>/dev/null) || load=""
	fi
	if [[ -z "$load" ]]; then
		load=$(uptime 2>/dev/null | sed -e 's/.*load averages*: *//' -e 's/[ ,].*//') || load=""
	fi
	printf '%s' "${load:-unknown}"
	return 0
}

# Internal: run one command, log output, record exit code.
_trl_run_one() {
	local round_dir="$1"
	local idx="$2"
	shift 2
	local rc=0
	"$@" >"${round_dir}/run-${idx}.log" 2>&1 || rc=$?
	printf '%s\n' "$rc" >"${round_dir}/run-${idx}.rc"
	return 0
}

# First error headline of a failing log (failure records first, then Error: lines).
_trl_headline() {
	local log_file="$1"
	local line=""
	line=$(grep -E -m 1 '^[[:space:]]*(not ok [0-9]+|AssertionError( \[[A-Z_]+\])?:)|failing tests:' "$log_file" 2>/dev/null) || line=""
	if [[ -z "$line" ]]; then
		line=$(grep -E -m 1 '^[[:space:]]*[A-Za-z]*Error( \[[A-Z_]+\])?:' "$log_file" 2>/dev/null) || line=""
	fi
	if [[ -z "$line" ]]; then
		line=$(grep -v '^[[:space:]]*$' "$log_file" 2>/dev/null | tail -1) || line=""
	fi
	[[ -n "$line" ]] || line="(no output)"
	printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/^not ok [0-9]* *-* *//' | cut -c1-200
	return 0
}

_trl_summarize_failures() {
	local base_dir="$1"
	local pairs="${base_dir}/failures.tsv"
	local rc_file="" log_file="" rc=""
	: >"$pairs"
	for rc_file in "$base_dir"/round-*/run-*.rc; do
		[[ -f "$rc_file" ]] || continue
		rc=$(cat "$rc_file" 2>/dev/null) || rc=1
		[[ "$rc" == "0" ]] && continue
		log_file="${rc_file%.rc}.log"
		printf '%s\t%s\n' "$(_trl_headline "$log_file")" "$log_file" >>"$pairs"
	done
	[[ -s "$pairs" ]] || return 0
	printf '\nFailures grouped by first error headline:\n'
	sort -t "$(printf '\t')" -k1,1 "$pairs" | awk -F '\t' '
		{ count[$1]++; if (!($1 in ex)) { ex[$1] = $2; order[++n] = $1 } }
		END { for (i = 1; i <= n; i++) { h = order[i]; printf "  %dx %s\n      example: %s\n", count[h], h, ex[h] } }'
	return 0
}

_trl_run_rounds() {
	local runs="$1"
	local concurrency="$2"
	local rounds="$3"
	shift 3
	local stamp base_dir round round_dir load_before load_after pass fail rc_file rc total_fail=0
	local self="${BASH_SOURCE[0]}"
	stamp=$(date +%Y%m%d-%H%M%S)
	base_dir="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}/test-load-repro/${stamp}-$$"
	mkdir -p "$base_dir" || {
		printf 'Cannot create %s\n' "$base_dir" >&2
		return 1
	}
	printf 'Logs: %s\n' "$base_dir"
	round=1
	while [[ "$round" -le "$rounds" ]]; do
		round_dir="${base_dir}/round-${round}"
		mkdir -p "$round_dir" || return 1
		load_before=$(_trl_loadavg)
		seq 1 "$runs" | xargs -P "$concurrency" -I{} bash "$self" _run-one "$round_dir" {} "$@" || true
		load_after=$(_trl_loadavg)
		pass=0
		fail=0
		for rc_file in "$round_dir"/run-*.rc; do
			[[ -f "$rc_file" ]] || continue
			rc=$(cat "$rc_file" 2>/dev/null) || rc=1
			if [[ "$rc" == "0" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); fi
		done
		# Runs that never recorded an rc (killed wrapper) count as failures.
		[[ $((pass + fail)) -ge "$runs" ]] || fail=$((runs - pass))
		total_fail=$((total_fail + fail))
		printf 'Round %s/%s: %s/%s passed, %s failed (load avg before=%s after=%s)\n' \
			"$round" "$rounds" "$pass" "$runs" "$fail" "$load_before" "$load_after"
		round=$((round + 1))
	done
	_trl_summarize_failures "$base_dir"
	if [[ "$total_fail" -gt 0 ]]; then
		printf '\nResult: %s failing run(s) of %s\n' "$total_fail" "$((runs * rounds))"
		return 1
	fi
	printf '\nResult: all %s run(s) passed\n' "$((runs * rounds))"
	return 0
}

_trl_cmd_run() {
	local runs="" concurrency="" rounds=1
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--runs)
			runs="${2:-}"
			shift 2 || shift
			;;
		--concurrency)
			concurrency="${2:-}"
			shift 2 || shift
			;;
		--rounds)
			rounds="${2:-}"
			shift 2 || shift
			;;
		--)
			shift
			break
			;;
		*)
			printf 'Unknown option: %s\n' "$1" >&2
			_trl_usage >&2
			return 2
			;;
		esac
	done
	if ! _trl_is_posint "$runs" || ! _trl_is_posint "$concurrency" || ! _trl_is_posint "$rounds" || [[ $# -eq 0 ]]; then
		_trl_usage >&2
		return 2
	fi
	_trl_run_rounds "$runs" "$concurrency" "$rounds" "$@"
	return $?
}

main() {
	local cmd="${1:-help}"
	[[ $# -gt 0 ]] && shift
	case "$cmd" in
	run)
		_trl_cmd_run "$@"
		return $?
		;;
	_run-one)
		_trl_run_one "$@"
		return $?
		;;
	help | -h | --help)
		_trl_usage
		return 0
		;;
	*)
		printf 'Unknown command: %s\n' "$cmd" >&2
		_trl_usage >&2
		return 2
		;;
	esac
}

main "$@"
