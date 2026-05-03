#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# cpu-saturation-helper.sh — Rolling per-core CPU saturation tracker (t3549, GH#22615)
#
# Replaces the load-average-based pre-flight overload check (t3210) with a
# direct measurement of sustained CPU saturation across all cores. Intended
# to be consulted by the canary-failure classifier in headless-runtime-lib.sh
# only AFTER a canary timeout — not as a pre-flight gate.
#
# Design contract:
#   • Every dispatch tick samples current CPU utilisation once (~50ms cost on
#     macOS via `top -l 1`, slightly cheaper on Linux via /proc/stat deltas).
#   • Samples accrete to a TSV state file. The `check` subcommand reads the
#     last N seconds of samples and returns 0 (saturated) only if EVERY
#     sample in the window is at or above the threshold.
#   • `report` prints the rolling window for diagnostics.
#   • `sample` is the explicit accretion entrypoint, callable from the pulse
#     tick or the canary preflight wrapper.
#
# Crash-resilient: state is a flat TSV; corrupted lines are dropped silently.
# Bash 3.2 compatible (macOS default).
#
# Usage:
#   cpu-saturation-helper.sh sample
#       Append one current-utilisation sample to the rolling state file.
#       Exit 0 on success, non-zero only on filesystem failures.
#
#   cpu-saturation-helper.sh check [--window SECONDS] [--threshold PERCENT]
#       Exit 0 if EVERY sample in the last SECONDS window is >= PERCENT.
#       Exit 1 if any sample is below threshold OR if there are insufficient
#       samples to cover the window (fail-open: "not yet saturated").
#       Defaults: SECONDS=120, PERCENT=98.
#
#   cpu-saturation-helper.sh report [--window SECONDS]
#       Print sample timestamps and utilisation for the last window.
#       Always exits 0.
#
#   cpu-saturation-helper.sh help
#
# Environment:
#   AIDEVOPS_CPU_SATURATION_STATE_DIR — override state directory (default
#       ~/.aidevops/.agent-workspace/cpu-saturation).
#   AIDEVOPS_CPU_SATURATION_FAKE_PCT — for tests: bypass real sampling and
#       use this value as the current utilisation percent. Whitespace-
#       separated multiple values cycle through samples (one per call).
#   AIDEVOPS_CPU_SATURATION_FAKE_NOW — for tests: override `date +%s`.

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants and defaults

CPU_SATURATION_STATE_DIR="${AIDEVOPS_CPU_SATURATION_STATE_DIR:-${HOME}/.aidevops/.agent-workspace/cpu-saturation}"
CPU_SATURATION_STATE_FILE="${CPU_SATURATION_STATE_DIR}/samples.tsv"
CPU_SATURATION_DEFAULT_WINDOW=120
CPU_SATURATION_DEFAULT_THRESHOLD=98
# Maximum samples to keep on disk regardless of window. ~24h at 8s tick.
CPU_SATURATION_MAX_RETAIN=10800

# ---------------------------------------------------------------------------
# Time helpers

_csh_now_epoch() {
	if [[ -n "${AIDEVOPS_CPU_SATURATION_FAKE_NOW:-}" ]]; then
		printf '%s\n' "${AIDEVOPS_CPU_SATURATION_FAKE_NOW}"
		return 0
	fi
	date +%s
	return 0
}

# ---------------------------------------------------------------------------
# Per-platform sampling
#
# Returns a single integer 0-100 representing instantaneous CPU utilisation
# across all cores. macOS uses `top -l 1` (system-wide aggregate). Linux
# reads two /proc/stat snapshots ~100ms apart for a delta-based percent.
# Failure modes return 0 (treat as idle, fail-open).

