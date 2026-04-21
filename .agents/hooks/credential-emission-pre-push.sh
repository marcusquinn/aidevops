#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# credential-emission-pre-push.sh — git pre-push hook (t2458)
#
# Blocks a push if the commit range introduces shell emits (echo / printf /
# log_*) of `$remote_url` or `$origin_url` WITHOUT wrapping them in
# `sanitize_url` or `scrub_credentials` from shared-constants.sh.
#
# Why: `git remote get-url origin` returns the URL verbatim. If the user (or
# a cloner script, or a stale credential helper) wrote the remote with an
# embedded token (`https://<token>@github.com/...`), any raw echo of that
# value leaks the token into stdout — where it reaches the user's terminal,
# any session transcript, and potentially upstream model providers.
#
# Detection scope:
#   .agents/scripts/**/*.sh (excluding tests/ and fixtures/)
#   .agents/hooks/**/*.sh
#
# Heuristic (regex, line-level):
#   - Line contains  (echo|printf|log_[a-z]+)
#   - Line references  \$\{?remote_url\}?  or  \$\{?origin_url\}?
#   - Line does NOT contain  sanitize_url  or  scrub_credentials
#
# Bypass:  CREDENTIAL_GUARD_DISABLE=1 git push ...
#          git push --no-verify
# Debug:   CREDENTIAL_GUARD_DEBUG=1 git push ...
#
# Git pre-push protocol:
#   $1 = remote name
#   $2 = remote URL
#   stdin: one line per ref: <local_ref> <local_sha> <remote_ref> <remote_sha>

set -euo pipefail

if [[ "${CREDENTIAL_GUARD_DISABLE:-0}" == "1" ]]; then
	printf '[credential-guard][INFO] CREDENTIAL_GUARD_DISABLE=1 — bypassing\n' >&2
	exit 0
fi

_cg_debug() {
	[[ "${CREDENTIAL_GUARD_DEBUG:-0}" == "1" ]] && printf '[credential-guard][DEBUG] %s\n' "$*" >&2
	return 0
}

# Scan a diff range for credential-emission violations.
# Arguments:
#   $1 — base ref
#   $2 — head ref
# Emits violations to stdout as "file:line:content" (one per line).
# Returns 0 if clean, 1 if any violations.
_cg_scan_range() {
	local base="$1"
	local head="$2"
	local diff_output
	local violations=0

	# Unified diff with context=0, restricted to .sh files under scripts/hooks.
	# `git diff --no-color` ensures no ANSI escape codes contaminate the scan.
	# `:(glob)` pathspec magic enables `**` recursive matching (disabled by default).
	diff_output=$(git diff --no-color -U0 "${base}..${head}" -- \
		':(glob).agents/scripts/**/*.sh' \
		':(glob).agents/hooks/**/*.sh' 2>/dev/null || true)

	if [[ -z "$diff_output" ]]; then
		_cg_debug "no .sh changes in .agents/{scripts,hooks} — nothing to scan"
		return 0
	fi

	local current_file=""
	local current_line=0
	local line

	while IFS= read -r line; do
		# Track current file being diffed.
		if [[ "$line" =~ ^\+\+\+[[:space:]]b/(.*)$ ]]; then
			current_file="${BASH_REMATCH[1]}"
			_cg_debug "scanning file: $current_file"
			continue
		fi

		# Skip tests/ and fixtures/ — they may deliberately include emit patterns
		# to verify the sanitizer catches them.
		case "$current_file" in
		.agents/scripts/tests/* | .agents/scripts/fixtures/*) continue ;;
		esac

		# Track line numbers via hunk headers: @@ -a,b +c,d @@
		if [[ "$line" =~ ^@@[[:space:]]-[0-9]+(,[0-9]+)?[[:space:]]\+([0-9]+) ]]; then
			current_line=$((${BASH_REMATCH[2]} - 1))
			continue
		fi

		# Only inspect added lines (start with +, but not +++).
		if [[ "$line" =~ ^\+[^+] ]]; then
			current_line=$((current_line + 1))
			local content="${line:1}"

			# Emit pattern: echo / printf / log_<name>
			if [[ "$content" =~ (^|[^a-zA-Z_])(echo|printf|log_[a-zA-Z_]+) ]]; then
				# References $remote_url or $origin_url (bare or braced)
				if [[ "$content" =~ \$\{?(remote_url|origin_url)\}? ]]; then
					# Safe if wrapped by a sanitizer on the same line.
					if [[ "$content" != *sanitize_url* ]] && [[ "$content" != *scrub_credentials* ]]; then
						printf '%s:%d:%s\n' "$current_file" "$current_line" "$content"
						violations=$((violations + 1))
					fi
				fi
			fi
		elif [[ "$line" =~ ^[[:space:]] ]]; then
			# Context line (unchanged) — advance line counter.
			current_line=$((current_line + 1))
		fi
	done <<<"$diff_output"

	return "$((violations > 0 ? 1 : 0))"
}

# Walk each ref in the push
exit_code=0
while IFS=' ' read -r _local_ref local_sha _remote_ref remote_sha; do
	[[ -z "${local_sha:-}" ]] && continue
	# Branch deletion (all zeros)
	if [[ "$local_sha" =~ ^0+$ ]]; then
		continue
	fi

	# For new branches, use the merge-base with main/master as the base.
	base_ref="$remote_sha"
	if [[ "$remote_sha" =~ ^0+$ ]]; then
		base_ref=$(git merge-base HEAD main 2>/dev/null \
			|| git merge-base HEAD master 2>/dev/null \
			|| echo "")
		if [[ -z "$base_ref" ]]; then
			_cg_debug "cannot determine base for new branch — skipping"
			continue
		fi
	fi

	_cg_debug "scanning ${base_ref}..${local_sha}"

	findings=$(_cg_scan_range "$base_ref" "$local_sha" || true)
	if [[ -n "$findings" ]]; then
		# shellcheck disable=SC2016  # The $remote_url/$origin_url strings here are intentional literal examples.
		printf '\n[credential-guard][BLOCK] Push contains unsanitized emits of $remote_url / $origin_url.\n' >&2
		printf '  These may leak embedded credentials from git remote URLs.\n\n' >&2
		printf '  Offending lines:\n' >&2
		while IFS= read -r f; do
			printf '    %s\n' "$f" >&2
		done <<<"$findings"
		printf '\n  Fix: wrap the variable in sanitize_url or scrub_credentials.\n' >&2
		# shellcheck disable=SC2016  # Example code snippet — variables should not expand.
		printf '    echo "Remote: $(sanitize_url "$remote_url")"\n' >&2
		printf '\n  Both helpers live in shared-constants.sh (source it if not already).\n' >&2
		printf '\n  Bypass: CREDENTIAL_GUARD_DISABLE=1 git push ... or git push --no-verify\n\n' >&2
		exit_code=1
	fi
done

exit "$exit_code"
