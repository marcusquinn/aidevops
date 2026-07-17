#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUS_LIB="$SCRIPT_DIR/../aidevops-cli/aidevops-status-lib.sh"
TEST_ROOT="$(mktemp -d -t aidevops-status-bundle.XXXXXX)"
HOME="$TEST_ROOT/home"
ACTIVE_BUNDLE="$HOME/.aidevops/runtime-bundles/fixture/agents"
STALE_BUNDLE="$HOME/.aidevops/runtime-bundles/stale/agents"
export HOME

cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

print_success() {
	local text="$1"
	printf 'SUCCESS: %s\n' "$text"
	return 0
}

print_warning() {
	local text="$1"
	printf 'WARNING: %s\n' "$text"
	return 0
}

get_version() {
	printf 'stale-process-version\n'
	return 0
}

mkdir -p "$ACTIVE_BUNDLE" "$STALE_BUNDLE" "$HOME/.aidevops"
ln -s "$ACTIVE_BUNDLE" "$HOME/.aidevops/agents"
printf '3.32.145\n' >"$ACTIVE_BUNDLE/VERSION"
printf '3.32.140\n' >"$STALE_BUNDLE/VERSION"
printf '%s\n' \
	'status=validated' \
	'framework_version=3.32.145' \
	'git_sha=0123456789abcdef' >"$ACTIVE_BUNDLE/.bundle-manifest"
printf '0123456789abcdef\n' >"$HOME/.aidevops/.deployed-sha"
AIDEVOPS_AGENTS_DIR="$STALE_BUNDLE"
AGENTS_DIR="$STALE_BUNDLE"
export AIDEVOPS_AGENTS_DIR AGENTS_DIR

# shellcheck source=../aidevops-cli/aidevops-status-lib.sh
source "$STATUS_LIB"

if [[ "$(_status_active_bundle_version)" != "3.32.145" ]]; then
	printf 'FAIL: status trusted a stale inherited bundle instead of the active symlink\n' >&2
	exit 1
fi
output=$(_status_runtime_bundle_integrity)
if [[ "$output" != *"Active runtime bundle metadata is coherent"* ]]; then
	printf 'FAIL: coherent active bundle was not recognized: %s\n' "$output" >&2
	exit 1
fi

printf '3.32.999\n' >"$ACTIVE_BUNDLE/VERSION"
output=$(_status_runtime_bundle_integrity)
if [[ "$output" != *"Active runtime bundle mismatch"* || "$output" != *"manifest version=3.32.145"* ]]; then
	printf 'FAIL: mutated VERSION versus stale manifest was not exposed: %s\n' "$output" >&2
	exit 1
fi

printf '%s\n' 'PASS: status resolves the active bundle and exposes metadata mismatch'
exit 0