_csh_sample_macos() {
	# Output line shape: "CPU usage: 12.50% user, 8.33% sys, 79.17% idle"
	local line idle_pct used_int
	line=$(top -l 1 -n 0 2>/dev/null | grep -E '^CPU usage' | head -1 || true)
	[[ -n "$line" ]] || {
		printf '0\n'
		return 0
	}
	idle_pct=$(printf '%s\n' "$line" | sed -nE 's/.*([0-9]+\.[0-9]+)%[[:space:]]*idle.*/\1/p')
	[[ -n "$idle_pct" ]] || {
		printf '0\n'
		return 0
	}
	# used = 100 - idle, rounded to int
	used_int=$(awk -v i="$idle_pct" 'BEGIN { v = 100 - i; if (v < 0) v = 0; if (v > 100) v = 100; printf "%d\n", v + 0.5 }')
	printf '%s\n' "$used_int"
	return 0
}

_csh_read_proc_stat() {
	# Print "user nice system idle iowait irq softirq steal" totals from the
	# aggregate `cpu` line in /proc/stat.
	awk '/^cpu / { for (i=2; i<=NF; i++) printf "%s ", $i; print "" }' /proc/stat 2>/dev/null
}

_csh_sample_linux() {
	local s1 s2 t1 t2 i1 i2 dt di used
	s1=$(_csh_read_proc_stat)
	[[ -n "$s1" ]] || {
		printf '0\n'
		return 0
	}
	# Brief delta window. Avoids a long blocking sleep on the dispatch path
	# while still giving a representative aggregate across cores.
	sleep 0.1 2>/dev/null || sleep 1
	s2=$(_csh_read_proc_stat)
	[[ -n "$s2" ]] || {
		printf '0\n'
		return 0
	}
	# Sum: total = sum of all fields; idle = field 4 (idle) + 5 (iowait).
	t1=$(printf '%s\n' "$s1" | awk '{ s = 0; for (i=1; i<=NF; i++) s += $i; print s }')
	t2=$(printf '%s\n' "$s2" | awk '{ s = 0; for (i=1; i<=NF; i++) s += $i; print s }')
	i1=$(printf '%s\n' "$s1" | awk '{ print $4 + $5 }')
	i2=$(printf '%s\n' "$s2" | awk '{ print $4 + $5 }')
	dt=$((t2 - t1))
	di=$((i2 - i1))
	if [[ "$dt" -le 0 ]]; then
		printf '0\n'
		return 0
	fi
	used=$(awk -v dt="$dt" -v di="$di" 'BEGIN { v = (1 - di / dt) * 100; if (v < 0) v = 0; if (v > 100) v = 100; printf "%d\n", v + 0.5 }')
	printf '%s\n' "$used"
	return 0
}

# Return current utilisation. Honours AIDEVOPS_CPU_SATURATION_FAKE_PCT for tests.
_csh_current_utilisation() {
	if [[ -n "${AIDEVOPS_CPU_SATURATION_FAKE_PCT:-}" ]]; then
		# Pull next value from the fake-pct queue (whitespace-separated).
		# Each call consumes one value; remaining values are written back
		# via the queue file so successive calls cycle through.
		local queue_file queue_state next remaining
		queue_file="${CPU_SATURATION_STATE_DIR}/.fake-pct-queue"
		mkdir -p "${CPU_SATURATION_STATE_DIR}" 2>/dev/null || true
		if [[ ! -f "$queue_file" ]]; then
			printf '%s\n' "${AIDEVOPS_CPU_SATURATION_FAKE_PCT}" >"$queue_file"
		fi
		queue_state=$(cat "$queue_file" 2>/dev/null || printf '%s' "${AIDEVOPS_CPU_SATURATION_FAKE_PCT}")
		# shellcheck disable=SC2206  # intentional word splitting
		local arr=($queue_state)
		next="${arr[0]:-0}"
		if [[ "${#arr[@]}" -gt 1 ]]; then
			remaining="${arr[*]:1}"
		else
			# When the queue is exhausted, recycle the original sequence.
			remaining="${AIDEVOPS_CPU_SATURATION_FAKE_PCT}"
		fi
		printf '%s\n' "$remaining" >"$queue_file"
		printf '%s\n' "$next"
		return 0
	fi
	case "$(uname -s)" in
		Darwin) _csh_sample_macos ;;
		Linux) _csh_sample_linux ;;
		*) printf '0\n' ;;
	esac
	return 0
}

