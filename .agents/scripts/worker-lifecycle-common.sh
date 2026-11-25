#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# worker-lifecycle-common.sh — Shared process lifecycle functions
#
# Extracted from pulse-wrapper.sh (t1419) so that both pulse-wrapper.sh and
# worker-watchdog.sh can reuse the same battle-tested process management
# primitives without duplication.
#
# Functions provided:
#   _kill_tree()              Kill a process and all its children (SIGTERM)
#   _force_kill_tree()        Force kill a process tree (SIGKILL)
#   _get_process_age()        Get process age in seconds from ps etime
#   _get_pid_cpu()            Get integer CPU% for a single PID
#   _get_process_tree_cpu()   Get CPU% summed across a process tree (BFS)
#   _worker_output_has_fresh_provider_failure() Trusted provider failure at output tail
#   _worker_kill_reason_class() Map a watchdog kill reason to its persisted class
#   _extract_session_title_from_cmd() Extract session title from opencode CLI args
#   _count_recent_opencode_messages() Count recent OpenCode messages by title match
#   _collect_worker_stall_evidence()  Summarise recent worker transcript/output tail
#   _sanitize_log_field()     Strip control characters from log fields
#   _sanitize_markdown()      Strip @ mentions and backticks from markdown
#   _validate_int()           Validate and sanitize integer config values
#   _worker_attempt_id_for_issue() Resolve the latest public attempt identity
#   _count_issue_comments_containing_marker() Pagination-safe comment marker count
#   _count_worker_commits()   Count commits in a worktree since elapsed seconds ago
#   _count_worker_messages()  Count session DB messages for a worker
#   _determine_struggle_flag() Determine struggle flag from ratio/commit/elapsed metrics
#   _compute_struggle_ratio() Compute messages/commits ratio for a worker
#   _format_duration()        Format seconds into human-readable duration
#
# Modules sourced by this orchestrator (GH#40351 large-file split; callers keep
# sourcing only this file):
#   worker-lifecycle-common-attempt.sh          Attempt identity, objective evidence, runtime events
#   worker-lifecycle-common-process.sh          Process tree, CPU, session tail, kill-reason class
#   worker-lifecycle-common-session.sh          Session title/ID resolution, recent message counts
#   worker-lifecycle-common-metrics.sh          Stall evidence, sanitisers, counters, formatting
#   worker-lifecycle-common-escalation-gate.sh  Body quality gate, no_work breaker, reason classifiers
#   worker-lifecycle-common-escalation.sh       Thresholds, no_work reclassification, escalate_issue_tier
#
# Companion files:
#   session_tail_query.py              Session tail classification (GH#6428)
#   worker-lifecycle-verbose.sh        Verbose lifecycle checkpoint watcher
#   worker_lifecycle_extract_title.py  Extract --title from CLI args (GH#17561)
#   worker_lifecycle_stall_evidence.py Classify worker log tail (GH#17561)
#   worker_lifecycle_resolve_session.py Resolve session ID from title (GH#17561)
#   worker_lifecycle_count_messages.py Count session DB messages (GH#17561)
#   list_active_workers.awk            Deduplicate active worker processes (GH#17561)
#
# Usage: source worker-lifecycle-common.sh
#
# Include guard prevents double-loading (readonly errors, function redefinition).

# Include guard
[[ -n "${_WORKER_LIFECYCLE_COMMON_LOADED:-}" ]] && return 0
_WORKER_LIFECYCLE_COMMON_LOADED=1
_WLC_STATUS_BLOCKED="blocked"
_WLC_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_worker_attempt_observability_dir="${BASH_SOURCE[0]%/*}"
# shellcheck source=worker-attempt-observability.sh
source "${_worker_attempt_observability_dir}/worker-attempt-observability.sh"
unset _worker_attempt_observability_dir

# Add correlation fields and durable checkpoints to lifecycle output without
# changing callers that use the shared print aliases for ordinary messages.
print_error() {
	local message="$1"
	worker_attempt_observability_print error "$message"
	return $?
}

print_warning() {
	local message="$1"
	worker_attempt_observability_print warning "$message"
	return $?
}

print_info() {
	local message="$1"
	worker_attempt_observability_print info "$message"
	return $?
}

# Resolve this library's own directory instead of trusting a caller's SCRIPT_DIR.
_worker_lifecycle_common_path="${BASH_SOURCE[0]%/*}"
[[ "$_worker_lifecycle_common_path" == "${BASH_SOURCE[0]}" ]] && _worker_lifecycle_common_path="."
_worker_lifecycle_common_dir="$(cd "$_worker_lifecycle_common_path" && pwd)" || return 1
unset _worker_lifecycle_common_path

# shellcheck source=./worker-lifecycle-common-attempt.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime from this file's directory
source "${_worker_lifecycle_common_dir}/worker-lifecycle-common-attempt.sh"

# shellcheck source=./worker-lifecycle-common-process.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime from this file's directory
source "${_worker_lifecycle_common_dir}/worker-lifecycle-common-process.sh"

# shellcheck source=./worker-lifecycle-common-session.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime from this file's directory
source "${_worker_lifecycle_common_dir}/worker-lifecycle-common-session.sh"

