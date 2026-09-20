#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/state"
SYSTEM_PATH="$PATH"
TOOL_TEST_REAL_JQ="$(command -v jq)"

cat >"$TEST_ROOT/bin/gh" <<'SH'
#!/usr/bin/env bash
printf 'gh version 2.100.0\n'
SH
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
if [[ "${1:-}" == "info" && "${2:-}" == "--json=v2" ]]; then
	case "${3:-}" in
	gh) stable=2.101.0 ;;
	jq) stable=1.8.2 ;;
	*) stable=1.0.0 ;;
	esac
	printf '{"formulae":[{"versions":{"stable":"%s"}}]}\n' "$stable"
	exit 0
fi
if [[ "${1:-}" == "upgrade" ]]; then
	printf '%s\n' "${2:-}" >>"$TOOL_TEST_STATE/brew-upgrades"
	exit 0
fi
exit 1
SH
cat >"$TEST_ROOT/bin/sudo" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TOOL_TEST_STATE/sudo-calls"
exit 1
SH
chmod +x "$TEST_ROOT/bin/gh" "$TEST_ROOT/bin/jq" "$TEST_ROOT/bin/brew" "$TEST_ROOT/bin/sudo"

export TOOL_TEST_STATE="$TEST_ROOT/state"
export TOOL_TEST_REAL_JQ
PATH="$TEST_ROOT/bin:$SYSTEM_PATH" \
	bash "$REPO_ROOT/.agents/scripts/tool-version-check.sh" --category brew --update --quiet >/dev/null

grep -qx 'gh' "$TEST_ROOT/state/brew-upgrades"
grep -qx 'jq' "$TEST_ROOT/state/brew-upgrades"
[[ ! -e "$TEST_ROOT/state/sudo-calls" ]]

printf 'PASS: Homebrew stable versions update without dormant sudo fallbacks blocking them\n'
