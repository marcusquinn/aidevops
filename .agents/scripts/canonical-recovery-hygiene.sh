#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# canonical-recovery-hygiene.sh - guarded repair of stale Git lock files and
# interrupted-fetch pack debris in a canonical checkout's common Git directory,
# plus the sanctioned canonical `git gc --auto` path (GH#39722).
#
# Crashed or killed Git processes leave zero-byte `*.lock` files behind. While a
# reflog lock remains, every automatic gc fails with `failed to run reflog`, and
# the canonical Git guard (correctly) refuses a direct `git gc` in a canonical
# checkout. These subcommands are the audited alternative.
#
# Sourced by canonical-recovery-helper.sh, which owns `set -euo pipefail` and
# sources canonical-recovery-lock.sh (crl_acquire/crl_release, portable-stat).
#
#   repair-stale-locks --repo PATH [--min-age-minutes N] [--tmp-min-age-days N] [--apply]
#   maintenance-gc     --repo PATH [--min-age-minutes N] [--tmp-min-age-days N] [--apply]
#
# Both default to a dry-run report. A candidate must be a regular file inside
# the common Git directory, older than its threshold, with no holder reported by
# lsof/fuser, and no live Git process of this user that started before the file
# was last written and targets this repository. Apply re-checks every gate under
# the canonical recovery lock, verifies the tamper-evident audit chain first,
# and records each removal's intent and outcome (relative path, size, mtime;
# never a repository path or name).

CGH_REPAIR_CMD="repair-stale-locks"
CGH_GC_CMD="maintenance-gc"
CGH_DEFAULT_MIN_AGE_MINUTES=60
CGH_DEFAULT_TMP_MIN_AGE_DAYS=2
# Exit status when another canonical recovery holds the lock (EX_TEMPFAIL).
CGH_LOCK_BUSY_EXIT=75
CGH_KIND_LOCK="lock"
CGH_KIND_TMP_PACK="tmp-pack"
CGH_GIT_PROCS=""
# 1 only after a successful process listing; every gate fails closed otherwise.
CGH_PROC_SCAN_OK=0
CGH_PID_VERDICTS=" "
CGH_LOCK_DIR=""
CGH_EVAL_REASON=""
CGH_EVAL_IDENTITY=""
CGH_LOCK_HELD=0
# Resolved in cgh_main once SCRIPT_DIR is known.
CGH_AUDIT_TOOL=""
CGH_AUDIT_FILE=""

_cgh_usage() {
	printf '%s\n' \
		'Usage:' \
		"  canonical-recovery-helper.sh ${CGH_REPAIR_CMD} --repo PATH [--min-age-minutes N] [--tmp-min-age-days N] [--apply]" \
		"  canonical-recovery-helper.sh ${CGH_GC_CMD} --repo PATH [--min-age-minutes N] [--tmp-min-age-days N] [--apply]" \
		'' \
		'Dry run by default. --apply removes only stale, unheld Git lock files and' \
		"interrupted-fetch objects/pack temporaries, audited; ${CGH_GC_CMD} then runs" \
		'git gc --auto in the canonical repository under the recovery lock.'
	return 0
}

_cgh_block() {
	local message="$1"
	printf 'BLOCKED: %s\n' "$message" >&2
	return 1
}

# Converts ps etime ([[dd-]hh:]mm:ss) to seconds.
_cgh_etime_seconds() {
	local etime="$1"
	local days=0 rest="" first="" second="" third="" hours=0 minutes=0 seconds=0

	if [[ "$etime" == *-* ]]; then
		days="${etime%%-*}"
		rest="${etime#*-}"
	else
		rest="$etime"
	fi
	IFS=: read -r first second third <<<"$rest"
	if [[ -n "$third" ]]; then
		hours="$first"
		minutes="$second"
		seconds="$third"
	else
		minutes="$first"
		seconds="$second"
	fi
	[[ "$days" =~ ^[0-9]+$ && "$hours" =~ ^[0-9]+$ && "$minutes" =~ ^[0-9]+$ && "$seconds" =~ ^[0-9]+$ ]] || return 1
	printf '%s\n' "$((10#$days * 86400 + 10#$hours * 3600 + 10#$minutes * 60 + 10#$seconds))"
	return 0
}

