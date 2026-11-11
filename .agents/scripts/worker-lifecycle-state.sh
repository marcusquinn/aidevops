#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Shared runtime resolution for worker launchers and scheduled Pulse services.
# This is data, never shell code; service generation need not capture shell env.

# A failed stat does not prove absence: find the nearest visible ancestor and
# require directory traversal before treating missing descendants as absent.
_worker_lifecycle_config_parent_accessible() {
	local parent="$1"
	[[ "$parent" == /* ]] || return 1
	while [[ ! -e "$parent" && ! -L "$parent" && "$parent" != / ]]; do
		parent="${parent%/*}"
		[[ -n "$parent" ]] || parent=/
	done
	if [[ ! -d "$parent" || ! -x "$parent" ]]; then
		return 1
	fi
	return 0
}

# Standalone entry for launchers which cannot source this library themselves.
# Exec keeps the observed native PID/start identity throughout the producer.
worker_lifecycle_exec() {
	local entry="${BASH_SOURCE[0]%/*}/../worker-lifecycle/worker-launch.py"
	[[ "$#" -gt 0 ]] || return 1
	worker_lifecycle_prepare_launch "$PWD" "$entry" "${AIDEVOPS_PRIVATE_WORKLOAD:-0}" || return $?
	exec "${WORKER_LIFECYCLE_PREFIX[@]}" "$@"
	return 1
}

worker_lifecycle_state_dir() {
	local state_dir="${AIDEVOPS_LIFECYCLE_STATE_DIR:-}"
	local config_file="${HOME}/.config/aidevops/lifecycle-state-dir"
	if [[ -z "$state_dir" ]] && ! _worker_lifecycle_config_parent_accessible "${config_file%/*}"; then
		printf '[worker-lifecycle] observation-gap reason=host-state-config-inaccessible\n' >&2
		return 0
	fi
	if [[ -z "$state_dir" && ( -e "$config_file" || -L "$config_file" ) ]]; then
		if [[ ! -f "$config_file" || -L "$config_file" || ! -O "$config_file" || ! -r "$config_file" ]]; then
			printf '[worker-lifecycle] observation-gap reason=host-state-config-unreadable\n' >&2
			return 0
		fi
		# Accept a final line without a newline. Preserve spaces and backslashes.
		IFS= read -r state_dir <"$config_file" || true
		if [[ -z "$state_dir" ]]; then
			printf '[worker-lifecycle] observation-gap reason=host-state-config-empty\n' >&2
			return 0
		fi
		# Host settings must mean the same path in every worker/service cwd.
		# Validate before expanding ~/; environment overrides retain legacy behavior.
		case "$state_dir" in
		/* | \~/*) ;;
		*)
			printf '[worker-lifecycle] observation-gap reason=host-state-config-relative\n' >&2
			return 0
			;;
		esac
	fi
	state_dir="${state_dir:-${AIDEVOPS_WORKSPACE_DIR:-${HOME}/.aidevops/.agent-workspace}/worker-lifecycle}"
	case "$state_dir" in
	\~/*) state_dir="$HOME/${state_dir#\~/}" ;;
	esac
	printf '%s\n' "$state_dir"
	return 0
}

# Targeted removal shares the collector's registry policy and preservation executor.
worker_lifecycle_cleanup_worktree() {
	local worktree="$1"
	local entry="${BASH_SOURCE[0]%/*}/../worker-lifecycle/worker-registry.py"
	local state_dir="" python="" result="" rc=0
	local archive_root="${AIDEVOPS_WORKTREE_ARCHIVE_ROOT:-${HOME}/.aidevops/recovery/archives}"
	# GH#36494: every refusal names its cause; none of these fall back to removal.
	if [[ "${AIDEVOPS_LIFECYCLE_DISABLED:-0}" == 1 ]]; then
		_worker_lifecycle_refusal_line "lifecycle-disabled" "unset AIDEVOPS_LIFECYCLE_DISABLED to use registry retirement"
		return 1
	fi
	if ! command -v jq >/dev/null 2>&1; then
		_worker_lifecycle_refusal_line "jq-unavailable" "install jq"
		return 1
	fi
	if ! python=$(type -P python3); then
		_worker_lifecycle_refusal_line "python3-unavailable" "install python3"
		return 1
	fi
	state_dir=$(worker_lifecycle_state_dir) || state_dir=""
	if [[ -z "$state_dir" || ! -d "$state_dir" ]]; then
		_worker_lifecycle_refusal_line "registry-state-unavailable" "no lifecycle registry on this host; see worker-lifecycle/LEGACY-CLEANUP.md"
		return 1
	fi
	# Never enroll, initialize, migrate, or fall back to legacy removal proofs.
	result=$("$python" -E -s -B "$entry" --state-dir "$state_dir" cleanup-worktree \
		--path "$worktree" --repos-config "${HOME}/.config/aidevops/repos.json" \
		--output-root "$archive_root") || rc=$?
	if [[ "$rc" -eq 0 ]] && _worker_lifecycle_relinquish_caller "$result" "$python" "$entry" "$state_dir" "$worktree"; then
		result=$("$python" -E -s -B "$entry" --state-dir "$state_dir" cleanup-worktree \
			--path "$worktree" --repos-config "${HOME}/.config/aidevops/repos.json" \
			--output-root "$archive_root") || rc=$?
	fi
	if [[ "$rc" -ne 0 ]]; then
		_worker_lifecycle_report_refusal "$result" "$rc" "$worktree" "$state_dir" "$archive_root"
		return 1
	fi
	printf '%s\n' "$result"
	if ! jq -e '.status == "retired"' >/dev/null <<<"$result"; then
		_worker_lifecycle_report_refusal "$result" "$rc" "$worktree" "$state_dir" "$archive_root"
		return 1
	fi
	return 0
}

# GH#37432: an OpenCode app keeps one PID for all its sessions, so a session's
# run on a finished tree otherwise lasts until the app quits. When a caller
# opts in (explicit removal) and the registry names this caller as the only
# owner (waiting-for-caller), end this session's own run and retry once. The
# registry requires the runtime PID to be this command's ancestor; any other
# refusal, or a run held by a sibling session, is left unchanged.
# Returns: 0 when this session's run was just ended (retry), 1 otherwise.
_worker_lifecycle_relinquish_caller() {
	local result="$1"
	local python="$2"
	local entry="$3"
	local state_dir="$4"
	local worktree="$5"
	local status=""
	[[ "${WORKER_LIFECYCLE_RELINQUISH_CALLER:-0}" == 1 ]] || return 1
	jq -e '.status == "waiting-for-runs" and .detail == "waiting-for-caller"' \
		>/dev/null 2>&1 <<<"$result" || return 1
	status=$(_worker_lifecycle_relinquish_status "$python" "$entry" "$state_dir" "$worktree") || return 1
	[[ "$status" == relinquished ]] || return 1
	printf '[worker-lifecycle] relinquished the run of this session; retrying retirement once\n' >&2
	return 0
}

# Ask the registry to end this session's own run on WORKTREE. The session is
# the plugin-declared AIDEVOPS_LIFECYCLE_SESSION_ID under the runtime PID
# AIDEVOPS_LIFECYCLE_RUNTIME_PID; the registry also requires that PID to be an
# ancestor of this command.
# Outputs: relinquished, already-ended or not-owner.
# Returns: 0 when the registry answered with one of those, 1 otherwise.
_worker_lifecycle_relinquish_status() {
	local python="$1"
	local entry="$2"
	local state_dir="$3"
	local worktree="$4"
	local pid="${AIDEVOPS_LIFECYCLE_RUNTIME_PID:-}"
	local session="${AIDEVOPS_LIFECYCLE_SESSION_ID:-}"
	local result="" status=""
	[[ "$pid" =~ ^[1-9][0-9]*$ && -n "$session" && -n "$worktree" ]] || return 1
	result=$("$python" -E -s -B "$entry" --state-dir "$state_dir" relinquish-session \
		--path "$worktree" --pid "$pid" --session-id "$session" 2>/dev/null) || return 1
	status=$(jq -r '.status // empty' 2>/dev/null <<<"$result") || return 1
	case "$status" in
	relinquished | already-ended | not-owner) printf '%s\n' "$status" ;;
	*) return 1 ;;
	esac
	return 0
}

# GH#37448: the full-loop `complete` handoff ends this session's own registry
# run on its finished worktree, so guarded cleanup no longer waits for the
# shared OpenCode app PID to exit. Best-effort and never removes anything:
# retirement keeps every registry check.
# Outputs: the registry status from _worker_lifecycle_relinquish_status.
# Returns: 0 when the registry answered, 1 when unavailable or refused.
worker_lifecycle_relinquish_session() {
	local worktree="$1"
	local entry="${BASH_SOURCE[0]%/*}/../worker-lifecycle/worker-registry.py"
	local state_dir=""
	local python=""
	[[ "${AIDEVOPS_LIFECYCLE_DISABLED:-0}" != 1 && -n "$worktree" ]] || return 1
	command -v jq >/dev/null 2>&1 || return 1
	python=$(type -P python3) || return 1
	state_dir=$(worker_lifecycle_state_dir 2>/dev/null) || return 1
	[[ -n "$state_dir" && -d "$state_dir" ]] || return 1
	_worker_lifecycle_relinquish_status "$python" "$entry" "$state_dir" "$worktree"
	return $?
}

# One-line refusal for local prerequisites that never reach the registry.
# Next-step guidance is printed only for explicit operator requests
# (WORKER_LIFECYCLE_EXPLAIN_REFUSAL=1), keeping per-cycle Pulse logs compact.
_worker_lifecycle_refusal_line() {
	local code="$1"
	local next_step="$2"
	printf '[worker-lifecycle] retirement-refused status=unavailable detail=%s\n' "$code" >&2
	if [[ "${WORKER_LIFECYCLE_EXPLAIN_REFUSAL:-0}" == 1 ]]; then
		printf '[worker-lifecycle] next: %s\n' "$next_step" >&2
	fi
	return 0
}

# Describe a live ownership-registry owner of WORKTREE (read-only).
# Outputs: "pid=N liveness=alive session=KEY task=ID" (no paths or raw text).
# Returns: 0 when a live owner is recorded, 1 otherwise or when unavailable.
_worker_lifecycle_owner_summary() {
	local worktree="${1:-}"
	local snapshot="" pid="" session="" batch="" task="" created="" start=""
	[[ -n "$worktree" ]] && declare -F check_worktree_owner_snapshot >/dev/null 2>&1 || return 1
	snapshot=$(check_worktree_owner_snapshot "$worktree" 2>/dev/null) || return 1
	IFS='|' read -r pid session batch task created start <<<"$snapshot"
	[[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null || return 1
	if [[ -n "$start" ]]; then
		local current_start=""
		declare -F _wt_process_start_token_for_pid >/dev/null 2>&1 || return 1
		current_start=$(_wt_process_start_token_for_pid "$pid" 2>/dev/null) || return 1
		[[ "$current_start" == "$start" ]] || return 1
	fi
	printf 'pid=%s liveness=alive session=%s task=%s\n' "$pid" "${session:-none}" "${task:-none}"
	return 0
}

# Surface only the registry's controlled diagnostic fields, never raw output.
_worker_lifecycle_report_refusal() {
	local result="$1"
	local rc="$2"
	local worktree="${3:-}"
	local state_dir="${4:-}"
	local archive_root="${5:-}"
	local summary="" status="" detail="" reason="" owner=""
	reason=$(jq -r '.reason // empty' 2>/dev/null <<<"$result") || reason=""
	detail=$(jq -r '.detail // empty' 2>/dev/null <<<"$result") || detail=""
	# GH#37740: a bare exception class (for example CalledProcessError) names no
	# condition. Keep the error primary; a live registry owner is only context.
	if [[ -z "$detail" && "$reason" =~ ^[A-Z][A-Za-z0-9]*(Error|Exception|Conflict|Expired)$ ]]; then
		owner=$(_worker_lifecycle_owner_summary "$worktree") || owner=""
		printf '[worker-lifecycle] retirement-refused status=unavailable detail=unexpected-error error=%s%s rc=%s\n' "$reason" "${owner:+ $owner}" "$rc" >&2
		if [[ "${WORKER_LIFECYCLE_EXPLAIN_REFUSAL:-0}" == 1 ]]; then
			printf '[worker-lifecycle] next: unexpected registry failure with no named condition; inspect worktree-helper.sh registry list and worker-lifecycle/CLEANUP.md "Registry-driven cleanup pass".\n' >&2
		fi
		return 0
	fi
	summary=$(jq -r '[("status=" + (.status // "unknown" | tostring)),
		(if .reason then "reason=" + (.reason | tostring) else empty end),
		(if .detail then "detail=" + (.detail | tostring) else empty end),
		(if .process_observation then "process_observation=" + (.process_observation | tojson) else empty end),
		(if .filesystem_path then "path=" + (.filesystem_path | tostring) else empty end)]
		| join(" ")' 2>/dev/null <<<"$result") || summary=""
	printf '[worker-lifecycle] retirement-refused %s rc=%s\n' "${summary:-status=unparseable}" "$rc" >&2
	[[ "${WORKER_LIFECYCLE_EXPLAIN_REFUSAL:-0}" == 1 ]] || return 0
	status=$(jq -r '.status // empty' 2>/dev/null <<<"$result") || status=""
	_worker_lifecycle_refusal_next_step "${detail:-$status}" "$worktree" "$state_dir" "$archive_root"
	return 0
}

# Print the supported next action for a registry refusal (GH#36494).
_worker_lifecycle_refusal_next_step() {
	local code="$1"
	local worktree="$2"
	local state_dir="$3"
	local archive_root="$4"
	local legacy_cli=""
	case "$code" in
	not-enrolled)
		legacy_cli=$(cd -- "${BASH_SOURCE[0]%/*}/../worker-lifecycle" 2>/dev/null && pwd -P) ||
			legacy_cli="${BASH_SOURCE[0]%/*}/../worker-lifecycle"
		legacy_cli="${legacy_cli}/worker-legacy-cleanup.py"
		printf '[worker-lifecycle] next: this tree has no lifecycle enrollment (created before enrollment or without a declared runtime). Stop any process using it, then preview archive-first operator retirement (add --apply to archive, verify and remove; branches are kept):\n' >&2
		printf '  python3 -E -s -B %q --state-dir %q --repos-config %q --output-root %q --confirm-legacy-path %q\n' \
			"$legacy_cli" "$state_dir" "${HOME}/.config/aidevops/repos.json" "$archive_root" "$worktree" >&2
		;;
	coverage-gap)
		legacy_cli=$(cd -- "${BASH_SOURCE[0]%/*}/../worker-lifecycle" 2>/dev/null && pwd -P) ||
			legacy_cli="${BASH_SOURCE[0]%/*}/../worker-lifecycle"
		legacy_cli="${legacy_cli}/worker-registry.py"
		printf '[worker-lifecycle] next: enrolled without a registered owner, so the registry cannot prove its writers ended; it stays retained. If it was never owned, stop any process using it, preview, then add --confirm to archive, verify and remove it (branch kept):\n' >&2
		printf '  python3 -E -s -B %q --state-dir %q retire-enrolled-only --repos-config %q --output-root %q --path %q\n' \
			"$legacy_cli" "$state_dir" "${HOME}/.config/aidevops/repos.json" "$archive_root" "$worktree" >&2
		;;
	generation-marker-missing)
		printf '[worker-lifecycle] next: registry history records enrollment but the generation marker is missing. Retain the tree and inspect its Git admin metadata and registry history; legacy retirement is not applicable.\n' >&2
		;;
	worktree-locked)
		printf '[worker-lifecycle] next: inspect the Git worktree lock and its reason with git worktree list --porcelain. After confirming the lock is no longer needed, use git worktree unlock PATH on the listed path (the private path if relocation occurred). If relocation already occurred, leave its registry state intact: the registry cleanup pass resumes it with the stored generation, repository, base branch and archive target. Otherwise retry retirement.\n' >&2
		;;
	waiting-for-runs)
		printf '[worker-lifecycle] next: a registered owner is still running or unconfirmed; retry after it exits (Pulse cleanup retries automatically).\n' >&2
		;;
	waiting-for-caller)
		printf '[worker-lifecycle] next: this runtime is the registered owner of the worktree because one of its sessions ran commands or edits there. worktree-helper.sh remove from the owning session relinquishes the run of that session and retries once; if this remains, another session of the same runtime still owns it. Retirement then completes after that runtime exits (Pulse cleanup retries automatically); --force cannot override ownership.\n' >&2
		;;
	outside-maintenance-scope)
		printf '[worker-lifecycle] next: explicit retirement requires a registered, non-local_only repository with a valid canonical path and slug. Register the canonical checkout with aidevops repos add <path>, then set pulse: false, maintenance: false in ~/.config/aidevops/repos.json to keep automatic maintenance disabled; retry removal.\n' >&2
		;;
	*)
		printf '[worker-lifecycle] next: see worker-lifecycle/CLEANUP.md "Registry-driven cleanup pass"; --force cannot override registry checks.\n' >&2
		;;
	esac
	return 0
}

# Produce argv, not shell text. IDs are supplied by the new admission controller,
# never inferred from old registries. Missing mandatory prerequisites deny launch.
worker_lifecycle_prepare_launch() {
	local worktree="$1"
	local entry="$2"
	local private_workload="${3:-0}"
	local generation="${AIDEVOPS_LIFECYCLE_GENERATION_ID:-}"
	local run="${AIDEVOPS_LIFECYCLE_RUN_ID:-}"
	local required=0 unregistered_only=0
	local state_dir="" python=""
	WORKER_LIFECYCLE_PREFIX=()
	if [[ -n "$generation" || -n "$run" ]]; then
		required=1
		if [[ -z "$generation" || -z "$run" || -z "$worktree" || "$private_workload" == 1 || "${AIDEVOPS_LIFECYCLE_DISABLED:-0}" == 1 ]]; then
			printf '[worker-lifecycle] admission-denied reason=incomplete-or-excluded-context\n' >&2
			return 75
		fi
	elif [[ -z "$worktree" ]]; then
		return 0
	elif [[ "$private_workload" == 1 || "${AIDEVOPS_LIFECYCLE_DISABLED:-0}" == 1 ]]; then
		unregistered_only=1
	fi
	# Preserve the declared spelling (including symlinks) for reservation checks.
	[[ "$worktree" == /* ]] || worktree="${PWD%/}/$worktree"
	state_dir=$(worker_lifecycle_state_dir)
	if [[ -z "$state_dir" || ! -f "$entry" ]] || ! python="$(type -P python3)" ||
		! "$python" -E -s -B "$entry" --help >/dev/null 2>&1; then
		printf '[worker-lifecycle] admission-denied reason=entry-or-state-unavailable\n' >&2
		return 75
	fi
	if [[ "$required" -eq 1 ]]; then
		worktree=$(cd -- "$worktree" && pwd -P) || return 75
		WORKER_LIFECYCLE_PREFIX=("$python" -E -s -B "$entry" --state-dir "$state_dir"
			--worktree "$worktree" --generation-id "$generation" --run-id "$run" --)
	elif [[ "$unregistered_only" -eq 1 ]]; then
		WORKER_LIFECYCLE_PREFIX=("$python" -E -s -B "$entry" --state-dir "$state_dir"
			--worktree "$worktree" --unregistered-only --)
	else
		WORKER_LIFECYCLE_PREFIX=("$python" -E -s -B "$entry" --initialize --state-dir "$state_dir"
			--worktree "$worktree" --)
	fi
	return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	worker_lifecycle_exec "$@"
fi
