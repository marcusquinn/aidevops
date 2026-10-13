#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Platform-specific process observation policy, not deletion authority.
# Unknown platforms retain the existing behavior. Never execute os-release.

worktree_process_platform() {
	local kernel="${1:-$(uname -s)}"
	local release_file="${2:-/etc/os-release}"
	local key=""
	local value=""

	if [[ "$kernel" == Linux && -r "$release_file" ]]; then
		while IFS='=' read -r key value; do
			[[ "$key" == ID ]] || continue
			case "$value" in
			nixos | '"nixos"' | "'nixos'")
				printf '%s\n' nixos
				return 0
				;;
			esac
			break
		done <"$release_file"
	fi
	printf '%s\n' "$kernel"
	return 0
}

worktree_process_inspector_allowed() {
	local platform="${1:-$(worktree_process_platform)}"
	# The NixOS adapter stays unprivileged. A denied read remains unknown;
	# existing recoverable cleanup must still prove every candidate predicate.
	[[ "$platform" == nixos ]] && return 1
	return 0
}
