#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# resource-metrics-helper.sh — low-overhead ps-based resource sampler.
#
# Samples a process tree at a bounded cadence and appends one JSONL summary when
# the stop file appears or the root process exits. The default 30s interval keeps
# overhead below the <1% CPU target under normal pulse load: one `ps` snapshot and
# one small Python aggregation per interval, no tight per-process loop.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh" 2>/dev/null || true

readonly DEFAULT_RESOURCE_METRICS_FILE="${HOME}/.aidevops/logs/resource-metrics.jsonl"
readonly DEFAULT_SAMPLE_INTERVAL_SECONDS="${AIDEVOPS_RESOURCE_SAMPLE_INTERVAL_SECONDS:-30}"

usage() {
	cat <<'EOF'
Usage:
  resource-metrics-helper.sh sample --pid PID --role ROLE --session-key KEY --out FILE --stop-file FILE [options]
  resource-metrics-helper.sh snapshot --pid PID [--process-snapshot-file FILE]

Options:
  --ppid PPID              Parent PID metadata (default: parent of PID when known)
  --repo SLUG              Repository slug metadata
  --issue N                GitHub issue metadata
  --result RESULT          Outcome label metadata
  --result-file FILE       Optional file containing final outcome label
  --process-snapshot-file FILE  Optional latest PID/PGID tree snapshot
  --interval SECONDS       Sampling interval (default: 30; min: 1)
  --help                   Show this help
EOF
	return 0
}

_json_escape() {
	local value="$1"
	python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$value"
	return 0
}

_resource_metrics_require_option_value() {
	local option_name="$1"
	local argument_count="$2"
	if [[ "$argument_count" -lt 2 ]]; then
		printf 'Option %s requires an argument\n' "$option_name" >&2
		return 1
	fi
	return 0
}

_process_tree_snapshot() {
	local root_pid="$1"
	local process_snapshot_file="${2:-}"
	local process_snapshot_ttl="${3:-5}"
	[[ "$process_snapshot_ttl" =~ ^[0-9]+$ ]] || process_snapshot_ttl=5
	local ps_snapshot=""
	ps_snapshot=$(ps -axo pid=,ppid=,pgid=,pcpu=,rss= 2>/dev/null || true)
	ROOT_PID="$root_pid" PS_SNAPSHOT="$ps_snapshot" PROCESS_SNAPSHOT_FILE="$process_snapshot_file" PROCESS_SNAPSHOT_TTL="$process_snapshot_ttl" python3 - <<'PY'
import os
import time
from collections import defaultdict

root = os.environ.get("ROOT_PID", "")
snapshot_file = os.environ.get("PROCESS_SNAPSHOT_FILE", "")
snapshot_ttl = int(os.environ.get("PROCESS_SNAPSHOT_TTL", "5"))
rows = []
children = defaultdict(list)
for line in os.environ.get("PS_SNAPSHOT", "").splitlines():
    parts = line.split()
    if len(parts) < 5:
        continue
    try:
        pid, ppid, pgid = parts[0], parts[1], parts[2]
        cpu = float(parts[3])
        rss = int(float(parts[4]))
    except ValueError:
        continue
    rows.append((pid, ppid, pgid, cpu, rss))
    children[ppid].append(pid)

wanted = set()
stack = [root]
while stack:
    pid = stack.pop()
    if pid in wanted:
        continue
    wanted.add(pid)
    stack.extend(children.get(pid, []))

cpu_total = 0.0
rss_total = 0
count = 0
for pid, _ppid, _pgid, cpu, rss in rows:
    if pid in wanted:
        cpu_total += cpu
        rss_total += rss
        count += 1

if snapshot_file:
    now = int(time.time())
    recent = {}
    try:
        with open(snapshot_file, encoding="utf-8") as existing:
            for line in existing:
                parts = line.split()
                if len(parts) != 3:
                    continue
                pid, pgid, last_seen = parts
                try:
                    last_seen = int(last_seen)
                except ValueError:
                    continue
                if now - last_seen <= snapshot_ttl:
                    recent[pid] = (pgid, last_seen)
    except OSError:
        pass
    for pid, _ppid, pgid, _cpu, _rss in rows:
        if pid in wanted:
            recent[pid] = (pgid, now)
    temp_file = f"{snapshot_file}.tmp.{os.getpid()}"
    with open(temp_file, "w", encoding="utf-8") as handle:
        for pid, (pgid, last_seen) in sorted(recent.items(), key=lambda item: int(item[0])):
            handle.write(f"{pid}\t{pgid}\t{last_seen}\n")
    os.replace(temp_file, snapshot_file)

print(f"{cpu_total:.3f} {rss_total} {count}")
PY
	return 0
}

