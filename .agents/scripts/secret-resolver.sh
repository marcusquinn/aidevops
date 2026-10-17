#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# =============================================================================
# Shared secret resolver (GH#34892) — sourced by shared-constants.sh.
# =============================================================================
# Lookup order: environment → credentials.sh (sourced in a subshell, so its
# other exports never leak into the caller) → gopass `aidevops/NAME`.
# Environment and plaintext values keep precedence, so current installs see no
# change; names moved to gopass by `aidevops secret import-credentials` keep
# resolving after `aidevops secret prune-plaintext`.
#
# Never prints values except on stdout of aidevops_resolve_secret, and gopass
# stderr is always discarded. Node callers use secret-resolver.mjs.
#
#   value=$(aidevops_resolve_secret NAME)  # value on stdout; 1 when unresolved
#   aidevops_load_secret NAME              # assign shell variable NAME (not exported)
#   aidevops_secret_available NAME         # presence only; gopass is listed, never decrypted
#   value=$(aidevops_gopass_secret NAME)   # gopass only (bounded when non-interactive)

[[ -n "${_AIDEVOPS_SECRET_RESOLVER_LOADED:-}" ]] && return 0
_AIDEVOPS_SECRET_RESOLVER_LOADED=1

_aidevops_secret_name_valid() {
	local name="$1"
	[[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && return 0
	return 1
}

# Value of NAME after sourcing credentials.sh (tenant loaders source the active
# tenant file) in an isolated subshell.
_aidevops_credential_file_value() {
	local name="$1"
	local cred_file="${HOME}/.config/aidevops/credentials.sh"
	[[ -f "$cred_file" ]] || return 1
	local value=""
	value=$(
		set +eu
		# shellcheck source=/dev/null
		source "$cred_file" >/dev/null 2>&1
		printf '%s' "${!name:-}"
	) || value=""
	[[ -n "$value" ]] || return 1
	printf '%s' "$value"
	return 0
}

# Run gopass with stderr discarded. Interactive terminals may answer a pinentry
# prompt; otherwise the call is bounded so headless callers never hang
# (AIDEVOPS_SECRET_RESOLVE_TIMEOUT seconds, default 10). Bounding uses
# shared-constants' timeout_sec, else timeout/gtimeout; with none available
# (standalone sourcing on bare macOS) a non-interactive gopass call is skipped.
_aidevops_gopass_run() {
	local secs="${AIDEVOPS_SECRET_RESOLVE_TIMEOUT:-10}"
	[[ "$secs" =~ ^[1-9][0-9]*$ ]] || secs=10
	if [[ -t 0 && -t 2 ]]; then
		gopass "$@" 2>/dev/null || return 1
	elif declare -F timeout_sec >/dev/null 2>&1; then
		timeout_sec "$secs" gopass "$@" </dev/null 2>/dev/null || return 1
	elif command -v timeout >/dev/null 2>&1; then
		timeout "$secs" gopass "$@" </dev/null 2>/dev/null || return 1
	elif command -v gtimeout >/dev/null 2>&1; then
		gtimeout "$secs" gopass "$@" </dev/null 2>/dev/null || return 1
	else
		return 1
	fi
	return 0
}

# Scalar gopass value for aidevops/NAME.
aidevops_gopass_secret() {
	local name="$1"
	_aidevops_secret_name_valid "$name" || return 1
	command -v gopass >/dev/null 2>&1 || return 1
	local value=""
	value=$(_aidevops_gopass_run show -o "aidevops/${name}") || value=""
	[[ -n "$value" ]] || return 1
	printf '%s' "$value"
	return 0
}

aidevops_resolve_secret() {
	local name="$1"
	_aidevops_secret_name_valid "$name" || return 1
	local value="${!name:-}"
	[[ -n "$value" ]] || value=$(_aidevops_credential_file_value "$name") || value=""
	[[ -n "$value" ]] || value=$(aidevops_gopass_secret "$name") || value=""
	[[ -n "$value" ]] || return 1
	printf '%s' "$value"
	return 0
}

# Set shell variable NAME from the resolver when it is empty. Not exported:
# callers that launch children needing it must export it themselves.
aidevops_load_secret() {
	local name="$1"
	_aidevops_secret_name_valid "$name" || return 1
	[[ -n "${!name:-}" ]] && return 0
	local value=""
	value=$(aidevops_resolve_secret "$name") || return 1
	printf -v "$name" '%s' "$value"
	return 0
}

# Presence check without decrypting: env, credentials.sh, then the gopass
# listing (cached per process).
aidevops_secret_available() {
	local name="$1"
	_aidevops_secret_name_valid "$name" || return 1
	[[ -n "${!name:-}" ]] && return 0
	_aidevops_credential_file_value "$name" >/dev/null && return 0
	command -v gopass >/dev/null 2>&1 || return 1
	if [[ -z "${_AIDEVOPS_GOPASS_LISTING_LOADED:-}" ]]; then
		_AIDEVOPS_GOPASS_LISTING=$(_aidevops_gopass_run ls --flat "aidevops/") || _AIDEVOPS_GOPASS_LISTING=""
		_AIDEVOPS_GOPASS_LISTING_LOADED=1
	fi
	if grep -Fxq -- "aidevops/${name}" <<<"$_AIDEVOPS_GOPASS_LISTING"; then
		return 0
	fi
	return 1
}
