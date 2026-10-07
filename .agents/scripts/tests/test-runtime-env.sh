#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Exercise missing FHS tools and shim-first PATH without modifying host profiles.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../runtime-env.sh
source "${SCRIPT_DIR}/runtime-env.sh"
native_git="$AIDEVOPS_REAL_GIT_BIN"
original_path="$PATH"
temp_root="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
[[ -d "$temp_root" ]]
workspace=$(mktemp -d "${temp_root}/runtime-env.XXXXXX")
trap 'PATH="$original_path"; rm -rf "$workspace"' EXIT
mkdir -p "$workspace/home/.nix-profile/bin" "$workspace/home/.local/state/nix/profile/bin" "$workspace/shims"
ln -s "$SCRIPT_DIR/git" "$workspace/shims/git"
ln -s "$native_git" "$workspace/home/.nix-profile/bin/git"
ln -s "$(command -v readlink)" "$workspace/home/.nix-profile/bin/readlink"
ln -s "$(command -v node)" "$workspace/home/.local/state/nix/profile/bin/node"
HOME="$workspace/home"
# Deliberately simulate a daemon with no inherited system tools.
# shellcheck disable=SC2123
PATH="$workspace/shims"
unset AIDEVOPS_REAL_GIT_BIN
# shellcheck source=../runtime-env.sh
source "${SCRIPT_DIR}/runtime-env.sh"
[[ "${PATH%%:*}" == "$workspace/shims" ]]
[[ "$AIDEVOPS_REAL_GIT_BIN" == "$HOME/.nix-profile/bin/git" ]]
[[ "$(command -v git)" == "$workspace/shims/git" ]]
[[ "$(command -v node)" == "$HOME/.local/state/nix/profile/bin/node" ]]
[[ "$(aidevops_runtime_path "$PATH")" == "$PATH" ]]
AIDEVOPS_REAL_GIT_BIN="$native_git"
[[ "$(aidevops_resolve_native_git)" == "$native_git" ]]
printf 'PASS: minimal PATH finds Nix profile tools, skips Git shims, preserves guards and explicit overrides\n'