_sample_resource_metrics_loop() {
	local pid="$1"
	local stop_file="$2"
	local interval="$3"
	local process_snapshot_file="${4:-}"
	local start_ts end_ts elapsed_s sample_count peak_rss_kb peak_process_count rss_sum_kb cpu_seconds
	start_ts=$(date -u +%s)
	end_ts="$start_ts"
	elapsed_s=0
	sample_count=0
	peak_rss_kb=0
	peak_process_count=0
	rss_sum_kb=0
	cpu_seconds="0.000"

	while kill -0 "$pid" 2>/dev/null; do
		local snapshot cpu_pct rss_kb proc_count
		snapshot=$(_process_tree_snapshot "$pid" "$process_snapshot_file" "$((interval * 2 + 2))" 2>/dev/null || printf '0.000 0 0')
		read -r cpu_pct rss_kb proc_count <<<"$snapshot"
		[[ "$rss_kb" =~ ^[0-9]+$ ]] || rss_kb=0
		[[ "$proc_count" =~ ^[0-9]+$ ]] || proc_count=0
		sample_count=$((sample_count + 1))
		rss_sum_kb=$((rss_sum_kb + rss_kb))
		if [[ "$rss_kb" -gt "$peak_rss_kb" ]]; then
			peak_rss_kb="$rss_kb"
		fi
		if [[ "$proc_count" -gt "$peak_process_count" ]]; then
			peak_process_count="$proc_count"
		fi
		cpu_seconds=$(awk -v total="$cpu_seconds" -v pct="$cpu_pct" -v interval_s="$interval" 'BEGIN { printf "%.3f", total + ((pct / 100.0) * interval_s) }')
		if [[ -f "$stop_file" ]]; then
			break
		fi
		sleep "$interval" &
		local sleep_pid="$!"
		while kill -0 "$sleep_pid" 2>/dev/null; do
			if [[ -f "$stop_file" ]]; then
				kill "$sleep_pid" 2>/dev/null || true
				wait "$sleep_pid" 2>/dev/null || true
				break
			fi
			sleep 1
		done
	done

	end_ts=$(date -u +%s)
	elapsed_s=$((end_ts - start_ts))
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$start_ts" "$end_ts" "$elapsed_s" "$sample_count" "$peak_rss_kb" "$peak_process_count" "$rss_sum_kb" "$cpu_seconds"
	return 0
}

_parse_sample_resource_metrics_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--pid)
			_resource_metrics_require_option_value "$1" "$#" || return 1
			pid="$2"
			shift 2
			;;
		--role)
			_resource_metrics_require_option_value "$1" "$#" || return 1
			role="$2"
			shift 2
			;;
		--session-key)
			_resource_metrics_require_option_value "$1" "$#" || return 1
			session_key="$2"
			shift 2
			;;
		--ppid)
			_resource_metrics_require_option_value "$1" "$#" || return 1
			ppid="$2"
			shift 2
			;;
		--repo)
			_resource_metrics_require_option_value "$1" "$#" || return 1
			repo="$2"
			shift 2
			;;
		--issue)
			_resource_metrics_require_option_value "$1" "$#" || return 1
			issue="$2"
			shift 2
			;;
		--result)
			_resource_metrics_require_option_value "$1" "$#" || return 1
			result="$2"
			shift 2
			;;
		--result-file)
			_resource_metrics_require_option_value "$1" "$#" || return 1
			result_file="$2"
			shift 2
			;;
		--process-snapshot-file)
			_resource_metrics_require_option_value "$1" "$#" || return 1
			process_snapshot_file="$2"
			shift 2
			;;
		--out)
			_resource_metrics_require_option_value "$1" "$#" || return 1
			out_file="$2"
			shift 2
			;;
		--stop-file)
			_resource_metrics_require_option_value "$1" "$#" || return 1
			stop_file="$2"
			shift 2
			;;
		--interval)
			_resource_metrics_require_option_value "$1" "$#" || return 1
			interval="$2"
			shift 2
			;;
		--help | -h)
			usage
			sample_help_requested=true
			return 0
			;;
		*)
			printf 'Unknown argument: %s\n' "$1" >&2
			return 1
			;;
		esac
	done
	return 0
}