# Records "start_epoch pid" for each live Git process of the current user and
# sets CGH_PROC_SCAN_OK=1 only when the listing itself succeeded.
_cgh_load_git_processes() {
	local now="$1"
	local pid="" etime="" command_name="" elapsed=0 listing=""

	CGH_GIT_PROCS=""
	CGH_PROC_SCAN_OK=0
	listing=$(LC_ALL=C ps -U "$(id -u)" -o pid= -o etime= -o comm= 2>/dev/null) || return 0
	# The listing must at least contain this shell, or it is not trustworthy.
	[[ "$listing" =~ (^|[[:space:]])$$[[:space:]] ]] || return 0
	while IFS=$' \t' read -r pid etime command_name; do
		[[ "$pid" =~ ^[0-9]+$ ]] || continue
		command_name="${command_name##*/}"
		[[ "$command_name" == "git" || "$command_name" == git-* ]] || continue
		# An unparseable start time is treated as "started long ago" (may own).
		elapsed=$(_cgh_etime_seconds "$etime") || elapsed="$now"
		CGH_GIT_PROCS="${CGH_GIT_PROCS}$((now - elapsed)) ${pid}"$'\n'
	done <<<"$listing"
	CGH_PROC_SCAN_OK=1
	return 0
}

# Returns 0 when PID may be operating on this repository (conservative), 1 not.
_cgh_process_targets_repo() {
	local pid="$1"
	local common="$2"
	local top="$3"
	local args="" cwd="" process_common="" arg0="" arg1=""

	# A failed probe cannot tell an exited process from a transient error, so
	# it means "may own"; an exited process stops blocking on the next run.
	args=$(ps -o args= -p "$pid" 2>/dev/null) || return 0
	[[ -n "$args" ]] || return 0
	# The filesystem monitor daemon never takes ref or pack locks; match only
	# the subcommand token so arbitrary argument text cannot exempt a process.
	IFS=$' \t' read -r arg0 arg1 _ <<<"$args"
	[[ "$arg1" == "fsmonitor--daemon" || "${arg0##*/}" == "git-fsmonitor--daemon" ]] && return 1
	[[ "$args" == *"$top"* || "$args" == *"$common"* ]] && return 0
	if [[ -e "/proc/${pid}/cwd" ]]; then
		cwd=$(readlink "/proc/${pid}/cwd" 2>/dev/null) || cwd=""
	elif command -v lsof >/dev/null 2>&1; then
		# awk reads all input, so lsof never sees SIGPIPE under pipefail.
		cwd=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | awk '/^n/ && !seen { print substr($0, 2); seen = 1 }') || cwd=""
	fi
	[[ -n "$cwd" && -d "$cwd" ]] || return 0
	process_common=$("$REAL_GIT" -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
	process_common=$(cd "$process_common" 2>/dev/null && pwd -P) || return 0
	[[ "$process_common" == "$common" ]] && return 0
	return 1
}

# Returns 0 when a live Git process for this repository started no later than
# MTIME (+2s clock slack) and so may own the file.
_cgh_live_git_owner() {
	local mtime="$1"
	local common="$2"
	local top="$3"
	local start="" pid="" verdict=""

	while IFS=' ' read -r start pid; do
		[[ "$start" =~ ^[0-9]+$ && "$pid" =~ ^[0-9]+$ ]] || continue
		[[ "$start" -le $((mtime + 2)) ]] || continue
		if [[ "$CGH_PID_VERDICTS" == *" ${pid}=1 "* ]]; then
			return 0
		fi
		[[ "$CGH_PID_VERDICTS" == *" ${pid}=0 "* ]] && continue
		verdict=0
		_cgh_process_targets_repo "$pid" "$common" "$top" && verdict=1
		CGH_PID_VERDICTS="${CGH_PID_VERDICTS}${pid}=${verdict} "
		[[ "$verdict" -eq 1 ]] && return 0
	done <<<"$CGH_GIT_PROCS"
	return 1
}

