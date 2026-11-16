#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# GH#38585: opencode-browse-helper.sh must not treat another command named
# `browse` as the OpenCode browse CLI. Debian/Ubuntu xdg-utils installs
# /usr/bin/browse -> xdg-open; with the CLI absent, every helper command used
# to run xdg-open and `installed` exited 0, so setup/update never installed it.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${TEST_DIR}/../opencode-browse-helper.sh"
TEST_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TEST_ROOT"' EXIT

PASS_COUNT=0

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	exit 1
	return 1
}

pass() {
	local message="$1"
	PASS_COUNT=$((PASS_COUNT + 1))
	printf 'PASS: %s\n' "$message"
	return 0
}

# xdg-open stub mirroring xdg-utils argument handling; records any open attempt.
ALIAS_BIN="${TEST_ROOT}/alias-bin"
ALIAS_MARKER="${TEST_ROOT}/xdg-open-invoked"
mkdir -p "$ALIAS_BIN"
cat >"${ALIAS_BIN}/xdg-open" <<STUB
#!/bin/sh
case "\$1" in
--version) echo "xdg-open 1.1.3"; exit 0 ;;
esac
echo "\$*" >>"${ALIAS_MARKER}"
exit 4
STUB
chmod +x "${ALIAS_BIN}/xdg-open"
ln -s xdg-open "${ALIAS_BIN}/browse"

# Fake OpenCode browse CLI: bare semver for --version, like the real CLI.
CLI_BIN="${TEST_ROOT}/cli-bin"
mkdir -p "$CLI_BIN"
cat >"${CLI_BIN}/browse" <<'STUB'
#!/bin/sh
case "$1" in
--version) echo "0.0.17"; exit 0 ;;
esac
echo "fake browse $*"
exit 0
STUB
chmod +x "${CLI_BIN}/browse"

EMPTY_HOME="${TEST_ROOT}/home-empty"
mkdir -p "$EMPTY_HOME"

run_helper() {
	local home_dir="$1"
	local path_prefix="$2"
	shift 2
	if env -u XDG_BIN_HOME HOME="$home_dir" PATH="${path_prefix}:${PATH}" \
		bash "$HELPER" "$@"; then
		return 0
	fi
	return 1
}

# 1. xdg-open alias on PATH, CLI not installed.
if run_helper "$EMPTY_HOME" "$ALIAS_BIN" installed >/dev/null 2>&1; then
	fail "installed exited 0 with only the xdg-utils browse alias on PATH"
fi
pass "installed exits non-zero when PATH browse is the xdg-open alias"

status_output="$(run_helper "$EMPTY_HOME" "$ALIAS_BIN" status 2>&1)" &&
	fail "status exited 0 with only the xdg-utils browse alias on PATH"
[[ "$status_output" == *"browse CLI: not installed"* ]] ||
	fail "status did not report the CLI as not installed: ${status_output}"
pass "status reports the CLI as not installed"

pair_output="$(run_helper "$EMPTY_HOME" "$ALIAS_BIN" pair --list 2>&1)" &&
	fail "pair --list exited 0 with only the xdg-utils browse alias on PATH"
[[ "$pair_output" == *"browse CLI is not installed"* ]] ||
	fail "pair --list did not print the not-installed guidance: ${pair_output}"
pass "pair --list prints the not-installed guidance"

[[ ! -e "$ALIAS_MARKER" ]] ||
	fail "xdg-open alias was invoked with: $(cat "$ALIAS_MARKER")"
pass "xdg-open alias is never invoked with helper arguments"

# 2. Real CLI reachable only via PATH (e.g. an npm install) is still accepted.
run_helper "$EMPTY_HOME" "$CLI_BIN" installed >/dev/null 2>&1 ||
	fail "installed rejected a PATH browse that reports a bare semver"
pass "installed accepts the browse CLI found on PATH"

# 3. Installer location wins over a PATH alias and is not probed.
INSTALLED_HOME="${TEST_ROOT}/home-installed"
mkdir -p "${INSTALLED_HOME}/.local/bin"
printf '#!/bin/sh\nexit 0\n' >"${INSTALLED_HOME}/.local/bin/browse"
chmod +x "${INSTALLED_HOME}/.local/bin/browse"
run_helper "$INSTALLED_HOME" "$ALIAS_BIN" installed >/dev/null 2>&1 ||
	fail "installed rejected the installer-location browse"
pass "installer-location browse is preferred over the PATH alias"

printf 'All %d opencode-browse-helper checks passed\n' "$PASS_COUNT"
exit 0
