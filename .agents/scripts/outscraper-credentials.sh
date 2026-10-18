#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Sourceable launch-time resolver; never print credential values.

outscraper_load_credentials() {
	local credentials="$HOME/.config/aidevops/credentials.sh"
	if [[ -z "${OUTSCRAPER_API_KEY:-}" && -f "$credentials" ]]; then
		# shellcheck source=/dev/null
		source "$credentials" >/dev/null 2>&1 || true
	fi
	if [[ -z "${OUTSCRAPER_API_KEY:-}" ]] && command -v gopass >/dev/null 2>&1; then
		OUTSCRAPER_API_KEY=$(gopass show -o aidevops/OUTSCRAPER_API_KEY 2>/dev/null) || OUTSCRAPER_API_KEY=""
	fi
	if [[ -n "${OUTSCRAPER_API_KEY:-}" ]]; then
		export OUTSCRAPER_API_KEY
		return 0
	fi
	return 1
}
