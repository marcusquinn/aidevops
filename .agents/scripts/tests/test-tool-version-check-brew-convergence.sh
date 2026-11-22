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
if [[ -e "$TOOL_TEST_STATE/gh-updated" ]]; then
	printf 'gh version 2.101.0\n'
else
	printf 'gh version 2.100.0\n'
fi
SH
cat >"$TEST_ROOT/bin/jq" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
	if [[ -e "$TOOL_TEST_STATE/jq-updated" ]]; then
		printf 'jq-1.8.2\n'
	else
		printf 'jq-1.7.1\n'
	fi
	exit 0
fi
exec "$TOOL_TEST_REAL_JQ" "$@"
SH
# Shadow every other brew CLI, including the dynamically selected owner probes,
# so host-installed tools cannot introduce extra updates into this test.
for cli in glab wt rg shellcheck opencode claude; do
	cat >"$TEST_ROOT/bin/$cli" <<'SH'
#!/usr/bin/env bash
printf '1.0.0\n'
SH
	chmod +x "$TEST_ROOT/bin/$cli"
done
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
if [[ "${1:-}" == "list" && "${2:-}" == "--formula" ]]; then
	[[ "${3:-}" == "gh" ]]
	exit $?
fi
if [[ "${1:-}" == "upgrade" ]]; then
	printf '%s\n' "${2:-}" >>"$TOOL_TEST_STATE/brew-upgrades"
	[[ "${2:-}" != "gh" ]] || touch "$TOOL_TEST_STATE/gh-updated"
	exit 0
fi
if [[ "${1:-}" == "install" ]]; then
	printf '%s\n' "${2:-}" >>"$TOOL_TEST_STATE/brew-installs"
	[[ "${2:-}" != "jq" ]] || touch "$TOOL_TEST_STATE/jq-updated"
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
if ! output=$(PATH="$TEST_ROOT/bin:$SYSTEM_PATH" \
	bash "$REPO_ROOT/.agents/scripts/tool-version-check.sh" --category brew --update --quiet 2>&1); then
	printf '%s\n' "$output" >&2
	exit 1
fi

grep -qx 'gh' "$TEST_ROOT/state/brew-upgrades"
grep -qx 'jq' "$TEST_ROOT/state/brew-installs"
[[ ! -e "$TEST_ROOT/state/brew-upgrades" ]] || ! grep -qx 'jq' "$TEST_ROOT/state/brew-upgrades"
[[ ! -e "$TEST_ROOT/state/sudo-calls" ]]

printf 'PASS: Homebrew updates installed formulas and installs absent selected formulas\n'
