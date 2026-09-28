#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Sourceable DataForSEO credential resolver; never print credential values.

dataforseo_load_credentials() {
	local credentials="$HOME/.config/aidevops/credentials.sh"
	local env_login="${DATAFORSEO_USERNAME:-}" env_password="${DATAFORSEO_PASSWORD:-}"
	local api_login="" api_password="" legacy_login="" legacy_password=""
	if [[ ( -z "$env_login" || -z "$env_password" ) && -f "$credentials" ]]; then
		# shellcheck source=/dev/null
		source "$credentials" >/dev/null 2>&1 || true
		[[ -n "$env_login" ]] && DATAFORSEO_USERNAME="$env_login"
		[[ -n "$env_password" ]] && DATAFORSEO_PASSWORD="$env_password"
	fi
	if [[ ( -z "${DATAFORSEO_USERNAME:-}" || -z "${DATAFORSEO_PASSWORD:-}" ) ]] && command -v gopass >/dev/null 2>&1; then
		api_login=$(gopass show -o aidevops/DATAFORSEO_API_LOGIN 2>/dev/null || true)
		api_password=$(gopass show -o aidevops/DATAFORSEO_API_PASSWORD 2>/dev/null || true)
		if [[ -n "$api_login" && -n "$api_password" ]]; then
			DATAFORSEO_USERNAME="${DATAFORSEO_USERNAME:-$api_login}"
			DATAFORSEO_PASSWORD="${DATAFORSEO_PASSWORD:-$api_password}"
		fi
	fi
	if [[ ( -z "${DATAFORSEO_USERNAME:-}" || -z "${DATAFORSEO_PASSWORD:-}" ) ]] && command -v gopass >/dev/null 2>&1; then
		legacy_login=$(gopass show -o aidevops/DATAFORSEO_USERNAME 2>/dev/null || true)
		legacy_password=$(gopass show -o aidevops/DATAFORSEO_PASSWORD 2>/dev/null || true)
		if [[ -n "$legacy_login" && -n "$legacy_password" ]]; then
			DATAFORSEO_USERNAME="${DATAFORSEO_USERNAME:-$legacy_login}"
			DATAFORSEO_PASSWORD="${DATAFORSEO_PASSWORD:-$legacy_password}"
		fi
	fi
	if [[ -n "${DATAFORSEO_USERNAME:-}" && -n "${DATAFORSEO_PASSWORD:-}" ]]; then
		export DATAFORSEO_USERNAME DATAFORSEO_PASSWORD
		return 0
	fi
	return 1
}
