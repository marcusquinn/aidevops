#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression tests for platform-aware headless OpenCode fallback candidates.

set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_REPO_ROOT="$(cd "$TEST_SCRIPTS_DIR/../.." && pwd)"
TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1" rc="$2" extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%sFAIL%s %s %s\n' "$TEST_RED" "$TEST_RESET" "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

run_candidate_list_for_platform() {
	local platform="$1"
	local profile="${2:-v1}"
	(
		export AIDEVOPS_TEST_UNAME_S="$platform"
		export AIDEVOPS_OPENCODE_PROFILE="$profile"
		# shellcheck disable=SC1091
		source "$TEST_REPO_ROOT/.agents/scripts/headless-runtime-lib.sh"
		_opencode_fixed_candidate_paths
	)
	return 0
}

run_warning_dirs_for_platform() {
	local platform="$1"
	(
		export AIDEVOPS_TEST_UNAME_S="$platform"
		# shellcheck disable=SC1091
		source "$TEST_REPO_ROOT/.agents/scripts/headless-runtime-lib.sh"
		_opencode_fixed_candidate_dirs_for_warning
	)
	return 0
}

write_version_binary() {
	local path="$1"
	local output="$2"
	mkdir -p "$(dirname "$path")"
	printf '#!/usr/bin/env bash\nprintf '\''%%s\\n'\'' '\''%s'\''\n' "$output" >"$path"
	chmod +x "$path"
	return 0
}

resolve_fixture_binary() {
	local fixture_root="$1"
	local expected_version="$2"
	local fixture_path="${3:-$PATH}"
	(
		export AIDEVOPS_TEST_UNAME_M="x86_64"
		export AIDEVOPS_OPENCODE_PROFILE="v1"
		export PATH="$fixture_path"
		# shellcheck disable=SC1091
		source "$TEST_REPO_ROOT/.agents/scripts/headless-runtime-lib.sh"
		_resolve_headless_opencode_install_binary "$fixture_root" "$expected_version"
	)
}

# Darwin must not include Linux-only Snap paths.
darwin_candidates=$(run_candidate_list_for_platform "Darwin")
if [[ "$darwin_candidates" != *"/snap/bin/opencode"* ]]; then
	print_result "Darwin candidate list excludes /snap/bin/opencode" 0
else
	print_result "Darwin candidate list excludes /snap/bin/opencode" 1 "$darwin_candidates"
fi

darwin_warning=$(run_warning_dirs_for_platform "Darwin")
if [[ "$darwin_warning" != *"/snap/bin"* ]]; then
	print_result "Darwin warning text excludes /snap/bin" 0
else
	print_result "Darwin warning text excludes /snap/bin" 1 "$darwin_warning"
fi

# Linux keeps Snap-installed OpenCode discoverable.
linux_candidates=$(run_candidate_list_for_platform "Linux")
if [[ "$linux_candidates" == *"/snap/bin/opencode"* ]]; then
	print_result "Linux candidate list includes /snap/bin/opencode" 0
else
	print_result "Linux candidate list includes /snap/bin/opencode" 1 "$linux_candidates"
fi

linux_warning=$(run_warning_dirs_for_platform "Linux")
if [[ "$linux_warning" == *"/snap/bin"* ]]; then
	print_result "Linux warning text includes /snap/bin" 0
else
	print_result "Linux warning text includes /snap/bin" 1 "$linux_warning"
fi

v2_linux_candidates=$(run_candidate_list_for_platform "Linux" "v2")
if [[ "$v2_linux_candidates" == *"/snap/bin/opencode2"* ]] && \
	[[ "$v2_linux_candidates" == *"/.local/bin/opencode2"* ]] && \
	[[ "$v2_linux_candidates" != *"/snap/bin/opencode"$'\n'* ]] && \
	[[ "$v2_linux_candidates" != *"/.local/bin/opencode"$'\n'* ]]; then
	print_result "V2 candidate list selects opencode2" 0
else
	print_result "V2 candidate list selects opencode2" 1 "$v2_linux_candidates"
fi

fixture_root=$(mktemp -d "${TMPDIR:-/tmp}/opencode-candidates.XXXXXX")
trap 'rm -rf "$fixture_root"' EXIT INT TERM
write_version_binary "$fixture_root/node_modules/.bin/opencode" "Error: opencode-ai's postinstall script was not run."
write_version_binary "$fixture_root/node_modules/opencode-linux-x64/bin/opencode" "1.18.29"
resolved_fixture=$(resolve_fixture_binary "$fixture_root" "1.18.29" || true)
if [[ "$resolved_fixture" == "$fixture_root/node_modules/opencode-linux-x64/bin/opencode" ]]; then
	print_result "failing npm placeholder falls back to exact-version native binary" 0
else
	print_result "failing npm placeholder falls back to exact-version native binary" 1 "$resolved_fixture"
fi

write_version_binary "$fixture_root/node_modules/opencode-linux-x64/bin/opencode" "1.18.28"
resolved_fixture=$(resolve_fixture_binary "$fixture_root" "1.18.29" || true)
if [[ -z "$resolved_fixture" ]]; then
	print_result "resolver rejects placeholder and wrong-version native binary" 0
else
	print_result "resolver rejects placeholder and wrong-version native binary" 1 "$resolved_fixture"
fi

mkdir -p "$fixture_root/tools"
# shellcheck disable=SC2016 # The generated stub must inspect its own positional parameters.
printf '#!/usr/bin/env bash\nif [[ "${*: -1}" == "/proc/cpuinfo" ]]; then exit 1; fi\nexec /usr/bin/grep "$@"\n' \
	>"$fixture_root/tools/grep"
printf '#!/usr/bin/env bash\nprintf "musl libc\\n"\n' >"$fixture_root/tools/ldd"
chmod +x "$fixture_root/tools/grep" "$fixture_root/tools/ldd"
write_version_binary "$fixture_root/node_modules/opencode-linux-x64-musl/bin/opencode" "1.18.29"
write_version_binary "$fixture_root/node_modules/opencode-linux-x64-baseline-musl/bin/opencode" "1.18.29"
resolved_fixture=$(resolve_fixture_binary "$fixture_root" "1.18.29" "$fixture_root/tools:$PATH" || true)
if [[ "$resolved_fixture" == "$fixture_root/node_modules/opencode-linux-x64-baseline-musl/bin/opencode" ]]; then
	print_result "non-AVX2 musl resolution prefers baseline native binary" 0
else
	print_result "non-AVX2 musl resolution prefers baseline native binary" 1 "$resolved_fixture"
fi

echo ""
echo "Tests run: $TESTS_RUN"
echo "Failed:    $TESTS_FAILED"

if [[ "$TESTS_FAILED" -eq 0 ]]; then
	exit 0
fi
exit 1
