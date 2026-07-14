#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression coverage for review-gate repos.json path resolution (GH#27676).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER="${SCRIPT_DIR}/../review-gate-config-helper.sh"
TEST_ROOT="$(mktemp -d -t review-gate-config-path.XXXXXX)"

cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

override_repos_json="${TEST_ROOT}/override-repos.json"
printf '%s\n' '{"initialized_repos":[]}' >"$override_repos_json"

output=$(env -u HOME AIDEVOPS_REPOS_JSON="$override_repos_json" "$HELPER" list)
if [[ "$output" != *"No repos registered"* ]]; then
	printf 'FAIL AIDEVOPS_REPOS_JSON override was not used with HOME unset\n' >&2
	exit 1
fi
printf 'PASS AIDEVOPS_REPOS_JSON override works with HOME unset\n'

stderr_file="${TEST_ROOT}/empty-home.stderr"
if HOME="" env -u AIDEVOPS_REPOS_JSON "$HELPER" list >/dev/null 2>"$stderr_file"; then
	printf 'FAIL empty HOME unexpectedly resolved a repos.json file\n' >&2
	exit 1
fi
if grep -Fq 'repos.json not found: /.config/aidevops/repos.json' "$stderr_file"; then
	printf 'FAIL empty HOME resolved to a root-level config path\n' >&2
	exit 1
fi
printf 'PASS empty HOME does not resolve to a root-level config path\n'

exit 0
