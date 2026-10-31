#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Central/unregistered worktree discovery and third-party recovery.
# Sourced by pulse-cleanup-worktree-removal.sh with shared cleanup dependencies.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail
[[ -n "${_PULSE_CLEANUP_WORKTREE_REMOVAL_CENTRAL_LOADED:-}" ]] && return 0
_PULSE_CLEANUP_WORKTREE_REMOVAL_CENTRAL_LOADED=1

# Invalid registrations are a daily diagnostic, not a per-cycle log storm.
_pc_log_invalid_repo_path_once() {
	local repo_slug="$1"
	local day="" marker="" log_dir=""
	day=$(date -u +%Y-%m-%d) || return 1
	log_dir="${AIDEVOPS_LOG_DIR:-${HOME}/.aidevops/logs}"
	# A slug is untrusted configuration; use a fixed marker plus a safe hash.
	marker="${log_dir}/invalid-repo-path-${day}-$(printf '%s' "$repo_slug" | git hash-object --stdin)"
	if [[ ! -e "$marker" ]]; then
		mkdir -p "$log_dir" || return 1
		if ( set -C; : >"$marker" ) 2>/dev/null; then
			printf '[pulse-cleanup] stage=merged-pr repo=%s skipping cleanup — invalid repo path configured\n' "$repo_slug" >>"${LOGFILE:-/dev/null}"
		fi
	fi
	return 0
}