# ---------------------------------------------------------------------------
# State file management

_csh_ensure_state_dir() {
	mkdir -p "${CPU_SATURATION_STATE_DIR}" 2>/dev/null || return 1
	return 0
}

# Append one sample. Trims the file to MAX_RETAIN lines if it grows past it.
_csh_append_sample() {
	local now pct
	now=$(_csh_now_epoch)
	pct=$(_csh_current_utilisation)
	[[ "$pct" =~ ^[0-9]+$ ]] || pct=0
	_csh_ensure_state_dir || return 1
	printf '%s\t%s\n' "$now" "$pct" >>"${CPU_SATURATION_STATE_FILE}" || return 1

	# Cheap trim: only when file gets noticeably oversized, rewrite tail.
	# mkdir-based mutex prevents concurrent samplers from racing on the
	# tail+mv pair (which can drop samples written between tail and mv).
	# If we can't get the lock, skip trim — another caller will trim later.
	local line_count
	line_count=$(wc -l <"${CPU_SATURATION_STATE_FILE}" 2>/dev/null | tr -d ' ')
	[[ "$line_count" =~ ^[0-9]+$ ]] || line_count=0
	if [[ "$line_count" -gt "$((CPU_SATURATION_MAX_RETAIN * 2))" ]]; then
		local lockdir="${CPU_SATURATION_STATE_FILE}.trim.lock"
		if mkdir "$lockdir" 2>/dev/null; then
			local tmpfile
			tmpfile=$(mktemp "${CPU_SATURATION_STATE_DIR}/.samples.XXXXXX") || {
				rmdir "$lockdir" 2>/dev/null || true
				return 0
			}
			tail -n "$CPU_SATURATION_MAX_RETAIN" "${CPU_SATURATION_STATE_FILE}" >"$tmpfile" 2>/dev/null || true
			mv "$tmpfile" "${CPU_SATURATION_STATE_FILE}" 2>/dev/null || rm -f "$tmpfile" 2>/dev/null
			rmdir "$lockdir" 2>/dev/null || true
		fi
	fi
	return 0
}

# Read samples within window; print as TAB-separated `epoch\tpct` lines.
_csh_samples_within_window() {
	local window="$1"
	local now cutoff
	now=$(_csh_now_epoch)
	cutoff=$((now - window))
	[[ -f "${CPU_SATURATION_STATE_FILE}" ]] || return 0
	awk -v cutoff="$cutoff" -F'\t' '
		NF == 2 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $1 >= cutoff { print }
	' "${CPU_SATURATION_STATE_FILE}" 2>/dev/null
	return 0
}

# ---------------------------------------------------------------------------
# Argument parsing

_csh_parse_window_threshold() {
	# Sets globals OPT_WINDOW and OPT_THRESHOLD from "$@".
	OPT_WINDOW="$CPU_SATURATION_DEFAULT_WINDOW"
	OPT_THRESHOLD="$CPU_SATURATION_DEFAULT_THRESHOLD"
	while [[ "$#" -gt 0 ]]; do
		case "$1" in
			--window)
				OPT_WINDOW="${2:-}"
				shift 2 || break
				;;
			--threshold)
				OPT_THRESHOLD="${2:-}"
				shift 2 || break
				;;
			*)
				shift
				;;
		esac
	done
	[[ "$OPT_WINDOW" =~ ^[0-9]+$ ]] || OPT_WINDOW="$CPU_SATURATION_DEFAULT_WINDOW"
	[[ "$OPT_THRESHOLD" =~ ^[0-9]+$ ]] || OPT_THRESHOLD="$CPU_SATURATION_DEFAULT_THRESHOLD"
	return 0
}