sample_resource_metrics() {
	local pid=""
	local role=""
	local session_key=""
	local ppid=""
	local repo=""
	local issue=""
	local result=""
	local result_file=""
	local process_snapshot_file=""
	local out_file="$DEFAULT_RESOURCE_METRICS_FILE"
	local stop_file=""
	local interval="$DEFAULT_SAMPLE_INTERVAL_SECONDS"
	local sample_help_requested=false

	_parse_sample_resource_metrics_args "$@" || return 1
	[[ "$sample_help_requested" == "true" ]] && return 0

	if [[ -z "$pid" || -z "$role" || -z "$session_key" || -z "$stop_file" ]]; then
		printf 'Missing required --pid, --role, --session-key, or --stop-file\n' >&2
		return 1
	fi
	if [[ ! "$interval" =~ ^[0-9]+$ || "$interval" -lt 1 ]]; then
		interval=1
	fi
	if [[ -z "$ppid" ]]; then
		ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)
	fi

	mkdir -p "$(dirname "$out_file")" 2>/dev/null || true
	local start_ts end_ts elapsed_s sample_count peak_rss_kb peak_process_count rss_sum_kb cpu_seconds
	start_ts=$(date -u +%s)
	end_ts="$start_ts"
	elapsed_s=0
	sample_count=0
	peak_rss_kb=0
	peak_process_count=0
	rss_sum_kb=0
	cpu_seconds="0.000"

	local metrics
	metrics=$(_sample_resource_metrics_loop "$pid" "$stop_file" "$interval" "$process_snapshot_file")
	if [[ -n "$metrics" ]]; then
		IFS=$'\t' read -r start_ts end_ts elapsed_s sample_count peak_rss_kb peak_process_count rss_sum_kb cpu_seconds <<<"$metrics"
	fi
	local avg_rss_kb=0
	if [[ "$sample_count" -gt 0 ]]; then
		avg_rss_kb=$((rss_sum_kb / sample_count))
	fi

	local role_json session_json repo_json issue_json result_json
	local timestamp
	if [[ -z "$result" && -n "$result_file" && -f "$result_file" ]]; then
		result=$(tr -d '\n\r' <"$result_file" 2>/dev/null || true)
	fi
	role_json=$(_json_escape "$role")
	session_json=$(_json_escape "$session_key")
	repo_json=$(_json_escape "$repo")
	issue_json=$(_json_escape "$issue")
	result_json=$(_json_escape "$result")
	timestamp=$(python3 -c 'import datetime,sys; print(datetime.datetime.fromtimestamp(int(sys.argv[1]), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$end_ts")
	printf '{"ts":%s,"timestamp":"%s","pid":%s,"ppid":%s,"role":%s,"session_key":%s,"repo":%s,"issue":%s,"result":%s,"cpu_seconds":%s,"rss_kb":%s,"peak_rss_kb":%s,"peak_process_count":%s,"avg_rss_kb":%s,"elapsed_s":%s,"sample_count":%s,"sample_interval_s":%s}\n' \
		"$end_ts" "$timestamp" \
		"$pid" "${ppid:-0}" "$role_json" "$session_json" "$repo_json" "$issue_json" "$result_json" \
		"$cpu_seconds" "$avg_rss_kb" "$peak_rss_kb" "$peak_process_count" "$avg_rss_kb" "$elapsed_s" "$sample_count" "$interval" >>"$out_file"
	return 0
}

snapshot_resource_metrics() {
	local pid=""
	local process_snapshot_file=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--pid)
			_resource_metrics_require_option_value "$1" "$#" || return 1
			pid="$2"
			shift 2
			;;
		--process-snapshot-file)
			_resource_metrics_require_option_value "$1" "$#" || return 1
			process_snapshot_file="$2"
			shift 2
			;;
		--help | -h)
			usage
			return 0
			;;
		*)
			printf 'Unknown argument: %s\n' "$1" >&2
			return 1
			;;
		esac
	done
	if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
		printf 'Missing or invalid --pid\n' >&2
		return 1
	fi
	_process_tree_snapshot "$pid" "$process_snapshot_file"
	return 0
}

main() {
	local command_name="${1:-}"
	case "$command_name" in
	sample)
		shift
		sample_resource_metrics "$@"
		;;
	snapshot)
		shift
		snapshot_resource_metrics "$@"
		;;
	--help | -h | help | "") usage ;;
	*)
		printf 'Unknown command: %s\n' "$command_name" >&2
		return 1
		;;
	esac
	return $?
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
