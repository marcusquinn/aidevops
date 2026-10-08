#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Portable tool resolution: PATH only, inherited entries before system
# fallbacks, Git shims skipped, no distro-specific roots injected.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../runtime-env.sh
source "${SCRIPT_DIR}/runtime-env.sh"
native_git="$AIDEVOPS_REAL_GIT_BIN"
original_path="$PATH"
temp_root="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
mkdir -p "$temp_root"
workspace=$(mktemp -d "${temp_root}/runtime-env.XXXXXX")
trap 'PATH="$original_path"; rm -rf "$workspace"' EXIT

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	exit 1
	return 1
}

# 1. PATH builder: inherited order kept, system roots only appended, de-duplicated.
toolchain="$workspace/toolchain/bin"
mkdir -p "$toolchain"
built=$(aidevops_runtime_path "${toolchain}:/usr/bin:${toolchain}::relative")
[[ "${built%%:*}" == "$toolchain" ]] || fail "inherited entry no longer leads: $built"
[[ ":${built}:" != *":relative:"* && "$built" != *::* ]] || fail "unsafe entry kept: $built"
count=$(printf '%s' "$built" | tr ':' '\n' | grep -Fxc "$toolchain" || true)
[[ "$count" -eq 1 ]] || fail "duplicate entries kept: $built"
before_usr=${built%%:/usr/bin*}
[[ "$before_usr" == "$toolchain" ]] || fail "system root shadows inherited PATH: $built"
composed=$(aidevops_compose_path "$toolchain" "/usr/bin:${toolchain}" "/usr/local/bin:/usr/bin")
[[ "$composed" == "${toolchain}:/usr/bin"* ]] || fail "compose order wrong: $composed"
[[ "$(aidevops_runtime_path "$built")" == "$built" ]] || fail "runtime path not idempotent"

# 2. Git only in a non-FHS directory, behind the aidevops shim, minimal PATH.
mkdir -p "$workspace/home/profile/bin" "$workspace/home/unlisted/bin" "$workspace/shims"
ln -s "$SCRIPT_DIR/git" "$workspace/shims/git"
ln -s "$native_git" "$workspace/home/profile/bin/git"
ln -s "$(command -v readlink)" "$workspace/home/profile/bin/readlink"
ln -s "$(command -v node)" "$workspace/home/unlisted/bin/node"
HOME="$workspace/home"
# shellcheck disable=SC2123 # Deliberately simulate a daemon without FHS tools.
PATH="$workspace/shims:$workspace/home/profile/bin"
unset AIDEVOPS_REAL_GIT_BIN
# shellcheck source=../runtime-env.sh
source "${SCRIPT_DIR}/runtime-env.sh"
[[ "${PATH%%:*}" == "$workspace/shims" ]] || fail "shim dir lost precedence"
[[ "$AIDEVOPS_REAL_GIT_BIN" == "$HOME/profile/bin/git" ]] || fail "real git not resolved from PATH: $AIDEVOPS_REAL_GIT_BIN"
[[ "$(command -v git)" == "$workspace/shims/git" ]] || fail "shim no longer first"
[[ ":${PATH}:" != *":$HOME/unlisted/bin:"* ]] || fail "directory not on PATH was injected"
for root in /nix /run/current-system /etc/profiles /run/wrappers; do
	[[ ":${PATH}:" != *":${root}"* ]] || fail "distro-specific root injected: $root"
done

# 3. Trusted lookup skips caller-writable entries (even symlinks to real tools).
system_git_dir=""
while IFS= read -r candidate; do
	[[ "$candidate" == "$workspace"/* ]] && continue
	[[ ! -w "$candidate" && ! -w "${candidate%/*}" ]] && system_git_dir="${candidate%/*}" && break
done < <(PATH="$original_path" type -a -p git)
if [[ -n "$system_git_dir" ]]; then
	trusted=$(aidevops_resolve_trusted_tool git "$HOME/profile/bin:$system_git_dir") ||
		fail "trusted git not found"
	[[ "$trusted" == "$system_git_dir/git" ]] || fail "trusted lookup accepted caller-writable git: $trusted"
	if aidevops_resolve_trusted_tool git "$HOME/profile/bin" >/dev/null; then
		fail "trusted lookup accepted git from caller-writable dir"
	fi
fi

# 4. Explicit operator override still wins.
AIDEVOPS_REAL_GIT_BIN="$native_git"
[[ "$(aidevops_resolve_native_git)" == "$native_git" ]] || fail "override ignored"
printf 'PASS: PATH-only resolution, inherited-before-system order, shim skip, trusted lookup, override\n'