# shellcheck source=./worker-lifecycle-common-metrics.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime from this file's directory
source "${_worker_lifecycle_common_dir}/worker-lifecycle-common-metrics.sh"

# shellcheck source=./worker-lifecycle-common-escalation-gate.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime from this file's directory
source "${_worker_lifecycle_common_dir}/worker-lifecycle-common-escalation-gate.sh"

# shellcheck source=./worker-lifecycle-common-escalation.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime from this file's directory
source "${_worker_lifecycle_common_dir}/worker-lifecycle-common-escalation.sh"

#######################################
# List active worker processes (logical, deduplicated).
#
# Moved here from pulse-wrapper.sh so that both pulse-wrapper.sh and
# stats-functions.sh (via stats-wrapper.sh) use the same counting logic.
# Previously, stats-functions.sh had a simpler _scan_active_workers that
# missed headless-runtime-helper workers, didn't deduplicate process chains,
# and didn't filter zombie/stopped processes — producing wrong worker counts
# on the pinned health issue dashboards.
#
# t5072: Count logical workers (one per session/issue), not OS process tree nodes.
# A single opencode worker spawns a 3-process chain:
#   bash sandbox-exec-helper.sh run ... -- opencode run ...  (top-level launcher)
#   node /opt/homebrew/bin/opencode run ...                  (node child)
#   /path/to/.opencode run ...                               (binary grandchild)
# All three contain /full-loop (or /review-issue-pr) and opencode in their command line.
#
# GH#12361 / GH#14944: Workers may appear either as direct opencode
# processes or as headless-runtime-helper.sh wrappers around sandbox +
# opencode children. Counting must treat the whole wrapper/process tree as
# one logical worker.
#
# GH#6413: Process state filtering — exclude zombie (Z) and stopped (T)
# processes.
#
# Output: one line per logical worker: "pid etime command..."
#######################################
list_active_worker_processes() {
	local script_dir effective_uid
	local -a pipeline_status
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	local awk_script="${script_dir}/list_active_workers.awk"
	effective_uid=$(id -u) || return 1
	[[ "$effective_uid" =~ ^[0-9]+$ ]] || return 1
	# Awk logic extracted to list_active_workers.awk (GH#17561)
	# t2190: use `axww` (unlimited line width) so Linux procps doesn't
	# truncate the command column to the detected terminal width (~80
	# cols when piped). Worker commands contain the full HEADLESS_
	# CONTINUATION_CONTRACT_V6 prompt (5000+ chars); without `ww`, the
	# awk match on `/full-loop`, `--role worker`, `--session-key issue-NNN`,
	# and `--dir <path>` all fail — has_worker_for_repo_issue returns
	# false within the 35s grace window, recover_failed_launch_state
	# unassigns the worker, and every dispatch cycle loops on the same
	# issue. macOS BSD ps already emits full commands; `ww` is harmless
	# there (and also supported).
	# Include numeric UID in the snapshot rather than relying on usernames or a
	# platform-specific ps user selector. The parser filters before deduplication,
	# so an identical foreign-user session cannot hide a runner-owned worker.
	ps axwwo uid,pid,stat,etime,command | awk -v effective_uid="$effective_uid" -f "$awk_script"
	pipeline_status=("${PIPESTATUS[@]}")
	[[ "${pipeline_status[0]}" -eq 0 && "${pipeline_status[1]}" -eq 0 ]] || return 1
	return 0
}


#######################################
# Emit one stdout line where an early-closing consumer is expected.
# Arguments:
#   value - line content to emit
# Returns: always 0 for EPIPE-safe data-return helpers
#######################################
_emit_stdout_line_safely() {
	local value="$1"
	printf '%s\n' "$value" 2>/dev/null || return 0
	return 0
}

#######################################
# Count active worker processes
# Returns: count via stdout
#######################################
count_active_workers() {
	local count worker_processes
	worker_processes=$(list_active_worker_processes) || return 1
	if [[ -z "$worker_processes" ]]; then
		count=0
	else
		count=$(printf '%s\n' "$worker_processes" | wc -l | tr -d ' ') || return 1
	fi
	_emit_stdout_line_safely "$count"
	return 0
}

#######################################
# Count interactive AI sessions (t1398)
#
# Counts opencode/claude processes with a real TTY (interactive sessions).
# Shared between pulse-wrapper.sh and stats-functions.sh.
#
# Arguments: none
# Returns: session count via stdout
#######################################
check_session_count() {
	local interactive_count=0

	# Count opencode processes with a real TTY (interactive sessions).
	# Filter both '?' (Linux) and '??' (macOS) headless TTY entries.
	# t2190: ps axwwo so the awk regex isn't defeated by Linux procps truncation.
	interactive_count=$(ps axwwo tty,command | awk '
		/(\.(opencode|claude)|opencode-ai|claude-ai)/ && !/awk/ && $1 != "?" && $1 != "??" { count++ }
		END { print count + 0 }
	') || interactive_count=0

	_emit_stdout_line_safely "$interactive_count"
	return 0
}

# shellcheck source=./worker-lifecycle-verbose.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime from this file's directory
source "${_worker_lifecycle_common_dir}/worker-lifecycle-verbose.sh"
unset _worker_lifecycle_common_dir
