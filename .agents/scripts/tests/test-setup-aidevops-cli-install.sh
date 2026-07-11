#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
CONFIG_LIB="${REPO_ROOT}/.agents/scripts/setup/modules/config.sh"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aidevops-cli-install.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

print_info() { return 0; }
print_success() { return 0; }
print_warning() { return 0; }

# shellcheck source=../setup/modules/config.sh
source "$CONFIG_LIB"

# Exercise setup.sh itself with its normal default and invalid HOME values.
# Invalid values must fail before setup can derive or write any user paths.
setup_home="$TEST_DIR/setup-home"
mkdir -p "$setup_home"
setup_trace=$(env -u AGENTS_DIR -u AIDEVOPS_AGENTS_DIR HOME="$setup_home" \
	bash -x "$REPO_ROOT/setup.sh" --help 2>&1)
if [[ "$setup_trace" != *"AGENTS_DIR=$setup_home/.aidevops/agents"* ||
	"$setup_trace" != *"export REPO_URL INSTALL_DIR AGENTS_DIR"* ]]; then
	printf 'FAIL: setup.sh did not define and export the default AGENTS_DIR\n' >&2
	exit 1
fi
for home_state in unset empty; do
	invalid_home_status=0
	if [[ "$home_state" == "unset" ]]; then
		invalid_home_trace=$(env -u AGENTS_DIR -u AIDEVOPS_AGENTS_DIR -u HOME \
			bash "$REPO_ROOT/setup.sh" --help 2>&1) || invalid_home_status=$?
	else
		invalid_home_trace=$(env -u AGENTS_DIR -u AIDEVOPS_AGENTS_DIR HOME= \
			bash "$REPO_ROOT/setup.sh" --help 2>&1) || invalid_home_status=$?
	fi
	if [[ "$invalid_home_status" -ne 1 ||
		"$invalid_home_trace" != *"HOME environment variable is unset or empty"* ||
		"$invalid_home_trace" == *"/.aidevops"* ]]; then
		printf 'FAIL: setup.sh did not fail safely with HOME %s\n' "$home_state" >&2
		exit 1
	fi
done
printf 'PASS: setup.sh rejects unset and empty HOME values\n'

source_cli="$TEST_DIR/source-cli"
target_cli="$TEST_DIR/bin/aidevops"
old_target="$TEST_DIR/old-target"
mkdir -p "$TEST_DIR/bin"
printf '#!/usr/bin/env bash\nprintf "current\\n"\n' >"$source_cli"
printf 'old\n' >"$old_target"
chmod 0755 "$source_cli"
ln -s "$old_target" "$target_cli"

_install_aidevops_cli_copy "$source_cli" "$target_cli"

if [[ -L "$target_cli" ]]; then
	printf 'FAIL: installed CLI remains a symlink\n' >&2
	exit 1
fi
if [[ ! -x "$target_cli" ]]; then
	printf 'FAIL: installed CLI is not executable\n' >&2
	exit 1
fi
if [[ "$("$target_cli")" != "current" ]]; then
	printf 'FAIL: installed CLI does not contain the current entrypoint\n' >&2
	exit 1
fi
if [[ "$(tr -d '\n' <"$old_target")" != "old" ]]; then
	printf 'FAIL: replacing the symlink modified its former target\n' >&2
	exit 1
fi

printf 'PASS: setup installs an executable standalone CLI atomically\n'