# ---------------------------------------------------------------------------
# Subcommand: check
#
# Saturated == every sample in window >= threshold AND samples cover at least
# half the window (so a fresh state file does not falsely report saturated).

cmd_check() {
	local OPT_WINDOW OPT_THRESHOLD
	_csh_parse_window_threshold "$@"

	local samples first_ts last_ts span min_pct sample_count
	samples=$(_csh_samples_within_window "$OPT_WINDOW")
	if [[ -z "$samples" ]]; then
		# No samples in window: not saturated.
		return 1
	fi

	sample_count=$(printf '%s\n' "$samples" | wc -l | tr -d ' ')
	first_ts=$(printf '%s\n' "$samples" | head -1 | awk -F'\t' '{print $1}')
	last_ts=$(printf '%s\n' "$samples" | tail -1 | awk -F'\t' '{print $1}')
	min_pct=$(printf '%s\n' "$samples" | awk -F'\t' 'BEGIN{m=101} {if ($2+0 < m) m = $2+0} END{print m+0}')

	# Need samples spanning at least half the requested window before
	# declaring sustained saturation. Otherwise a freshly-started runner
	# with only 1-2 samples could trip overload the moment those samples
	# happen to be high.
	span=$((last_ts - first_ts))
	local min_span
	min_span=$((OPT_WINDOW / 2))
	if [[ "$span" -lt "$min_span" ]]; then
		return 1
	fi
	# Need a minimum sample density (avoid declaring saturation off 1-2 spikes).
	if [[ "$sample_count" -lt 3 ]]; then
		return 1
	fi

	if [[ "$min_pct" -ge "$OPT_THRESHOLD" ]]; then
		return 0
	fi
	return 1
}

# ---------------------------------------------------------------------------
# Subcommand: report

cmd_report() {
	local OPT_WINDOW OPT_THRESHOLD
	_csh_parse_window_threshold "$@"
	local samples
	samples=$(_csh_samples_within_window "$OPT_WINDOW")
	if [[ -z "$samples" ]]; then
		printf 'cpu-saturation: no samples in last %ss\n' "$OPT_WINDOW"
		return 0
	fi
	local sample_count avg_pct min_pct max_pct
	sample_count=$(printf '%s\n' "$samples" | wc -l | tr -d ' ')
	avg_pct=$(printf '%s\n' "$samples" | awk -F'\t' '{s+=$2; n++} END{if (n>0) printf "%d", s/n + 0.5; else print 0}')
	min_pct=$(printf '%s\n' "$samples" | awk -F'\t' 'BEGIN{m=101} {if ($2+0 < m) m = $2+0} END{print m+0}')
	max_pct=$(printf '%s\n' "$samples" | awk -F'\t' 'BEGIN{m=-1} {if ($2+0 > m) m = $2+0} END{print m+0}')
	printf 'cpu-saturation window=%ss samples=%s min=%s%% avg=%s%% max=%s%% threshold=%s%%\n' \
		"$OPT_WINDOW" "$sample_count" "$min_pct" "$avg_pct" "$max_pct" "$OPT_THRESHOLD"
	return 0
}

# ---------------------------------------------------------------------------
# Subcommand: sample

cmd_sample() {
	_csh_append_sample
	return $?
}

# ---------------------------------------------------------------------------
# Subcommand: help

cmd_help() {
	sed -nE '/^# Usage:/,/^# Environment:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
	return 0
}

# ---------------------------------------------------------------------------
# Dispatch

main() {
	local subcmd="${1:-help}"
	[[ "$#" -gt 0 ]] && shift || true
	case "$subcmd" in
		sample) cmd_sample "$@" ;;
		check) cmd_check "$@" ;;
		report) cmd_report "$@" ;;
		help | --help | -h) cmd_help ;;
		*)
			printf 'cpu-saturation-helper.sh: unknown subcommand %s\n' "$subcmd" >&2
			cmd_help >&2
			return 2
			;;
	esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
