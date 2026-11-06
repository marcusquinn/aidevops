#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# gsc-auth-lib.sh -- Google Search Console Application Default Credentials
# =============================================================================
# Shared by seo-export-gsc.sh and keyword-research-helper-webmaster.sh so both
# GSC paths resolve the same credential file and request the same scoped token
# (GH#36898). Callers check GSC_ACCESS_TOKEN first; this library covers ADC:
#
#   1. GOOGLE_APPLICATION_CREDENTIALS (authoritative when set)
#   2. ~/.config/aidevops/gsc-credentials.json
#   3. gcloud default ADC: ${CLOUDSDK_CONFIG:-~/.config/gcloud}/application_default_credentials.json
#      written by `gcloud auth application-default login`, including keyless
#      `--impersonate-service-account=<sa>` setups
#
# Tokens always request the Search Console read-only scope; Search Console
# rejects unscoped service-account ADC tokens (GH#32843). Functions print
# results only and never log credentials; callers own error messages.
#
# Usage: source "${SCRIPT_DIR}/gsc-auth-lib.sh"
# =============================================================================

# Include guard
[[ -n "${_GSC_AUTH_LIB_LOADED:-}" ]] && return 0
_GSC_AUTH_LIB_LOADED=1

GSC_ADC_SCOPE="https://www.googleapis.com/auth/webmasters.readonly"

# Print the ADC file to use, or nothing when none is configured.
gsc_adc_credential_file() {
	local _aidevops_file="$HOME/.config/aidevops/gsc-credentials.json"
	local _gcloud_file="${CLOUDSDK_CONFIG:-$HOME/.config/gcloud}/application_default_credentials.json"
	if [[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]]; then
		printf '%s\n' "$GOOGLE_APPLICATION_CREDENTIALS"
	elif [[ -f "$_aidevops_file" ]]; then
		printf '%s\n' "$_aidevops_file"
	elif [[ -f "$_gcloud_file" ]]; then
		printf '%s\n' "$_gcloud_file"
	fi
	return 0
}

# gsc_adc_access_token <credential-file>
# Print a Search Console-scoped access token; return 1 when gcloud cannot
# produce one (missing file, missing gcloud, or a refresh/reauth failure).
gsc_adc_access_token() {
	local _cred_file="$1"
	local _token=""
	[[ -n "$_cred_file" && -f "$_cred_file" ]] || return 1
	_token=$(GOOGLE_APPLICATION_CREDENTIALS="$_cred_file" \
		gcloud auth application-default print-access-token --scopes="$GSC_ADC_SCOPE" 2>/dev/null) || _token=""
	[[ -n "$_token" ]] || return 1
	printf '%s\n' "$_token"
	return 0
}
