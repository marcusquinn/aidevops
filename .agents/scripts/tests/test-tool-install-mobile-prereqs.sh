#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Regression coverage for opt-in device prerequisites; no packages are installed.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source_file="$repo_root/.agents/scripts/setup/modules/tool-install.sh"
sandbox="$(mktemp -d -t mobile-prereqs-XXXXXX)"
trap 'rm -rf "$sandbox"' EXIT

awk '
    /^setup_android_platform_tools\(\)/, /^}$/ { print; next }
    /^setup_ios_simulator_prerequisites\(\)/, /^}$/ { print; next }
    /^_setup_mobile_mcp_node_version_ok\(\)/, /^}$/ { print; next }
    /^setup_mobile_mcp\(\)/, /^}$/ { print; next }
    /^setup_mobile_simulator_tools\(\)/, /^}$/ { print; next }
' "$source_file" >"$sandbox/functions.sh"

# shellcheck disable=SC1090
source "$sandbox/functions.sh"

print_info() { printf 'INFO: %s\n' "$*"; }
print_success() { printf 'OK: %s\n' "$*"; }
print_warning() { printf 'WARN: %s\n' "$*"; }
print_skip() { printf 'SKIP: %s\n' "$*"; }
setup_prompt() {
	local var_name="$1"
	local prompt_text="$2"
	local default_value="$3"
	: "$prompt_text"
	if [[ "${NON_INTERACTIVE:-false}" == "true" ]]; then
		printf -v "$var_name" '%s' "$default_value"
	else
		printf -v "$var_name" '%s' "${TEST_ANSWER:-N}"
	fi
}
run_with_spinner() {
	local label="$1"
	shift
	: "$label"
	"$@"
}
brew() { printf '%s\n' "$*" >>"$sandbox/installs"; }
uname() { printf '%s\n' "${TEST_OS:-Darwin}"; }
command() {
	if [[ "$1" == "-v" && "$2" == "adb" ]]; then
		declare -F adb >/dev/null || return 1
		printf 'adb\n'
		return 0
	fi
	builtin command "$@"
}
xcrun() { [[ "${SIMCTL_AVAILABLE:-no}" == "yes" ]]; }
node() { printf 'v22.12.0\n'; }
npm() { return 0; }
npm_global_install() { printf 'npm %s\n' "$*" >>"$sandbox/installs"; }

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}
assert_contains() { [[ "$1" == *"$2"* ]] || fail "expected: $2"; }
assert_no_install() { [[ ! -s "$sandbox/installs" ]] || fail 'unexpected package installation'; }

NON_INTERACTIVE=true
output="$(setup_android_platform_tools)"
assert_no_install
[[ -z "$output" ]] || fail 'non-interactive setup must not offer Android installation'

TEST_OS=Linux
output="$(setup_android_platform_tools)"
assert_contains "$output" 'install Android SDK Platform Tools for this OS'
[[ -z "$(setup_ios_simulator_prerequisites)" ]] || fail 'iOS guidance must be macOS-only'
assert_no_install
TEST_OS=Darwin

NON_INTERACTIVE=false
TEST_ANSWER=N
setup_android_platform_tools >/dev/null
assert_no_install

TEST_ANSWER=Y
setup_android_platform_tools >/dev/null
assert_contains "$(<"$sandbox/installs")" 'install --cask android-platform-tools'

: >"$sandbox/installs"
adb() { return 0; }
output="$(setup_android_platform_tools)"
assert_no_install
assert_contains "$output" 'device availability is not yet verified'
unset -f adb

output="$(setup_ios_simulator_prerequisites)"
assert_contains "$output" 'Command Line Tools alone do not include simctl'
assert_contains "$output" 'xcrun simctl list devices available'
SIMCTL_AVAILABLE=yes
output="$(setup_ios_simulator_prerequisites)"
assert_contains "$output" 'a booted simulator is still required'

SIMCTL_AVAILABLE=no
output="$(setup_mobile_mcp)"
assert_contains "$output" 'No Android platform tools or usable iOS simulator SDK'
assert_no_install

mobile_setup_block="$(awk '/^setup_mobile_simulator_tools\(\)/, /^}$/' "$source_file")"
[[ "$mobile_setup_block" == *$'setup_android_platform_tools\n\tsetup_ios_simulator_prerequisites\n\tsetup_minisim\n\tsetup_serve_sim\n\tsetup_mobile_mcp'* ]] || fail 'mobile setup order changed'

printf 'PASS: Mobile prerequisite setup remains opt-in and reports SDK readiness accurately\n'
