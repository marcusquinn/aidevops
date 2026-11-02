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

# Surface only the registry's controlled diagnostic fields, never raw output.
_worker_lifecycle_report_refusal() {
	local result="$1"
	local rc="$2"
	local worktree="${3:-}"
	local state_dir="${4:-}"
	local archive_root="${5:-}"
	local summary="" status="" detail=""
	summary=$(jq -r '[("status=" + (.status // "unknown" | tostring)),
		(if .reason then "reason=" + (.reason | tostring) else empty end),
		(if .detail then "detail=" + (.detail | tostring) else empty end),
		(if .filesystem_path then "path=" + (.filesystem_path | tostring) else empty end)]
		| join(" ")' 2>/dev/null <<<"$result") || summary=""
	printf '[worker-lifecycle] retirement-refused %s rc=%s\n' "${summary:-status=unparseable}" "$rc" >&2
	[[ "${WORKER_LIFECYCLE_EXPLAIN_REFUSAL:-0}" == 1 ]] || return 0
	status=$(jq -r '.status // empty' 2>/dev/null <<<"$result") || status=""
	detail=$(jq -r '.detail // empty' 2>/dev/null <<<"$result") || detail=""
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
		printf '[worker-lifecycle] next: enrolled without a registered owner, so the registry cannot prove its writers ended; it stays retained. See worker-lifecycle/CLEANUP.md "Registry-driven cleanup pass".\n' >&2
		;;
	waiting-for-runs)
		printf '[worker-lifecycle] next: a registered owner is still running or unconfirmed; retry after it exits (Pulse cleanup retries automatically).\n' >&2
		;;
	outside-maintenance-scope)
		printf '[worker-lifecycle] next: the repository is not in maintenance scope in ~/.config/aidevops/repos.json.\n' >&2
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