# Prints held, free or unknown for an open-file holder check.
_cgh_holder_state() {
	local path="$1"
	local out="" err="" rc=0 err_file=""

	# lsof/fuser exit 1 both for "no holder" and for errors, so a free verdict
	# also requires empty output and no diagnostics on stderr.
	if ! command -v lsof >/dev/null 2>&1 && ! command -v fuser >/dev/null 2>&1; then
		printf 'unknown\n'
		return 0
	fi
	err_file=$(mktemp "${TMPDIR:-/tmp}/cgh-holder.XXXXXX") || {
		printf 'unknown\n'
		return 0
	}
	if command -v lsof >/dev/null 2>&1; then
		out=$(lsof -w -t -- "$path" 2>"$err_file") || rc=$?
		err=$(cat "$err_file" 2>/dev/null) || err="unreadable"
	else
		out=$(fuser "$path" 2>"$err_file") || rc=$?
		err=$(cat "$err_file" 2>/dev/null) || err="unreadable"
		# fuser echoes "path:" on stderr even when nothing holds the file.
		err="${err//"${path}:"/}"
		err="${err//[[:space:]]/}"
	fi
	rm -f "$err_file"
	if [[ "$out" =~ [0-9] ]]; then
		printf 'held\n'
	elif [[ ( "$rc" -eq 0 || "$rc" -eq 1 ) && -z "$err" ]]; then
		printf 'free\n'
	else
		printf 'unknown\n'
	fi
	return 0
}

# gc.pid is stale only when it names a dead PID on this host.
_cgh_gc_pid_is_dead() {
	local path="$1"
	local recorded_pid="" recorded_host="" this_host=""

	# Git writes "PID HOST" without a trailing newline, so read may return 1.
	IFS=$' \t' read -r recorded_pid recorded_host <"$path" 2>/dev/null || [[ -n "$recorded_pid" ]] || return 1
	[[ "$recorded_pid" =~ ^[0-9]+$ ]] || return 1
	this_host=$(hostname 2>/dev/null) || this_host=""
	[[ -n "$recorded_host" && "$recorded_host" == "$this_host" ]] || return 1
	# Absence from ps is trusted only when process listing is known to work.
	[[ "$CGH_PROC_SCAN_OK" -eq 1 ]] || return 1
	ps -p "$recorded_pid" >/dev/null 2>&1 && return 1
	return 0
}

# Evaluates one path. Returns 0 for a removal candidate and sets
# CGH_EVAL_IDENTITY ("inode size mtime"); returns 1 and sets CGH_EVAL_REASON.
_cgh_evaluate() {
	local path="$1"
	local min_age="$2"
	local common="$3"
	local top="$4"
	local now="$5"
	local identity="" inode="" size="" mtime="" owner="" parent=""

	CGH_EVAL_REASON=""
	CGH_EVAL_IDENTITY=""
	if [[ -L "$path" || ! -f "$path" ]]; then
		CGH_EVAL_REASON="not-regular"
		return 1
	fi
	# A symlinked intermediate directory must not carry removal outside scope.
	parent=$(cd -P "${path%/*}" 2>/dev/null && pwd -P) || parent=""
	if [[ -z "$parent" || ("$parent" != "$common" && "$parent" != "$common"/*) ]]; then
		CGH_EVAL_REASON="outside-common"
		return 1
	fi
	identity=$(_cgh_file_identity "$path") || identity=""
	IFS=' ' read -r inode size mtime owner <<<"$identity"
	if [[ ! "$inode" =~ ^[0-9]+$ || ! "$size" =~ ^[0-9]+$ || ! "$mtime" =~ ^[0-9]+$ ]]; then
		CGH_EVAL_REASON="stat-failed"
		return 1
	fi
	# Holder and process checks only see this user's processes.
	if [[ "$owner" != "$(id -u)" ]]; then
		CGH_EVAL_REASON="foreign-owner"
		return 1
	fi
	if [[ "$CGH_PROC_SCAN_OK" -ne 1 ]]; then
		CGH_EVAL_REASON="process-scan-failed"
		return 1
	fi
	if [[ $((now - mtime)) -lt "$min_age" ]]; then
		CGH_EVAL_REASON="fresh"
		return 1
	fi
	if [[ "${path##*/}" == "gc.pid" ]] && ! _cgh_gc_pid_is_dead "$path"; then
		CGH_EVAL_REASON="gc-pid-live-or-foreign"
		return 1
	fi
	case "$(_cgh_holder_state "$path")" in
	free) ;;
	held)
		CGH_EVAL_REASON="held"
		return 1
		;;
	*)
		CGH_EVAL_REASON="holder-unknown"
		return 1
		;;
	esac
	if _cgh_live_git_owner "$mtime" "$common" "$top"; then
		CGH_EVAL_REASON="live-git-process"
		return 1
	fi
	CGH_EVAL_IDENTITY="${inode} ${size} ${mtime} ${owner}"
	return 0
}

# Prints "inode size mtime uid" (%i and %u are identical on GNU and BSD stat).
_cgh_file_identity() {
	local path="$1"
	[[ -f "$path" && ! -L "$path" ]] || return 1
	_stat_batch '%i %s %Y %u' "$path" || return 1
	return 0
}

