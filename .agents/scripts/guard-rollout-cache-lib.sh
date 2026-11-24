#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Conservative setup optimization: receipts never replace installer policy.

[[ -n "${_AIDEVOPS_GUARD_CACHE_LOADED:-}" ]] && return 0
_AIDEVOPS_GUARD_CACHE_LOADED=1
GUARD_CACHE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=git-hooks-path-lib.sh
source "${GUARD_CACHE_LIB_DIR}/git-hooks-path-lib.sh"

guard_rollout_hash() {
	local digest=""
	if command -v sha256sum >/dev/null 2>&1; then
		digest=$(sha256sum "$@" 2>/dev/null) || return 1
	else
		digest=$(shasum -a 256 "$@" 2>/dev/null) || return 1
	fi
	printf '%s\n' "$digest"
	return 0
}

# Once per rollout stage, not per repository. Hash contents (not mtimes),
# including the source templates and resolver used by the installer.
guard_rollout_fingerprint() {
	local installer="$1"
	local dir="${installer%/*}" inputs=""
	dir=$(cd "$dir" && pwd) || return 1
	installer="$dir/${installer##*/}"
	inputs=$(guard_rollout_hash "$installer" \
		"$GUARD_CACHE_LIB_DIR/guard-rollout-cache-lib.sh" \
		"$dir/git-hooks-path-lib.sh" "$dir"/../hooks/*.sh \
		"$dir/pre-commit-hook.sh") || return 1
	printf '%s\n' "$inputs" | guard_rollout_hash
	return "${PIPESTATUS[1]}"
}

# A receipt binds the entire executable dispatcher, not just a copyable header.
# Rewrites by another installer invalidate it safely. Never source receipts.
guard_rollout_record() {
	local hook="$1" installer="$2"
	local fingerprint="" digest="" staged=""
	[[ -f "$hook" && ! -L "$hook" && -x "$hook" ]] || return 1
	fingerprint=$(guard_rollout_fingerprint "$installer") || return 1
	digest=$(guard_rollout_hash "$hook") || return 1
	staged=$(mktemp "${hook}.aidevops-current.XXXXXX") || return 1
	if ! printf '%s\n%s\n' "$fingerprint" "$digest" >"$staged" ||
		! mv -f "$staged" "${hook}.aidevops-current"; then
		rm -f "$staged"
		return 1
	fi
	return 0
}

guard_rollout_current() {
	local repo="$1" hook_name="$2" marker="$3" fingerprint="$4"
	local hooks_dir="" hook="" expected="" digest=""
	[[ -n "$fingerprint" ]] || return 1
	hooks_dir=$(aidevops_git_hooks_dir "$repo") || return 1
	hook="$hooks_dir/$hook_name"
	[[ -f "$hook" && ! -L "$hook" && -x "$hook" && -f "${hook}.aidevops-current" ]] || return 1
	expected=$(<"${hook}.aidevops-current")
	[[ "$expected" == "$fingerprint"$'\n'* ]] || return 1
	grep -qxF "$marker" "$hook" || return 1
	digest=$(guard_rollout_hash "$hook") || return 1
	[[ "$expected" == "$fingerprint"$'\n'"$digest" ]] || return 1
	return 0
}
