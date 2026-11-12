#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Sealed-generation recovery. Removal always delegates to the archive-backed
# helper (including its fresh process/ownership checks); never force removal.

_dlw_classify_sealed_candidate() {
	local path="$1" issue="$2" repo="$3"
	local record="" rc=0 branch=""
	record=$(python3 "$(_dlw_lifetime_helper)" status "$path" 2>/dev/null) || rc=$?
	if [[ "$rc" == 3 ]]; then
		# Lifecycle-only generations have no old managed enrollment. Preserve
		# legacy branch identity, tightened to an explicit terminal issue suffix.
		branch=$(git -C "$path" symbolic-ref --short HEAD) || return 1
		[[ "$branch" =~ (^|[/_-])gh-?${issue}$ ]] && printf 'sealed\n'
		return 0
	fi
	[[ "$rc" == 0 ]] || return 1
	# Branch names only nominate enrolled candidates. Never retire a generation
	# with a missing/different enrolled task, even if its Git tree is empty.
	jq -e '.task.issue != null and .task.repo != null' <<<"$record" >/dev/null || return 1
	if jq -e --arg issue "$issue" --arg repo "$repo" \
		'.task.issue == $issue and .task.repo == $repo' <<<"$record" >/dev/null; then
		printf 'sealed\n'
	fi
	return 0
}

_dispatch_skip_for_sealed_generation() {
	local repo_path="$1" issue="$2" repo="$3"
	declare -F _dlw_sealed_hold_active >/dev/null 2>&1 || return 1
	_dlw_sealed_hold_active "$repo_path" "$issue" "$repo" || return 1
	return 0
}

_dlw_sealed_hold_file() {
	local issue="$1" repo="$2"
	[[ "$issue" =~ ^[0-9]+$ && "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
	printf '%s/%s--%s.json\n' "${AIDEVOPS_DISPATCH_SEALED_HOLD_DIR:-${HOME}/.aidevops/logs/dispatch-sealed-generation}" "${repo//\//--}" "$issue"
	return 0
}

# Local-only fingerprint: paths stay in the private cache, never in diagnostics.
# Include lifecycle admission so unsealing/replacing a generation wakes it too.
_dlw_sealed_snapshot() {
	local repo_path="$1" issue="$2" repo="$3"
	local line="" path="" branch="" class="" status="" head="" snapshot="" listing="" base="" ahead=""
	listing=$(git -C "$repo_path" worktree list --porcelain) || return 1
	base=$(git -C "$repo_path" rev-parse --verify refs/remotes/origin/HEAD 2>/dev/null) || base="default_unavailable"
	while IFS= read -r line; do
		case "$line" in
		"worktree "*) path="${line#worktree }"; continue ;;
		"branch refs/heads/"*) branch="${line#branch refs/heads/}" ;;
		*) continue ;;
		esac
		[[ "$branch" =~ gh-?${issue}([^0-9]|$) && -n "$path" && -d "$path" ]] || continue
		class=$(_dlw_classify_reuse_candidate "$path" "$issue" "$repo") || return 1
		status=$(git -C "$path" status --porcelain --ignored --untracked-files=all) || return 1
		head=$(git -C "$path" rev-parse HEAD) || return 1
		# Unrelated default-branch commits must not wake a protected checkpoint.
		# Only integration of its commits changes its ahead evidence.
		ahead=$(git -C "$path" rev-list --count "${base}..HEAD" 2>/dev/null) || ahead="default_unavailable"
		snapshot+=$'\n'"${path}|${branch}|${class}|${head}|${ahead}|${status}"
	done <<<"$listing"
	printf '%s' "$snapshot" | git -C "$repo_path" hash-object --stdin
	return "${PIPESTATUS[1]}"
}

_dlw_sealed_hold_active() {
	local repo_path="$1" issue="$2" repo="$3"
	local file="" fingerprint="" saved="" stamp="" reason="" now=""
	file=$(_dlw_sealed_hold_file "$issue" "$repo") || return 1
	[[ -f "$file" ]] || return 1
	IFS='|' read -r saved stamp reason < <(jq -er '[.fingerprint,.stamp,.reason] | join("|")' "$file" 2>/dev/null)
	[[ "$stamp" =~ ^[0-9]+$ ]] || return 1
	# Unavailable APIs/process evidence can recover without a Git change.
	case "$reason" in
	dirty|unpublished_commits)
		now=$(date +%s); [[ $((now - stamp)) -lt 86400 ]] || return 1 ;;
	*) now=$(date +%s); [[ $((now - stamp)) -lt 300 ]] || return 1 ;;
	esac
	fingerprint=$(_dlw_sealed_snapshot "$repo_path" "$issue" "$repo") || return 1
	[[ "$fingerprint" == "$saved" ]] || return 1
	return 0
}

