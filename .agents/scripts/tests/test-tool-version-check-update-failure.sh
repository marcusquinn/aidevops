#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/bin"
SYSTEM_PATH="$PATH"
TOOL_TEST_REAL_JQ="$(command -v jq)"

cat >"$TEST_ROOT/bin/jq" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
	printf 'jq-1.7.1\n'
	exit 0
fi
exec "$TOOL_TEST_REAL_JQ" "$@"
SH
cat >"$TEST_ROOT/bin/brew" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
info)
	if [[ "${3:-}" == "jq" ]]; then
		printf '%s\n' '{"formulae":[{"versions":{"stable":"1.8.2"}}]}'
	else
		printf '%s\n' '{"formulae":[]}'
	fi
	;;
list) exit 1 ;;
install) printf '%s\n' 'simulated install failure' >&2; exit 1 ;;
*) exit 1 ;;
esac
SH
chmod +x "$TEST_ROOT/bin/jq" "$TEST_ROOT/bin/brew"

set +e
output=$(TOOL_TEST_REAL_JQ="$TOOL_TEST_REAL_JQ" PATH="$TEST_ROOT/bin:$SYSTEM_PATH" \
	bash "$REPO_ROOT/.agents/scripts/tool-version-check.sh" --category brew --update --quiet 2>&1)
status=$?
set -e

[[ "$status" -ne 0 ]]
grep -q 'Tool maintenance failed: 1 action' <<<"$output"

printf 'PASS: failed Homebrew actions produce a non-success maintenance summary\n'
