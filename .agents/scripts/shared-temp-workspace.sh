#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# Route framework-owned temporary files away from the host-wide temporary
# directory. Call this only at managed session/runtime entry points.
aidevops_init_temp_workspace() {
	local workspace_root="${AIDEVOPS_WORKSPACE_DIR:-${HOME:?}/.aidevops/.agent-workspace}"
	local temp_root="${workspace_root}/tmp"

	mkdir -p "$temp_root" || return 1
	chmod 700 "$temp_root" 2>/dev/null || true
	temp_root=$(cd "$temp_root" && pwd -P) || return 1

	export TMPDIR="$temp_root"
	export TMP="$temp_root"
	export TEMP="$temp_root"
	export AIDEVOPS_TEMP_DIR="$temp_root"
	return 0
}
