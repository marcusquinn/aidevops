#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT=$(mktemp -d -t aidevops-managed-temp.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT

pass=0
fail=0
assert() {
	local description="$1"
	shift
	if "$@"; then
		printf 'PASS: %s\n' "$description"
		((++pass))
	else
		printf 'FAIL: %s\n' "$description" >&2
		((++fail))
	fi
	return 0
}

# shellcheck source=../shared-temp-workspace.sh
source "$SCRIPTS_DIR/shared-temp-workspace.sh"
HOME="$TEST_ROOT/home"
mkdir -p "$HOME"
unset AIDEVOPS_WORKSPACE_DIR
export TMPDIR="/host/tmpdir"
export TMP="/host/tmp"
export TEMP="/host/temp"
aidevops_init_temp_workspace
expected=$(cd "$HOME/.aidevops/.agent-workspace/tmp" && pwd -P)
assert "initializer preserves host TMPDIR" test "$TMPDIR" = "/host/tmpdir"
assert "initializer preserves host TMP" test "$TMP" = "/host/tmp"
assert "initializer preserves host TEMP" test "$TEMP" = "/host/temp"
assert "initializer exports the canonical aidevops temp directory" test "$AIDEVOPS_TEMP_DIR" = "$expected"
assert "managed temp directory exists" test -d "$expected"
managed_temp_file=$(mktemp "$AIDEVOPS_TEMP_DIR/aidevops-test.XXXXXX")
assert "canonical temp directory supports managed artifacts" test "${managed_temp_file#"$expected"/}" != "$managed_temp_file"
unset TMPDIR TMP TEMP
aidevops_init_temp_workspace
assert "initializer leaves absent TMPDIR unset" test -z "${TMPDIR+x}"
assert "initializer leaves absent TMP unset" test -z "${TMP+x}"
assert "initializer leaves absent TEMP unset" test -z "${TEMP+x}"

runtime_artifact_files=(
	"$SCRIPTS_DIR/../AGENTS.md"
	"$SCRIPTS_DIR/browser-qa-worker.sh"
	"$SCRIPTS_DIR/browser-qa/browser-qa.mjs"
	"$SCRIPTS_DIR/milestone-validation-worker.sh"
	"$SCRIPTS_DIR/../prompts/worker-efficiency-protocol.md"
	"$SCRIPTS_DIR/../workflows/full-loop.md"
	"$SCRIPTS_DIR/../workflows/log-issue-aidevops.md"
	"$SCRIPTS_DIR/../workflows/runners.md"
	"$SCRIPTS_DIR/../workflows/ui-verification.md"
)
assert "agent guidance directs readable artifacts to the managed workspace" grep -q "temporary artifacts.*AIDEVOPS_TEMP_DIR.*never host \`/tmp\`" "$SCRIPTS_DIR/../AGENTS.md"
assert "runtime-visible artifact defaults avoid host /tmp paths" test -z "$(grep -El '/tmp/(browser-qa|aidevops-(pr-body|merge-summary|issue-body)|ui-verify|worker-)' "${runtime_artifact_files[@]}" || true)"

print_info() { return 0; }
print_warning() { return 0; }
FRAMEWORK_PROCESS_PATTERN='opencode|aidevops'
_is_process_alive_and_matches() { return 1; }
nm() {
	local path="${*: -1}"
	[[ "$path" != *not-fff* ]] || return 1
	printf '00000000 T fff_create_instance2\n00000000 T fff_destroy\n00000000 T fff_search\n'
	return 0
}
lsof() {
	local path="$1"
	[[ "$path" == *held* ]] && return 0
	return 1
}
# shellcheck source=../portable-stat.sh
source "$SCRIPTS_DIR/portable-stat.sh"
# shellcheck source=../setup/modules/migrations.sh
source "$SCRIPTS_DIR/setup/modules/migrations.sh"

legacy_root="$TEST_ROOT/legacy"
mkdir -p "$legacy_root"
old_named="$legacy_root/aidevops-worker-auth.old"
old_generic="$legacy_root/tmp.not-owned"
new_named="$legacy_root/aidevops-canary.new"
mkdir -p "$old_named" "$old_generic" "$new_named"
touch -t 202001010000 "$old_named" "$old_generic"
stale_fff="$expected/.stale-00000000.so"
held_fff="$expected/.held-00000000.so"
not_fff="$expected/.not-fff-00000000.so"
recent_fff="$expected/.recent-00000000.so"
touch "$stale_fff" "$held_fff" "$not_fff" "$recent_fff"
touch -t 202001010000 "$stale_fff" "$held_fff" "$not_fff"
AIDEVOPS_LEGACY_TEMP_ROOT="$legacy_root" AIDEVOPS_TEMP_MAX_AGE_SECONDS=60 cleanup_legacy_aidevops_temp_artifacts
assert "old named aidevops artifact is removed" test ! -e "$old_named"
assert "generic tmp artifact is preserved" test -d "$old_generic"
assert "recent named artifact is preserved" test -d "$new_named"
assert "stale attributable FFF artifact without holders is removed" test ! -e "$stale_fff"
assert "held FFF artifact is preserved" test -f "$held_fff"
assert "non-attributable native artifact is preserved" test -f "$not_fff"
assert "recent FFF artifact is preserved" test -f "$recent_fff"

assert "setup invokes legacy cleanup in both modes" test "$(grep -c 'cleanup_legacy_aidevops_temp_artifacts' "$SCRIPTS_DIR/../../setup.sh")" -ge 2

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
