#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Runtime-bundle PID leases for long-lived Pulse and worker processes.

_AIDEVOPS_RUNTIME_BUNDLE_LEASE_FILE="${_AIDEVOPS_RUNTIME_BUNDLE_LEASE_FILE:-}"

aidevops_runtime_bundle_lease_acquire() {
	local requested_root="${1:-${AIDEVOPS_AGENTS_DIR:-}}"
	local bundles_root="${AIDEVOPS_RUNTIME_BUNDLES_DIR:-${HOME:-}/.aidevops/runtime-bundles}"
	local agents_root=""
	local physical_bundles_root=""
	local bundle_dir=""
	local bundle_id=""
	local lease_dir=""
	local lease_file=""
	local lease_tmp=""

	if [[ -n "$_AIDEVOPS_RUNTIME_BUNDLE_LEASE_FILE" && -f "$_AIDEVOPS_RUNTIME_BUNDLE_LEASE_FILE" ]]; then
		return 0
	fi
	_AIDEVOPS_RUNTIME_BUNDLE_LEASE_FILE=""
	[[ -n "$requested_root" && -d "$requested_root" ]] || return 0
	[[ -n "$bundles_root" && -d "$bundles_root" ]] || return 0
	agents_root=$(cd "$requested_root" && pwd -P) || return 0
	physical_bundles_root=$(cd "$bundles_root" && pwd -P) || return 0
	[[ "${agents_root##*/}" == "agents" ]] || return 0
	bundle_dir="${agents_root%/agents}"
	[[ "$bundle_dir" != "$agents_root" && "${bundle_dir%/*}" == "$physical_bundles_root" ]] || return 0
	bundle_id="${bundle_dir##*/}"
	case "$bundle_id" in
	"" | .*) return 0 ;;
	esac

	lease_dir="${physical_bundles_root}/.leases/${bundle_id}"
	lease_file="${lease_dir}/$$"
	lease_tmp="${lease_dir}/.$$-${RANDOM}.tmp"
	mkdir -p "$lease_dir" || return 1
	: >"$lease_tmp" || return 1
	chmod 600 "$lease_tmp" 2>/dev/null || {
		rm -f "$lease_tmp"
		return 1
	}
	if ! printf '%s\n' "$agents_root" >"$lease_tmp" || ! mv "$lease_tmp" "$lease_file"; then
		rm -f "$lease_tmp"
		return 1
	fi
	_AIDEVOPS_RUNTIME_BUNDLE_LEASE_FILE="$lease_file"
	return 0
}

aidevops_runtime_bundle_lease_release() {
	local lease_file="${_AIDEVOPS_RUNTIME_BUNDLE_LEASE_FILE:-}"
	local lease_dir=""
	local leases_root=""
	[[ -n "$lease_file" ]] || return 0
	_AIDEVOPS_RUNTIME_BUNDLE_LEASE_FILE=""
	if [[ "${lease_file##*/}" != "$$" ]]; then
		return 1
	fi
	lease_dir="${lease_file%/*}"
	leases_root="${lease_dir%/*}"
	rm -f "$lease_file" 2>/dev/null || return 1
	rmdir "$lease_dir" 2>/dev/null || true
	rmdir "$leases_root" 2>/dev/null || true
	return 0
}