# Prints "kind<TAB>absolute-path" for every path in scope.
_cgh_scope_paths() {
	local common="$1"
	local dir="" name="" path=""

	for dir in "${common}/refs" "${common}/logs/refs"; do
		[[ -d "$dir" ]] || continue
		while IFS= read -r path; do
			[[ -n "$path" ]] && printf '%s\t%s\n' "$CGH_KIND_LOCK" "$path"
		done < <(find "$dir" -name '*.lock' \( -type f -o -type l \) -print 2>/dev/null || true)
	done
	# The canonical worktree's index lives in the common directory itself.
	for name in packed-refs.lock index.lock gc.pid; do
		path="${common}/${name}"
		[[ -e "$path" || -L "$path" ]] && printf '%s\t%s\n' "$CGH_KIND_LOCK" "$path"
	done
	if [[ -d "${common}/objects/pack" ]]; then
		while IFS= read -r path; do
			[[ -n "$path" ]] && printf '%s\t%s\n' "$CGH_KIND_TMP_PACK" "$path"
		done < <(find "${common}/objects/pack" -maxdepth 1 \( -name 'tmp_*' -o -name '.tmp-*' \) \
			\( -type f -o -type l \) -print 2>/dev/null || true)
	fi
	return 0
}

# Apply mode requires the tamper-evident audit helper and an intact chain
# before any removal or gc, whether or not candidates exist.
_cgh_audit_ready() {
	[[ -x "$CGH_AUDIT_TOOL" ]] || {
		_cgh_block "tamper-evident audit helper is unavailable"
		return 1
	}
	if [[ -s "$CGH_AUDIT_FILE" ]] && ! AUDIT_LOG_FILE="$CGH_AUDIT_FILE" "$CGH_AUDIT_TOOL" verify --quiet; then
		_cgh_block "audit chain verification failed"
		return 1
	fi
	return 0
}

# Writes one audit entry: MESSAGE then "key=value" details (never a repo path).
_cgh_audit_log() {
	local message="$1"
	shift
	local detail=""
	local -a detail_args=()

	for detail in "$@"; do
		detail_args+=(--detail "$detail")
	done
	AUDIT_LOG_FILE="$CGH_AUDIT_FILE" AUDIT_QUIET=true "$CGH_AUDIT_TOOL" log operation.verify \
		"$message" "${detail_args[@]}" >/dev/null || return 1
	return 0
}

# Records removal intent before rm, then the observed outcome after it.
_cgh_remove_audited() {
	local path="$1"
	local expected="$2"
	local operation="$3"
	local repo_id="$4"
	local kind="$5"
	local relative="$6"
	local size=0 mtime=0 current="" message="" result="" status=0
	local -a details=()

	IFS=' ' read -r _ size mtime _ <<<"$expected"
	details=("operation=${operation}" "repo_id=${repo_id}" "kind=${kind}" "path=${relative}"
		"size=${size}" "mtime=${mtime}")
	_cgh_audit_log "Canonical stale Git debris removal approved" "${details[@]}" || {
		_cgh_block "recovery audit record could not be written"
		return 2
	}
	# Narrow the audit-to-removal window: the file must still be identical.
	current=$(_cgh_file_identity "$path") || current=""
	if [[ "$current" != "$expected" ]]; then
		printf 'KEPT reason=changed-before-removal path=%s\n' "$relative"
		message="Canonical stale Git debris removal abandoned"
		result="changed"
	elif rm -f -- "$path" && [[ ! -e "$path" ]]; then
		printf 'REMOVED kind=%s path=%s\n' "$kind" "$relative"
		message="Canonical stale Git debris removed"
		result="removed"
	else
		printf 'FAILED path=%s\n' "$relative" >&2
		message="Canonical stale Git debris removal failed"
		result="failed"
		status=1
	fi
	_cgh_audit_log "$message" "${details[@]}" "result=${result}" || {
		_cgh_block "recovery audit outcome could not be written"
		return 2
	}
	return "$status"
}

