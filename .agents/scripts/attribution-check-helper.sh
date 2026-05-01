#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# attribution-check-helper.sh — evidence gate before publishing blame.

set -euo pipefail

_usage() {
	cat <<'EOF'
Usage: attribution-check-helper.sh --file .agents/scripts/name.sh [--symbol function_name] [--claim tNNN]

Compares source/deployed script mtimes and checks cited code presence before
publishing task/PR attribution as a diagnosis.
EOF
	return 0
}

main() {
	local file=""
	local symbol=""
	local claim=""
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		shift
		case "$arg" in
			--file) [[ $# -gt 0 ]] || { printf 'ERROR: --file requires a value\n' >&2; return 2; }; local value="$1"; file="$value"; shift ;;
			--symbol) [[ $# -gt 0 ]] || { printf 'ERROR: --symbol requires a value\n' >&2; return 2; }; local value="$1"; symbol="$value"; shift ;;
			--claim) [[ $# -gt 0 ]] || { printf 'ERROR: --claim requires a value\n' >&2; return 2; }; local value="$1"; claim="$value"; shift ;;
			--help|-h) _usage; return 0 ;;
			*) printf 'ERROR: unknown option: %s\n' "$arg" >&2; return 2 ;;
		esac
	done
	if [[ -z "$file" ]]; then
		_usage >&2
		return 2
	fi
	local source_path="$PWD/$file"
	local deployed_path="$HOME/.aidevops/agents/${file#.agents/}"
	python3 - "$source_path" "$deployed_path" <<'PY'
import os, sys, time
for label, path in [('source', sys.argv[1]), ('deployed', sys.argv[2])]:
    if os.path.exists(path):
        print(f'- {label}: {path} mtime={time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(os.path.getmtime(path)))}')
    else:
        print(f'- {label}: missing ({path})')
PY
	if [[ -n "$claim" ]]; then
		printf '- Claim: %s (hypothesis until code evidence below matches)\n' "$claim"
	fi
	if [[ -n "$symbol" ]]; then
		if rg -n "(^|[[:space:]])${symbol}[[:space:]]*\(" "$source_path" >/dev/null 2>&1; then
			printf '- Symbol check: found %s in source\n' "$symbol"
		else
			printf '- Symbol check: missing %s in source\n' "$symbol"
			printf 'RESULT: hypothesis-only\n'
			return 1
		fi
	fi
	printf 'RESULT: evidence-collected\n'
	return 0
}

main "$@"
