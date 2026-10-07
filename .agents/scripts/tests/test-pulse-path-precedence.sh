#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="${SCRIPT_DIR}/../pulse-wrapper.sh"
BASH_BIN="$(command -v bash)"

# Exercise the actual bootstrap block without starting Pulse or contacting GitHub.
PATH_BLOCK="$(awk '
 /^_aidevops_path_prefix=/ { capture = 1 }
 capture { print }
 /^unset _aidevops_path_prefix$/ { exit }
' "$WRAPPER")"
[[ -n "$PATH_BLOCK" ]] || {
	printf 'FAIL: PATH bootstrap block missing\n' >&2
	exit 1
}

for platform in Darwin Linux; do
	for initial in configured empty unset; do
		# shellcheck disable=SC2016 # Expand test arguments inside the isolated child shell.
		"$BASH_BIN" -c '
			set -eu
			platform="$1"
			initial="$2"
			block="$3"
			uname() {
				printf "%s\n" "$platform"
				return 0
			}
			case "$initial" in
				configured) export PATH="/operator/toolchain:/operator/tools" ;;
				empty) export PATH="" ;;
				unset) unset PATH ;;
			esac
			eval "$block"
			if [[ "$initial" == configured ]]; then
				[[ "$PATH" == /operator/toolchain:/operator/tools:* ]] || exit 1
			else
				[[ "$PATH" != :* ]] || exit 1
			fi
			[[ ":$PATH:" == *:/opt/homebrew/bin:* ]] || exit 1
			[[ ":$PATH:" == *:/usr/local/bin:* ]] || exit 1
			[[ ":$PATH:" == *:/usr/bin:* ]] || exit 1
			[[ ":$PATH:" == *:/bin:* ]] || exit 1
			[[ "$PATH" != *::* && "$PATH" != *: ]] || exit 1
		' pulse-path-test "$platform" "$initial" "$PATH_BLOCK" || {
			printf 'FAIL: platform=%s initial=%s\n' "$platform" "$initial" >&2
			exit 1
		}
	done
done

printf 'PASS: configured PATH precedence and empty/unset fallbacks on Darwin and Linux\n'
