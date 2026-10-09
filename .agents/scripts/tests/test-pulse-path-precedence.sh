#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BASH_BIN="$(command -v bash)"

# Every launchd/cron entrypoint bootstraps PATH through runtime-env.sh with the
# daemon profile. Exercise each script's actual bootstrap lines (not a copy)
# without running the script itself.
entrypoints=()
while IFS= read -r entry; do
	entrypoints+=("$entry")
done < <(cd "$SCRIPTS_DIR" && grep -rl --include='*.sh' '^AIDEVOPS_PATH_PROFILE=daemon' . | sort)
[[ "${#entrypoints[@]}" -gt 0 ]] || {
	printf 'FAIL: no daemon PATH bootstrap found\n' >&2
	exit 1
}
grep -rl --include='*.sh' '^_aidevops_path_prefix=' "$SCRIPTS_DIR" && {
	printf 'FAIL: legacy _aidevops_path_prefix block reintroduced\n' >&2
	exit 1
}

for entry in "${entrypoints[@]}"; do
	script="${SCRIPTS_DIR}/${entry#./}"
	block="$(awk '
		/^AIDEVOPS_PATH_PROFILE=daemon/ { capture = 1 }
		capture { print }
		capture && /source "/ { exit }
	' "$script")"
	for initial in configured empty unset; do
		# shellcheck disable=SC2016 # Expand test arguments inside the isolated child shell.
		"$BASH_BIN" -c '
			set -eu
			initial="$1"
			block="$2"
			case "$initial" in
				configured) export PATH="/operator/toolchain:/operator/tools" ;;
				empty) export PATH="" ;;
				unset) unset PATH ;;
			esac
			eval "$block"
			if [[ "$initial" == configured ]]; then
				[[ "$PATH" == /operator/toolchain:/operator/tools:* ]] || exit 1
			fi
			[[ "$PATH" != :* && "$PATH" != *::* && "$PATH" != *: ]] || exit 1
			# Every existing daemon fallback root is present; missing ones are
			# never added. The list comes from runtime-env.sh, not a copy.
			[[ -n "${AIDEVOPS_DAEMON_PATH_FALLBACK:-}" ]] || exit 1
			IFS=: read -r -a fallback_dirs <<<"$AIDEVOPS_DAEMON_PATH_FALLBACK"
			for dir in "${fallback_dirs[@]}"; do
				if [[ -d "$dir" ]]; then
					[[ ":$PATH:" == *":$dir:"* ]] || exit 1
				else
					[[ ":$PATH:" != *":$dir:"* ]] || exit 1
				fi
			done
			# Package-manager roots precede system roots (Homebrew bash 5
			# over /bin/bash 3.2 when launchd starts with an empty PATH).
			if [[ "$initial" != configured && -d /opt/homebrew/bin ]]; then
				[[ "$PATH" == /opt/homebrew/bin:* ]] || exit 1
			fi
		' "$script" "$initial" "$block" || {
			printf 'FAIL: %s initial=%s\n' "${entry#./}" "$initial" >&2
			exit 1
		}
	done
done

printf 'PASS: %s daemon entrypoints keep configured PATH precedence and existing fallbacks\n' "${#entrypoints[@]}"
