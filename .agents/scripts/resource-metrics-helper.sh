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

Options:
  --ppid PPID              Parent PID metadata (default: parent of PID when known)
  --repo SLUG              Repository slug metadata
  --issue N                GitHub issue metadata
  --result RESULT          Outcome label metadata
  --result-file FILE       Optional file containing final outcome label
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

_process_tree_snapshot() {
	local root_pid="$1"
	local ps_snapshot=""
	ps_snapshot=$(ps -axo pid=,ppid=,pcpu=,rss= 2>/dev/null || true)
	ROOT_PID="$root_pid" PS_SNAPSHOT="$ps_snapshot" python3 - <<'PY'
import os
from collections import defaultdict

root = os.environ.get("ROOT_PID", "")
rows = []
children = defaultdict(list)
for line in os.environ.get("PS_SNAPSHOT", "").splitlines():
    parts = line.split()
    if len(parts) < 4:
        continue
    try:
        pid, ppid = parts[0], parts[1]
        cpu = float(parts[2])
        rss = int(float(parts[3]))
    except ValueError:
        continue
    rows.append((pid, ppid, cpu, rss))
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
for pid, _ppid, cpu, rss in rows:
    if pid in wanted:
        cpu_total += cpu
        rss_total += rss
        count += 1

print(f"{cpu_total:.3f} {rss_total} {count}")
PY
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
	local out_file="$DEFAULT_RESOURCE_METRICS_FILE"
	local stop_file=""
	local interval="$DEFAULT_SAMPLE_INTERVAL_SECONDS"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--pid) pid="$2"; shift 2 ;;
		--role) role="$2"; shift 2 ;;
		--session-key) session_key="$2"; shift 2 ;;
		--ppid) ppid="$2"; shift 2 ;;
		--repo) repo="$2"; shift 2 ;;
		--issue) issue="$2"; shift 2 ;;
		--result) result="$2"; shift 2 ;;
		--result-file) result_file="$2"; shift 2 ;;
		--out) out_file="$2"; shift 2 ;;
		--stop-file) stop_file="$2"; shift 2 ;;
		--interval) interval="$2"; shift 2 ;;
		--help | -h) usage; return 0 ;;
		*) printf 'Unknown argument: %s\n' "$1" >&2; return 1 ;;
		esac
	done

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
	local start_ts end_ts elapsed_s sample_count peak_rss_kb rss_sum_kb cpu_seconds
	start_ts=$(date -u +%s)
	end_ts="$start_ts"
	elapsed_s=0
	sample_count=0
	peak_rss_kb=0
	rss_sum_kb=0
	cpu_seconds="0.000"

	while kill -0 "$pid" 2>/dev/null; do
		local snapshot cpu_pct rss_kb proc_count
		snapshot=$(_process_tree_snapshot "$pid" 2>/dev/null || printf '0.000 0 0')
		read -r cpu_pct rss_kb proc_count <<<"$snapshot"
		[[ "$rss_kb" =~ ^[0-9]+$ ]] || rss_kb=0
		sample_count=$((sample_count + 1))
		rss_sum_kb=$((rss_sum_kb + rss_kb))
		if [[ "$rss_kb" -gt "$peak_rss_kb" ]]; then
			peak_rss_kb="$rss_kb"
		fi
		cpu_seconds=$(awk -v total="$cpu_seconds" -v pct="$cpu_pct" -v int="$interval" 'BEGIN { printf "%.3f", total + ((pct / 100.0) * int) }')
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
	printf '{"ts":%s,"timestamp":"%s","pid":%s,"ppid":%s,"role":%s,"session_key":%s,"repo":%s,"issue":%s,"result":%s,"cpu_seconds":%s,"rss_kb":%s,"peak_rss_kb":%s,"avg_rss_kb":%s,"elapsed_s":%s,"sample_count":%s,"sample_interval_s":%s}\n' \
		"$end_ts" "$timestamp" \
		"$pid" "${ppid:-0}" "$role_json" "$session_json" "$repo_json" "$issue_json" "$result_json" \
		"$cpu_seconds" "$avg_rss_kb" "$peak_rss_kb" "$avg_rss_kb" "$elapsed_s" "$sample_count" "$interval" >>"$out_file"
	return 0
}

main() {
	local command_name="${1:-}"
	case "$command_name" in
	sample) shift; sample_resource_metrics "$@" ;;
	--help | -h | help | "") usage ;;
	*) printf 'Unknown command: %s\n' "$command_name" >&2; return 1 ;;
	esac
	return $?
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