_dlw_sealed_hold_record() {
	local repo_path="$1" issue="$2" repo="$3" reason="$4" expected="$5"
	local file="" fingerprint="" temporary="" unchanged=0
	file=$(_dlw_sealed_hold_file "$issue" "$repo") || return 1
	fingerprint=$(_dlw_sealed_snapshot "$repo_path" "$issue" "$repo") || return 1
	# Refusal evidence must describe this snapshot, not a state that changed
	# between the dirt/ahead probe and persistence (which could hold an empty tree).
	[[ -n "$expected" && "$fingerprint" == "$expected" ]] || return 1
	if [[ -f "$file" ]] && jq -e --arg fingerprint "$fingerprint" --arg reason "$reason" \
		'.fingerprint == $fingerprint and .reason == $reason' "$file" >/dev/null 2>&1; then
		unchanged=1
	fi
	mkdir -p "${file%/*}" || return 1
	temporary=$(mktemp "${file}.XXXXXX") || return 1
	jq -cn --arg fingerprint "$fingerprint" --arg reason "$reason" --argjson stamp "$(date +%s)" \
		'{fingerprint:$fingerprint,reason:$reason,stamp:$stamp}' >"$temporary" && mv "$temporary" "$file" || return 1
	if [[ "$unchanged" == 0 ]]; then
		echo "[dispatch_worker_launch] worktree_reuse_sealed_generation issue=#${issue} path_class=sealed_issue_generation reason=${reason} action=hold_until_state_changes no_wave_slot_spent=true" >>"${LOGFILE:-/dev/null}"
	fi
	return 0
}

# Only empty generations qualify: even pushed task commits ahead of the default
# are preserved. Unknown Git/GitHub evidence is never evidence of emptiness.
_dlw_retire_empty_sealed() {
	local path="$1" branch="$2" repo="$3"
	local status="" base="" ahead="" prs="" output="" entry="" head=""
	_DLW_SEALED_REASON="evidence_unavailable"
	status=$(git -C "$path" status --porcelain --ignored --untracked-files=all) || return 1
	while IFS= read -r entry; do
		case "$entry" in
		""|"!! .metadata_never_index"|"?? .metadata_never_index") ;;
		*) _DLW_SEALED_REASON="dirty"; return 1 ;;
		esac
	done <<<"$status"
	base=$(git -C "$path" symbolic-ref refs/remotes/origin/HEAD) || return 1
	[[ "$base" == refs/remotes/origin/* ]] || return 1
	ahead=$(git -C "$path" rev-list --count "${base}..HEAD") || return 1
	if [[ "$ahead" != 0 ]]; then
		_DLW_SEALED_REASON="unpublished_commits"
		return 1
	fi
	[[ -n "$repo" ]] || return 1
	head=$(git -C "$path" rev-parse HEAD) || return 1
	# Share the lifecycle's complete fork/parent/source lookup and exact HEAD
	# matching. A failed lookup must hold, never authorize retirement.
	prs=$(python3 -E -s -B -c '
import sys
sys.path.insert(0, sys.argv[1])
from worker_lifecycle.pull_requests import open_pull_requests, matches_open_pull_request
repo, head, branch = sys.argv[2:]
print("open_pr" if matches_open_pull_request(open_pull_requests(repo), head, branch, repo) else "")
' "${_DLW_SYSTEMD_MODULE_DIR}/../worker-lifecycle" "$repo" "$head" "refs/heads/$branch" 2>/dev/null) || return 1
	[[ -z "$prs" ]] || { _DLW_SEALED_REASON="open_pr"; return 1; }
	_DLW_SEALED_REASON="guarded_retirement_refused"
	output=$("${SCRIPT_DIR}/worktree-helper.sh" remove "$path" 2>/dev/null) || return 1
	# Exit zero alone is not proof: require the guarded retirement receipt and
	# disappearance of the source before allowing a parallel fresh generation.
	[[ ! -e "$path" ]] && jq -e '.status == "retired"' <<<"$output" >/dev/null || return 1
	return 0
}