# Reports (and with apply=1 removes) stale debris. Prints a summary.
_cgh_repair() {
	local repo="$1"
	local common="$2"
	local lock_age="$3"
	local tmp_age="$4"
	local apply="$5"
	local operation="$6"
	local now="" kind="" path="" relative="" min_age=0 size="" mtime="" step_rc=0
	local lock_candidates=0 tmp_candidates=0 skipped=0 removed=0 failed=0 repo_id=""
	local -a plan_kinds=() plan_paths=() plan_identities=()
	local i=0

	now=$(date +%s)
	_cgh_load_git_processes "$now"
	while IFS=$'\t' read -r kind path; do
		[[ -n "$path" ]] || continue
		relative="${path#"${common}/"}"
		min_age="$lock_age"
		[[ "$kind" == "$CGH_KIND_TMP_PACK" ]] && min_age="$tmp_age"
		if _cgh_evaluate "$path" "$min_age" "$common" "$repo" "$now"; then
			IFS=' ' read -r _ size mtime _ <<<"$CGH_EVAL_IDENTITY"
			printf 'CANDIDATE kind=%s path=%s size=%s mtime=%s age_minutes=%s\n' \
				"$kind" "$relative" "$size" "$mtime" "$(((now - mtime) / 60))"
			plan_kinds+=("$kind")
			plan_paths+=("$path")
			plan_identities+=("$CGH_EVAL_IDENTITY")
			if [[ "$kind" == "$CGH_KIND_TMP_PACK" ]]; then
				tmp_candidates=$((tmp_candidates + 1))
			else
				lock_candidates=$((lock_candidates + 1))
			fi
		else
			printf 'SKIP reason=%s kind=%s path=%s\n' "$CGH_EVAL_REASON" "$kind" "$relative"
			skipped=$((skipped + 1))
		fi
	done < <(_cgh_scope_paths "$common")
	printf 'STALE_LOCK_CANDIDATES=%s\nTMP_PACK_CANDIDATES=%s\nSKIPPED=%s\n' \
		"$lock_candidates" "$tmp_candidates" "$skipped"
	if [[ "$apply" -ne 1 ]]; then
		printf 'MODE=dry-run\n'
		return 0
	fi
	printf 'MODE=apply\n'
	[[ ${#plan_paths[@]} -gt 0 ]] || {
		printf 'REMOVED=0\n'
		return 0
	}
	repo_id=$(printf '%s' "$common" | "$REAL_GIT" hash-object --stdin) || repo_id="unknown"
	repo_id="${repo_id:0:12}"
	now=$(date +%s)
	CGH_PID_VERDICTS=" "
	_cgh_load_git_processes "$now"
	for ((i = 0; i < ${#plan_paths[@]}; i++)); do
		path="${plan_paths[$i]}"
		kind="${plan_kinds[$i]}"
		relative="${path#"${common}/"}"
		min_age="$lock_age"
		[[ "$kind" == "$CGH_KIND_TMP_PACK" ]] && min_age="$tmp_age"
		# Every gate is re-checked; the file must also be the one reported.
		if ! _cgh_evaluate "$path" "$min_age" "$common" "$repo" "$now" ||
			[[ "$CGH_EVAL_IDENTITY" != "${plan_identities[$i]}" ]]; then
			printf 'KEPT reason=%s path=%s\n' "${CGH_EVAL_REASON:-changed}" "$relative"
			continue
		fi
		step_rc=0
		_cgh_remove_audited "$path" "${plan_identities[$i]}" "$operation" "$repo_id" \
			"$kind" "$relative" || step_rc=$?
		case "$step_rc" in
		0) [[ -e "$path" ]] || removed=$((removed + 1)) ;;
		1) failed=$((failed + 1)) ;;
		*) return 1 ;;
		esac
	done
	printf 'REMOVED=%s\n' "$removed"
	[[ "$failed" -eq 0 ]] || return 1
	return 0
}

_cgh_release_lock() {
	local lock_dir="$1"
	[[ "$CGH_LOCK_HELD" -eq 1 ]] && crl_release "$lock_dir"
	CGH_LOCK_HELD=0
	return 0
}

# Runs git gc --auto in the foreground and fails on reflog/lock errors.
_cgh_run_gc() {
	local repo="$1"
	local common="$2"
	local output="" rc=0 result="ok" repo_id=""

	output=$("$REAL_GIT" -C "$repo" -c gc.autoDetach=false -c maintenance.autoDetach=false \
		gc --auto --quiet 2>&1) || rc=$?
	[[ -n "$output" ]] && printf '%s\n' "$output" >&2
	if [[ "$rc" -ne 0 || "$output" == *"failed to run reflog"* || "$output" == *"Unable to create"* ]]; then
		result="failed"
	fi
	repo_id=$(printf '%s' "$common" | "$REAL_GIT" hash-object --stdin) || repo_id="unknown"
	_cgh_audit_log "Canonical sanctioned git gc --auto" "operation=${CGH_GC_CMD}" \
		"repo_id=${repo_id:0:12}" "result=${result}" "exit=${rc}" || {
		_cgh_block "gc audit outcome could not be written"
		result="audit-failed"
	}
	printf 'GC_RESULT=%s\n' "$result"
	[[ "$result" == "ok" ]] || return 1
	return 0
}

cgh_main() {
	local cmd="$1"
	shift
	local repo="" apply=0 lock_minutes="$CGH_DEFAULT_MIN_AGE_MINUTES" tmp_days="$CGH_DEFAULT_TMP_MIN_AGE_DAYS"
	local git_dir="" common="" lock_dir="" rc=0 option="" value="" index=0
	local -a options=("$@")

	while [[ "$index" -lt "${#options[@]}" ]]; do
		option="${options[$index]}"
		value="${options[$((index + 1))]:-}"
		case "$option" in
		--repo | --min-age-minutes | --tmp-min-age-days)
			[[ $((index + 1)) -lt "${#options[@]}" ]] || {
				_cgh_usage
				return 2
			}
			[[ "$option" == "--repo" ]] && repo="$value"
			[[ "$option" == "--min-age-minutes" ]] && lock_minutes="$value"
			[[ "$option" == "--tmp-min-age-days" ]] && tmp_days="$value"
			index=$((index + 2))
			;;
		--apply)
			apply=1
			index=$((index + 1))
			;;
		--dry-run)
			apply=0
			index=$((index + 1))
			;;
		*)
			_cgh_usage
			return 2
			;;
		esac
	done
	if [[ -z "$repo" || ! -d "$repo" || ! "$lock_minutes" =~ ^[0-9]+$ || ! "$tmp_days" =~ ^[0-9]+$ ]]; then
		_cgh_usage
		return 2
	fi
	repo=$(cd "$repo" && pwd -P) || return 2
	# shellcheck source=runtime-env.sh
	# shellcheck disable=SC1091  # resolved at runtime via $SCRIPT_DIR
	source "${SCRIPT_DIR}/runtime-env.sh"
	REAL_GIT="${AIDEVOPS_REAL_GIT_BIN:-aidevops-native-git-not-found}"
	CGH_AUDIT_TOOL="${SCRIPT_DIR}/audit-log-helper.sh"
	CGH_AUDIT_FILE="${AIDEVOPS_CANONICAL_RECOVERY_AUDIT_FILE:-${HOME}/.aidevops/logs/canonical-recovery-audit.jsonl}"
	# Repository identity comes only from --repo, never an inherited Git env.
	unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
	git_dir=$("$REAL_GIT" -C "$repo" rev-parse --path-format=absolute --git-dir 2>/dev/null) || git_dir=""
	common=$("$REAL_GIT" -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common=""
	[[ -n "$git_dir" && "$git_dir" == "$common" && "$common" != "$repo" ]] || {
		_cgh_block "target is not a canonical (non-bare main) worktree"
		return 1
	}
	common=$(cd "$common" && pwd -P) || return 1
	lock_dir="${common}/aidevops-canonical-recovery.lock"
	CGH_LOCK_DIR="$lock_dir"
	if [[ "$apply" -eq 1 ]]; then
		crl_acquire "$lock_dir" "$cmd" || {
			printf 'BUSY: canonical recovery lock is already held\n' >&2
			return "$CGH_LOCK_BUSY_EXIT"
		}
		CGH_LOCK_HELD=1
		# Read the path from a global at exit so no path text is re-parsed.
		trap '_cgh_release_lock "$CGH_LOCK_DIR"' EXIT
		# Every apply path (repair and gc, with or without candidates) needs a
		# working, intact audit chain before it changes anything.
		_cgh_audit_ready || {
			_cgh_release_lock "$lock_dir"
			return 1
		}
	fi
	_cgh_repair "$repo" "$common" "$((lock_minutes * 60))" "$((tmp_days * 86400))" "$apply" "$cmd" || rc=$?
	if [[ "$cmd" == "$CGH_GC_CMD" && "$rc" -eq 0 ]]; then
		if [[ "$apply" -eq 1 ]]; then
			_cgh_run_gc "$repo" "$common" || rc=$?
		else
			printf 'GC_PLAN=git gc --auto (foreground, after debris repair; add --apply)\n'
		fi
	fi
	_cgh_release_lock "$lock_dir"
	return "$rc"
}
