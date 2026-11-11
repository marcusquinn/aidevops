#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Sealed-generation recovery. Removal always delegates to the archive-backed
# helper (including its fresh process/ownership checks); never force removal.

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
	local line="" path="" branch="" class="" status="" head="" snapshot="" listing="" base=""
	listing=$(git -C "$repo_path" worktree list --porcelain) || return 1
	base=$(git -C "$repo_path" rev-parse refs/remotes/origin/HEAD) || return 1
	snapshot="$base"
	while IFS= read -r line; do
		case "$line" in
		"worktree "*) path="${line#worktree }"; continue ;;
		"branch refs/heads/"*) branch="${line#branch refs/heads/}" ;;
		*) continue ;;
		esac
		[[ "$branch" =~ gh-?${issue}([^0-9]|$) ]] || continue
		class=$(_dlw_classify_reuse_candidate "$path" "$issue" "$repo") || return 1
		status=$(git -C "$path" status --porcelain --ignored --untracked-files=all) || return 1
		head=$(git -C "$path" rev-parse HEAD) || return 1
		snapshot+=$'\n'"${path}|${branch}|${class}|${head}|${status}"
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
	dirty|unpublished_commits) ;;
	*) now=$(date +%s); [[ $((now - stamp)) -lt 300 ]] || return 1 ;;
	esac
	fingerprint=$(_dlw_sealed_snapshot "$repo_path" "$issue" "$repo") || return 1
	[[ "$fingerprint" == "$saved" ]] || return 1
	return 0
}

_dlw_sealed_hold_record() {
	local repo_path="$1" issue="$2" repo="$3" reason="$4"
	local file="" fingerprint="" temporary=""
	file=$(_dlw_sealed_hold_file "$issue" "$repo") || return 1
	fingerprint=$(_dlw_sealed_snapshot "$repo_path" "$issue" "$repo") || return 1
	mkdir -p "${file%/*}" || return 1
	temporary=$(mktemp "${file}.XXXXXX") || return 1
	jq -cn --arg fingerprint "$fingerprint" --arg reason "$reason" --argjson stamp "$(date +%s)" \
		'{fingerprint:$fingerprint,reason:$reason,stamp:$stamp}' >"$temporary" && mv "$temporary" "$file" || return 1
	echo "[dispatch_worker_launch] worktree_reuse_sealed_generation issue=#${issue} path_class=sealed_issue_generation reason=${reason} action=hold_until_state_changes no_wave_slot_spent=true" >>"${LOGFILE:-/dev/null}"
	return 0
}

# Only empty generations qualify: even pushed task commits ahead of the default
# are preserved. Unknown Git/GitHub evidence is never evidence of emptiness.
_dlw_retire_empty_sealed() {
	local path="$1" branch="$2" repo="$3"
	local status="" base="" ahead="" prs="" output="" entry=""
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
	prs=$(gh pr list --repo "$repo" --state open --head "$branch" --json number 2>/dev/null) || return 1
	jq -e 'type == "array" and length == 0' <<<"$prs" >/dev/null || { _DLW_SEALED_REASON="open_pr"; return 1; }
	_DLW_SEALED_REASON="guarded_retirement_refused"
	output=$("${SCRIPT_DIR}/worktree-helper.sh" remove "$path" 2>/dev/null) || return 1
	# Exit zero alone is not proof: require the guarded retirement receipt and
	# disappearance of the source before allowing a parallel fresh generation.
	[[ ! -e "$path" ]] && jq -e '.status == "retired"' <<<"$output" >/dev/null || return 1
	return 0
}
