#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tap-qualified Homebrew formulas (owner/tap/formula) must never be resolved or
# updated through apt/dnf/yum on hosts without brew. A same-named distro package
# can be an unrelated tool (apt "bd" is not Beads), which queued an update that
# ran `apt-get install steveyegge/beads/bd` and failed every `aidevops update`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TOOL_VERSION_CHECK="${TOOL_VERSION_CHECK:-$REPO_ROOT/.agents/scripts/tool-version-check.sh}"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/tvc-tap.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

FUNCTION_BODY="$(awk '/^_tool_latest_version\(\) \{/,/^\}/' "$TOOL_VERSION_CHECK")"
[[ -n "$FUNCTION_BODY" ]] || {
	printf 'FAIL: could not extract _tool_latest_version\n' >&2
	exit 1
}

# Lookup stubs; copied into the probe shell with `declare -f`.
get_npm_latest() {
	printf '%s\n' npm
	return 0
}
get_pip_latest() {
	printf '%s\n' pip
	return 0
}
get_apt_candidate() {
	local pkg="$1"
	printf 'apt:%s\n' "$pkg"
	return 0
}
get_brew_latest() {
	local pkg="$1"
	printf 'brew:%s\n' "$pkg"
	return 0
}
STUBS="$(declare -f get_npm_latest get_pip_latest get_apt_candidate get_brew_latest)"

# $1 = PATH for the probe, $2 = formula. Prints the resolved latest version.
resolve_latest() {
	local probe_path="$1"
	local formula="$2"
	env -i PATH="$probe_path" "$BASH" -c \
		"${STUBS}"$'\n'"${FUNCTION_BODY}"$'\n'"_tool_latest_version brew ${formula} x"
	return 0
}

assert_eq() {
	local label="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$actual" != "$expected" ]]; then
		printf 'FAIL: %s: expected "%s", got "%s"\n' "$label" "$expected" "$actual" >&2
		exit 1
	fi
	return 0
}

# Host with apt-get and without brew: PATH contains only an apt-get stub.
mkdir -p "$TEST_ROOT/apt-only" "$TEST_ROOT/with-brew"
printf '#!/usr/bin/env bash\nexit 0\n' >"$TEST_ROOT/apt-only/apt-get"
printf '#!/usr/bin/env bash\nexit 0\n' >"$TEST_ROOT/with-brew/brew"
chmod +x "$TEST_ROOT/apt-only/apt-get" "$TEST_ROOT/with-brew/brew"

assert_eq "tap formula on apt host without brew" "unknown" \
	"$(resolve_latest "$TEST_ROOT/apt-only" steveyegge/beads/bd)"
assert_eq "plain formula on apt host without brew" "apt:jq" \
	"$(resolve_latest "$TEST_ROOT/apt-only" jq)"
assert_eq "tap formula with brew present" "brew:max-sixty/worktrunk/wt" \
	"$(resolve_latest "$TEST_ROOT/with-brew" max-sixty/worktrunk/wt)"

printf 'PASS: tap-qualified formulas are not resolved through apt without brew\n'
exit 0