# Resolve only an ordinary, top-level Git linked worktree with a live main
# checkout. Never follow a symlink or infer a canonical repo from a directory
# name; missing canonical repositories are human-owned recovery decisions.
_pc_central_canonical() {
	local candidate="$1" pointer="" gitdir="" canonical="" common=""
	[[ -d "$candidate" && ! -L "$candidate" && -f "$candidate/.git" && ! -L "$candidate/.git" ]] || return 1
	IFS= read -r pointer <"$candidate/.git" || [[ -n "$pointer" ]] || return 1
	[[ "$pointer" == 'gitdir: /'*/.git/worktrees/* ]] || return 1
	gitdir="${pointer#gitdir: }"
	canonical="${gitdir%/.git/worktrees/*}"
	[[ "$canonical" == /* && "$canonical" != "$candidate" && "$canonical" != *'/../'* && "$canonical" != *'/./'* ]] || return 1
	if [[ ! -d "$canonical/.git" || ! -d "$gitdir" ]]; then
		printf '[pulse-cleanup] stage=central-unregistered path=%s skip=orphaned-canonical\n' "$candidate" >>"${LOGFILE:-/dev/null}"
		return 1
	fi
	common=$(git -C "$candidate" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
	[[ "$common" == "$canonical/.git" ]] || return 1
	[[ "$(git -C "$canonical" rev-parse --show-toplevel 2>/dev/null)" == "$canonical" ]] || return 1
	printf '%s\n' "$canonical"
	return 0
}

# Only accept an exact GitHub remote identity; an unknown host/slug is not
# evidence that no PR exists. Cache attempts, including errors, for one UTC day.
_pc_thirdparty_pr() {
	local path="$1" branch="$2" cache="$3" remote="" url="" slug="" result="" day=""
	day=$(date -u +%Y-%m-%d) || return 1
	if [[ -f "$cache" ]] && jq -e --arg day "$day" '.day == $day' "$cache" >/dev/null 2>&1; then
		result=$(jq -c --arg branch "$branch" 'select(.branch == $branch and .verified == true) | .pr' "$cache" 2>/dev/null) || return 1
		[[ -n "$result" ]] || return 1
		printf '%s\n' "$result"; return 0
	fi
	# Claim the daily lookup slot before contacting the API. A failed query is
	# held uncertain rather than retried eight times by repeated pulse cycles.
	jq -cn --arg day "$day" --arg branch "$branch" '{day:$day,branch:$branch,verified:false}' >"$cache" || return 1
	for remote in upstream origin; do
		url=$(git -C "$path" remote get-url "$remote" 2>/dev/null) || continue
		case "$url" in
		https://github.com/*) slug="${url#https://github.com/}" ;;
		git@github.com:*) slug="${url#git@github.com:}" ;;
		*) continue ;;
		esac
		slug="${slug%.git}"
		[[ "$slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || continue
		# Fetch all pages, including old closed PRs. An API error cannot be
		# interpreted as proof that no PR exists.
		result=$(gh api --paginate --slurp "repos/${slug}/pulls?state=all&per_page=100" 2>/dev/null |
			jq -c --arg branch "$branch" '[.[][] | select(.head.ref == $branch) | {number, state, merged_at}] as $prs | ([$prs[] | select(.state == "open")][0] // $prs[0] // null)') || return 1
		if [[ "$result" != null ]]; then break; fi
	done
	[[ -n "$slug" && -n "$result" ]] || return 1
	if [[ "$result" != null ]]; then
		result=$(jq -cn --argjson pr "$result" --arg repo "$slug" '$pr + {repo:$repo}') || return 1
	fi
	jq -cn --arg day "$day" --arg branch "$branch" --argjson pr "$result" '{day:$day,branch:$branch,verified:true,pr:$pr}' >"$cache" || return 1
	printf '%s\n' "$result"
	return 0
}

_pc_thirdparty_report_once() {
	local path="$1" marker="" day=""
	day=$(date -u +%Y-%m-%d) || return 1
	marker="${AIDEVOPS_LOG_DIR:-${HOME}/.aidevops/logs}/thirdparty-unsent-${day}-$(printf '%s' "$path" | git hash-object --stdin)"
	if (set -C; : >"$marker") 2>/dev/null; then
		printf '[pulse-cleanup] thirdparty-open-pr-unsent-work path=%s\n' "$path" >>"${LOGFILE:-/dev/null}"
	fi
	return 0
}

# Orphaned gitdir: a bounded, symlink-free file snapshot in the recovery root.
# Verify the archive against its source before any recoverable trash move.
_pc_archive_missing_canonical() {
	local path="$1" archive="" root="${AIDEVOPS_WORKTREE_ARCHIVE_ROOT:-${HOME}/.aidevops/recovery/archives}"
	archive="${root}/orphan-$(date -u +%Y%m%dT%H%M%S)-$(printf '%s' "$path" | git hash-object --stdin).tar"
	mkdir -p "$root" || return 1
	python3 - "$path" "$archive" <<'PY'
import hashlib, os, pathlib, stat, sys, tarfile
source, output = map(pathlib.Path, sys.argv[1:])
def digest(stream):
    result = hashlib.sha256()
    for chunk in iter(lambda: stream.read(1024 * 1024), b''):
        result.update(chunk)
    return result.digest()
files = []
total = 0
for parent, dirs, names in os.walk(source, followlinks=False):
    for name in dirs + names:
        item = pathlib.Path(parent) / name
        mode = item.lstat().st_mode
        if not (stat.S_ISDIR(mode) or stat.S_ISREG(mode)):
            sys.exit(1)
        if stat.S_ISREG(mode):
            total += item.stat().st_size
            files.append(item)
        if len(files) > 10000 or total > 1073741824:
            sys.exit(1)
with tarfile.open(output, 'x') as bundle:
    for item in files:
        bundle.add(item, arcname=str(item.relative_to(source)), recursive=False)
with tarfile.open(output, 'r') as bundle:
    members = bundle.getmembers()
    if len(members) != len(files):
        sys.exit(1)
    for item, member in zip(files, members):
        if not member.isfile() or member.name != str(item.relative_to(source)):
            sys.exit(1)
        with item.open('rb') as original, bundle.extractfile(member) as saved:
            if saved is None or digest(original) != digest(saved):
                sys.exit(1)
PY
	[[ "$?" -eq 0 && -f "$archive" ]] || return 1
	printf '%s\n' "$archive"
	return 0
}

_pc_thirdparty_candidate() {
	local candidate="$1" canonical="$2" cache="$3" apply="$4" branch="" pr="" state="" unique="" activity="" age="" archive=""
	[[ -f "$candidate/.git" && ! -L "$candidate/.git" ]] || return 1
	# The missing-canonical branch below also bypasses native Git removal.
	worktree_managed_require_removal_proof "$candidate" || return 1
	_pc_unattributed_archive_policy_clear "$candidate" >/dev/null || return 1
	_worktree_owner_alive "$candidate" "" && return 1
	_pc_fixture_process_clear "$candidate" || return 1
	if [[ -z "$canonical" ]]; then
		[[ "$(<"$candidate/.git")" == 'gitdir: /'*/.git/worktrees/* ]] || return 1
		[[ "$apply" == 1 ]] || { printf 'orphan-candidate\n'; return 0; }
		archive=$(_pc_archive_missing_canonical "$candidate") || return 1
		_pc_fixture_process_clear "$candidate" && ! _worktree_owner_alive "$candidate" "" &&
			_pc_unattributed_archive_policy_clear "$candidate" >/dev/null && _pc_trash_orphan_dir "$candidate" || return 1
		printf 'orphan-removed\n'
		return 0
	fi
	branch=$(git -C "$candidate" symbolic-ref --short -q HEAD 2>/dev/null) || return 1
	[[ -n "$branch" ]] || return 1
	pr=$(_pc_thirdparty_pr "$candidate" "$branch" "$cache") || return 1
	unique=$(_pc_unregistered_unique_work "$candidate") || return 1
	state=$(jq -r '.state // "none" | ascii_upcase' <<<"$pr") || return 1
	if [[ "$state" == OPEN ]]; then
		[[ "$unique" == yes ]] && _pc_thirdparty_report_once "$candidate"
		printf 'open-pr\n'
		return 0
	fi
	[[ "$state" == CLOSED || "$state" == NONE ]] || return 1
	if [[ "$state" == NONE ]]; then
		activity=$(_pc_unregistered_activity_epoch "$candidate") || return 1
		age="${WORKTREE_UNREGISTERED_MAX_AGE_DAYS:-30}"
		[[ "$age" =~ ^[1-9][0-9]*$ ]] || return 1
		if (( $(date +%s) - activity < age * 86400 )); then
			printf 'young\n'
			return 0
		fi
	fi
	[[ "$apply" == 1 ]] || { printf 'eligible\n'; return 0; }
	# The registry owns eligibility, preservation and retirement as one operation.
	# Never allocate a legacy archive before it can reject an unregistered path.
	# shellcheck source=./worker-lifecycle-state.sh
	source "${BASH_SOURCE[0]%/*}/worker-lifecycle-state.sh" || return 1
	worker_lifecycle_cleanup_worktree "$candidate" >>"${LOGFILE:-/dev/null}" 2>&1 || return 1
	printf 'archived-removed\n'
	return 0
}

# Bounded rotating scan; report-only by default until rollout is explicitly
# enabled after a clean report cycle.
_pc_cleanup_central_unregistered() {
	local base="" repos_json="${HOME}/.config/aidevops/repos.json" cursor="" last="" candidate="" canonical="" scanned=0
	local candidates=() entry="" index=0 start=0 length=0 decision="" cache="" bytes=0 eligible=0 candidate_bytes=0 removed=0 archived=0 kept_open_pr=0 apply="${WORKTREE_UNREGISTERED_APPLY:-0}" budget=""
	base=$(aidevops_worktree_base_dir_configured) || { printf '0\n'; return 0; }
	[[ -d "$base" && ! -L "$base" ]] || { printf '0\n'; return 0; }
	[[ -f "$repos_json" ]] && jq -e '.initialized_repos | type == "array"' "$repos_json" >/dev/null 2>&1 || { printf '0\n'; return 0; }
	[[ "$apply" == 0 || "$apply" == 1 ]] || { printf '0\n'; return 0; }
	budget=$(gh api rate_limit --jq '.resources.graphql.remaining' 2>/dev/null) || budget=""
	[[ "$budget" =~ ^[0-9]+$ && "$budget" -ge 100 ]] || {
		printf '[pulse-cleanup] thirdparty skip=api-budget\n' >>"${LOGFILE:-/dev/null}"
		printf '0\n'; return 0;
	}
	for entry in "$base"/*; do
		[[ -d "$entry" && ! -L "$entry" ]] && candidates+=("$entry")
	done
	length=${#candidates[@]}
	[[ "$length" -gt 0 ]] || {
		printf '[pulse-cleanup] thirdparty eligible=0 candidate_bytes=0 removed=0 archived=0 kept_open_pr=0 scanned=0\n' >>"${LOGFILE:-/dev/null}"
		printf '0\n'; return 0;
	}
	cursor="${AIDEVOPS_LOG_DIR:-${HOME}/.aidevops/logs}/central-unregistered-next"
	[[ ! -f "$cursor" ]] || IFS= read -r last <"$cursor" || true
	for ((index=0; index<length; index++)); do
		if [[ "${candidates[$index]}" == "$last" ]]; then
			start=$(((index + 1) % length))
			break
		fi
	done
	for ((index=0; index<length && index<8; index++)); do
		candidate="${candidates[$(((start + index) % length))]}"
		mkdir -p "${cursor%/*}" || break
		printf '%s\n' "$candidate" >"$cursor" || break
		scanned=$((scanned + 1))
		canonical=$(_pc_central_canonical "$candidate") || canonical=""
		# A malformed pointer is not a missing canonical repo.
		if [[ -z "$canonical" ]]; then
			[[ -f "$candidate/.git" && "$(<"$candidate/.git")" == 'gitdir: /'*/.git/worktrees/* ]] || continue
			entry="$(<"$candidate/.git")"
			entry="${entry#gitdir: }"
			entry="${entry%/.git/worktrees/*}"
			[[ ! -e "$entry" ]] || continue
		fi
		# A valid registered canonical (including local_only) is owned by the
		# existing repo policy, never by this pass.
		if [[ -f "$repos_json" ]] && command -v jq >/dev/null 2>&1 &&
			jq -e --arg path "$canonical" '.initialized_repos[]? | select(.path == $path)' "$repos_json" >/dev/null 2>&1; then
			continue
		fi
		cache="${cursor%/*}/thirdparty-pr-$(printf '%s' "$candidate" | git hash-object --stdin).json"
		bytes=$(du -sk "$candidate" 2>/dev/null | cut -f1) || bytes=0
		decision=$(_pc_thirdparty_candidate "$candidate" "$canonical" "$cache" "$apply") || decision="skipped"
		case "$decision" in
		eligible | orphan-candidate | removed | orphan-removed | archived-removed)
			eligible=$((eligible + 1))
			[[ "$bytes" =~ ^[0-9]+$ ]] && candidate_bytes=$((candidate_bytes + bytes * 1024))
			;;
		esac
		case "$decision" in
		removed | orphan-removed | archived-removed)
			removed=$((removed + 1))
			[[ "$decision" != removed ]] && archived=$((archived + 1))
			;;
		open-pr) kept_open_pr=$((kept_open_pr + 1)) ;;
		esac
		printf '[pulse-cleanup] thirdparty path=%s decision=%s mode=%s\n' "$candidate" "$decision" "$apply" >>"${LOGFILE:-/dev/null}"
	done
	printf '[pulse-cleanup] thirdparty eligible=%s candidate_bytes=%s removed=%s archived=%s kept_open_pr=%s scanned=%s\n' "$eligible" "$candidate_bytes" "$removed" "$archived" "$kept_open_pr" "$scanned" >>"${LOGFILE:-/dev/null}"
	printf '%s\n' "$removed"
	return 0
}
