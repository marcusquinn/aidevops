#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# Secure DSPy's diskcache-backed cache against writes by other local users.
# CVE-2025-69872 can execute a pickled cache value when an attacker can replace
# cache content before DSPy reads it.

aidevops_secure_dspy_cache() {
	local cache_root="${AIDEVOPS_CACHE_DIR:-$HOME/.aidevops/cache}"
	local cache_dir="${DSPY_CACHEDIR:-${cache_root}/dspy}"
	local previous_umask

	if [[ "$cache_dir" != /* ]]; then
		printf '[ERROR] DSPY_CACHEDIR must be an absolute path: %s\n' "$cache_dir" >&2
		return 1
	fi
	if [[ -L "$cache_dir" ]]; then
		printf '[ERROR] Refusing symlinked DSPy cache directory: %s\n' "$cache_dir" >&2
		return 1
	fi

	previous_umask=$(umask)
	umask 077
	if ! mkdir -p -- "$cache_dir"; then
		umask "$previous_umask"
		printf '[ERROR] Unable to create DSPy cache directory: %s\n' "$cache_dir" >&2
		return 1
	fi
	umask "$previous_umask"

	if [[ -L "$cache_dir" || ! -d "$cache_dir" || ! -O "$cache_dir" ]]; then
		printf '[ERROR] DSPy cache must be an owner-controlled directory: %s\n' "$cache_dir" >&2
		return 1
	fi
	if ! chmod 700 "$cache_dir"; then
		printf '[ERROR] Unable to restrict DSPy cache permissions: %s\n' "$cache_dir" >&2
		return 1
	fi

	export DSPY_CACHEDIR="$cache_dir"
	return 0
}

aidevops_persist_dspy_cache_env() {
	local activate_file="$1"
	local marker="# aidevops:dspy-cache-security"

	if [[ ! -f "$activate_file" ]]; then
		printf '[ERROR] DSPy virtualenv activation script not found: %s\n' "$activate_file" >&2
		return 1
	fi
	if grep -Fq "$marker" "$activate_file"; then
		return 0
	fi

	if ! cat >>"$activate_file" <<'EOF'; then

# aidevops:dspy-cache-security
# Keep DSPy's pickle-backed cache in the owner-only directory prepared by setup.
export DSPY_CACHEDIR="${AIDEVOPS_CACHE_DIR:-$HOME/.aidevops/cache}/dspy"
EOF
		printf '[ERROR] Unable to persist the secure DSPy cache environment\n' >&2
		return 1
	fi
	return 0
}
