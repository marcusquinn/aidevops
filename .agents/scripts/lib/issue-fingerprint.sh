#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# aidevops Issue Fingerprint Library
# =============================================================================
# Shared fingerprint algorithm for deduplication of near-identical issues.
# Consumed by:
#   - log-issue-helper.sh  (client-side dedup via local state file)
#   - issue-sync-reusable.yml  (server-side dedup via GitHub Actions)
#
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/lib/issue-fingerprint.sh"
#        fingerprint=$(_compute_issue_fingerprint "$title" "$body")
#
# Env vars honoured (by callers, not this lib directly):
#   LOG_ISSUE_DEDUP_WINDOW_SECONDS      — client-side window (default 120)
#   ISSUE_SYNC_DEDUP_WINDOW_SECONDS     — server-side window (default 120)

# _normalize_body_for_fingerprint <body>
# Strips aidevops sig footer, source-context trailers, trailing blank lines,
# and standalone "---" separator lines so that two issues differing only in
# token-count or timing metadata in the footer are treated as identical.
#
# This is the canonical normalisation algorithm; any change here affects BOTH
# the client-side (log-issue-helper.sh) and server-side (workflow) dedup.
_normalize_body_for_fingerprint() {
	local body="$1"
	# Strip aidevops sig footer (everything from <!-- aidevops:sig --> to end)
	body=$(printf '%s' "$body" | awk '/<!-- aidevops:sig -->/{exit} {print}')
	# Strip "*Detected by ... in `...`.*" source-context trailer lines
	# shellcheck disable=SC2016
	body=$(printf '%s' "$body" | sed '/^\*Detected by .*\*[[:space:]]*$/d')
	# Strip trailing blank lines and standalone "---" separator lines
	body=$(printf '%s' "$body" | awk '
		{lines[NR]=$0}
		END {
			n=NR
			while (n>0 && (lines[n]=="" || lines[n]=="---")) n--
			for (i=1; i<=n; i++) print lines[i]
		}
	')
	printf '%s' "$body"
	return 0
}

# _compute_issue_fingerprint <title> <body>
# Prints the SHA-256 hex digest of "<title>|<normalized_body>".
# Falls back to openssl dgst then cksum when sha256 is unavailable.
# The pipe separator ensures a title change always produces a different hash.
_compute_issue_fingerprint() {
	local title="$1"
	local body="$2"
	local normalized_body
	normalized_body=$(_normalize_body_for_fingerprint "$body")
	local input="${title}|${normalized_body}"
	local hash=""

	if command -v shasum &>/dev/null; then
		hash=$(printf '%s' "$input" | shasum -a 256 | awk '{print $1}')
	elif command -v sha256sum &>/dev/null; then
		hash=$(printf '%s' "$input" | sha256sum | awk '{print $1}')
	elif command -v openssl &>/dev/null; then
		hash=$(printf '%s' "$input" | openssl dgst -sha256 | awk '{print $NF}')
	else
		# Fallback: cksum — not cryptographic but sufficient for dedup within a session
		hash=$(printf '%s' "$input" | cksum | awk '{print $1}')
	fi

	echo "$hash"
	return 0
}
