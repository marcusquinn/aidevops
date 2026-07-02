#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# aidevops Reach Feedback Library
# =============================================================================
# Reach performance feedback mining and issue-body reporting.
#
# Usage: source "${SCRIPT_DIR}/reach-feedback-lib.sh"
#
# Dependencies:
#   - shared-constants.sh (when available)
#   - reach-helper.sh constants sourced before this library in normal use
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_REACH_FEEDBACK_LIB_LOADED:-}" ]] && return 0
_REACH_FEEDBACK_LIB_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

if [[ -f "${SCRIPT_DIR}/shared-constants.sh" ]]; then
	# shellcheck source=./shared-constants.sh
	# shellcheck disable=SC1091  # shared constants resolved at runtime via $SCRIPT_DIR
	source "${SCRIPT_DIR}/shared-constants.sh"
fi

# --- Functions ---

feedback_window_seconds() {
	local window_value="$1"
	parse_ttl_seconds "$window_value"
	return $?
}

feedback_emit_mine() {
	local window_value="$1"
	local format_value="$2"
	local log_path=""
	local window_seconds=""
	log_path="$(reach_performance_log_path)"
	window_seconds="$(feedback_window_seconds "$window_value")" || return 1
	python3 - "$log_path" "$window_value" "$window_seconds" "$format_value" <<'PY'
import collections
import datetime
import json
import os
import sys

log_path, window_label, window_seconds, output_format = sys.argv[1:]
now = datetime.datetime.now(datetime.timezone.utc)
cutoff = now - datetime.timedelta(seconds=int(window_seconds))

def parse_ts(value):
    try:
        return datetime.datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None

records = []
if os.path.exists(log_path):
    with open(log_path, "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            ts = parse_ts(record.get("timestamp", ""))
            if ts is None or ts >= cutoff:
                records.append(record)

groups = collections.defaultdict(list)
for record in records:
    key = (
        str(record.get("failure_class", "none")),
        str(record.get("backend", "unknown")),
        str(record.get("agency_level", 0)),
        str(record.get("target_key", "target:unknown")),
    )
    groups[key].append(record)

themes = []
for (failure_class, backend, agency_level, target_key), grouped in sorted(groups.items()):
    sessions = {str(item.get("session_ref", "session:unavailable")) for item in grouped}
    failure_records = [item for item in grouped if item.get("status") == "failure"]
    temporary_failures = [item for item in failure_records if item.get("temporary") is True]
    permanent_failures = [item for item in failure_records if item.get("temporary") is False]
    slow_records = [item for item in grouped if int(item.get("latency_ms") or 0) >= 5000]
    discovery_heavy = [item for item in grouped if int(item.get("discovery_steps") or 0) >= 5]
    token_heavy = [item for item in grouped if int(item.get("token_estimate") or 0) >= 8000]
    manual_review = [item for item in grouped if backend == "manual_review" or failure_class in {"auth_required", "scope_forbidden"}]
    reasons = []
    if len(temporary_failures) >= 3 and len(sessions) >= 2:
        reasons.append("repeated temporary failures")
    if permanent_failures:
        reasons.append("permanent blocker")
    if len(slow_records) >= 3:
        reasons.append("slow backend choice")
    if len(discovery_heavy) >= 3:
        reasons.append("high discovery count")
    if len(token_heavy) >= 3:
        reasons.append("high token estimate")
    if len(manual_review) >= 3:
        reasons.append("repeated manual-review outcome")
    if not reasons:
        continue
    next_actions = collections.Counter(str(item.get("next_best_action", "inspect sanitized evidence")) for item in grouped)
    themes.append({
        "theme_id": f"reach-{failure_class}-{backend}-{abs(hash((failure_class, backend, agency_level, target_key))) % 100000}",
        "summary": f"Reach {backend} attempts for {target_key} show {', '.join(reasons)}.",
        "failure_class": failure_class,
        "backend": backend,
        "agency_level": int(agency_level) if str(agency_level).isdigit() else 0,
        "target_key": target_key,
        "evidence_count": len(grouped),
        "failure_count": len(failure_records),
        "independent_sessions": len(sessions),
        "reasons": reasons,
        "privacy": "target details are hashed or sanitized; no raw URLs, cookies, credentials, proxy values, or private paths are included",
        "suggested_next_best_action": next_actions.most_common(1)[0][0] if next_actions else "inspect sanitized evidence",
        "eligible_for_issue": (len(temporary_failures) >= 3 and len(sessions) >= 2) or bool(permanent_failures),
    })

result = {
    "schema_version": 1,
    "source": "reach-performance-jsonl",
    "source_log": os.path.basename(log_path),
    "window": window_label,
    "records_considered": len(records),
    "themes": themes,
}
if output_format == "json":
    print(json.dumps(result, sort_keys=True))
else:
    print(f"# Reach feedback themes ({window_label})")
    print("")
    print(f"Records considered: {len(records)}")
    if not themes:
        print("No threshold-backed themes found.")
    for theme in themes:
        print(f"- {theme['theme_id']}: {theme['summary']} Evidence: {theme['evidence_count']} records across {theme['independent_sessions']} sessions.")
PY
	return $?
}

feedback_emit_issue() {
	local window_value="$1"
	local format_value="$2"
	local dry_run="$3"
	local create_with_wrapper="$4"
	local log_path=""
	local window_seconds=""
	log_path="$(reach_performance_log_path)"
	window_seconds="$(feedback_window_seconds "$window_value")" || return 1
	if [[ "$dry_run" != "true" && "$create_with_wrapper" != "true" ]]; then
		log_error "reach feedback issue creates public tasks only with --create-with-wrapper; use --dry-run to preview"
		return 1
	fi
	python3 - "$log_path" "$window_value" "$window_seconds" "$format_value" "$dry_run" <<'PY'
import collections
import datetime
import json
import os
import sys

log_path, window_label, window_seconds, output_format, dry_run = sys.argv[1:]
now = datetime.datetime.now(datetime.timezone.utc)
cutoff = now - datetime.timedelta(seconds=int(window_seconds))

def parse_ts(value):
    try:
        return datetime.datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None

records = []
if os.path.exists(log_path):
    with open(log_path, "r", encoding="utf-8") as handle:
        for line in handle:
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            ts = parse_ts(record.get("timestamp", ""))
            if ts is None or ts >= cutoff:
                records.append(record)

groups = collections.defaultdict(list)
for record in records:
    key = (str(record.get("failure_class", "none")), str(record.get("backend", "unknown")), str(record.get("agency_level", 0)), str(record.get("target_key", "target:unknown")))
    groups[key].append(record)

eligible = []
for (failure_class, backend, agency_level, target_key), grouped in sorted(groups.items()):
    sessions = {str(item.get("session_ref", "session:unavailable")) for item in grouped}
    failures = [item for item in grouped if item.get("status") == "failure"]
    temporary = [item for item in failures if item.get("temporary") is True]
    permanent = [item for item in failures if item.get("temporary") is False]
    if (len(temporary) >= 3 and len(sessions) >= 2) or permanent:
        next_action = collections.Counter(str(item.get("next_best_action", "inspect sanitized evidence")) for item in grouped).most_common(1)[0][0]
        eligible.append({
            "failure_class": failure_class,
            "backend": backend,
            "agency_level": agency_level,
            "target_key": target_key,
            "records": len(grouped),
            "sessions": len(sessions),
            "next_action": next_action,
        })

brief = {
    "schema_version": 1,
    "dry_run": dry_run == "true",
    "eligible_theme_count": len(eligible),
    "issues": eligible,
}
if output_format == "json":
    print(json.dumps(brief, sort_keys=True))
else:
    print("# tbd: Reach feedback follow-up")
    print("")
    print("## What")
    if eligible:
        theme = eligible[0]
        print(f"Investigate repeated reach `{theme['failure_class']}` outcomes on `{theme['backend']}` for sanitized target `{theme['target_key']}`.")
    else:
        print("No issue is eligible: evidence thresholds were not met.")
    print("")
    print("## Evidence")
    print(f"- Window: {window_label}")
    print(f"- Records considered: {len(records)}")
    print(f"- Eligible themes: {len(eligible)}")
    for theme in eligible:
        print(f"- `{theme['failure_class']}` via `{theme['backend']}`: {theme['records']} records across {theme['sessions']} sessions; next action: {theme['next_action']}")
    print("")
    print("## Files to Modify")
    print("- `EDIT: .agents/scripts/reach-helper.sh` — adjust reach route/capture handling for the verified theme.")
    print("- `EDIT: .agents/aidevops/feedback.md` — document any threshold or review-gate change.")
    print("")
    print("## Verification")
    print("```bash")
    print("shellcheck .agents/scripts/reach-helper.sh")
    print(".agents/scripts/tests/test-reach-feedback.sh")
    print("./aidevops.sh reach feedback mine --window 7d --format json")
    print("```")
    print("")
    print("Privacy: target details are sanitized or hashed; do not paste raw URLs, cookies, credentials, proxy values, or private paths into public issues.")
PY
	return $?
}

handle_feedback() {
	local subcommand="${1:-mine}"
	if [[ $# -gt 0 ]]; then
		shift
	fi
	local window_value="7d"
	local format_value="json"
	local dry_run="false"
	local create_with_wrapper="false"
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
			--window)
				shift
				window_value="${1:-7d}"
				;;
			--format)
				shift
				format_value="${1:-json}"
				;;
			--dry-run)
				dry_run="true"
				;;
			--create-with-wrapper)
				create_with_wrapper="true"
				;;
			*)
				log_error "Unknown feedback option: $arg"
				return 1
				;;
		esac
		shift || true
	done
	case "$format_value" in
		json | markdown) ;;
		*) log_error "feedback --format must be json or markdown"; return 1 ;;
	esac
	case "$subcommand" in
		mine)
			feedback_emit_mine "$window_value" "$format_value"
			return $?
			;;
		issue)
			if [[ "$dry_run" != "true" && "$create_with_wrapper" != "true" ]]; then
				dry_run="true"
			fi
			feedback_emit_issue "$window_value" "$format_value" "$dry_run" "$create_with_wrapper"
			return $?
			;;
		*)
			log_error "feedback requires mine or issue"
			return 1
			;;
	esac
}

