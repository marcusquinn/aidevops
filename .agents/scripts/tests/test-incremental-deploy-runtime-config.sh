#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
FIXTURE_REPO="$TEST_ROOT/repo"
TEST_HOME="$TEST_ROOT/home"
MARKER="$TEST_ROOT/runtime-config-generated"

cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

mkdir -p "$FIXTURE_REPO/.agents/scripts" "$TEST_HOME/.aidevops/agents"
git -C "$FIXTURE_REPO" init -q
printf '%s\n' 'ref: refs/heads/fixture' >"$FIXTURE_REPO/.git/HEAD"
printf '%s\n' '3.32.107' >"$FIXTURE_REPO/VERSION"
cat >"$FIXTURE_REPO/.agents/scripts/generate-runtime-config.sh" <<EOF_GENERATOR
#!/usr/bin/env bash
printf '%s\n' "\$1" >"$MARKER"
exit 0
EOF_GENERATOR
cat >"$FIXTURE_REPO/.agents/scripts/example-helper.sh" <<'EOF_HELPER'
#!/usr/bin/env bash
exit 0
EOF_HELPER

HOME="$TEST_HOME" bash "$REPO_ROOT/.agents/scripts/deploy-agents-on-merge.sh" \
	--repo "$FIXTURE_REPO" --scripts-only --quiet
grep -Fxq 'all' "$MARKER"

if bash -c 'source "$1"; runtime_config_changes_detected ".agents/scripts/example-helper.sh"' \
	_ "$REPO_ROOT/.agents/scripts/deploy-agents-on-merge.sh"; then
	printf '%s\n' 'FAIL: unrelated script was classified as a runtime config source' >&2
	exit 1
fi
if ! bash -c 'source "$1"; runtime_config_changes_detected ".agents/scripts/generate-runtime-config-commands.sh"' \
	_ "$REPO_ROOT/.agents/scripts/deploy-agents-on-merge.sh"; then
	printf '%s\n' 'FAIL: runtime config generator change was not classified for regeneration' >&2
	exit 1
fi

cat >"$FIXTURE_REPO/.agents/scripts/generate-runtime-config.sh" <<'EOF_FAILURE'
#!/usr/bin/env bash
exit 9
EOF_FAILURE
if HOME="$TEST_HOME" bash "$REPO_ROOT/.agents/scripts/deploy-agents-on-merge.sh" \
	--repo "$FIXTURE_REPO" --scripts-only --quiet; then
	printf '%s\n' 'FAIL: incremental deploy ignored runtime config regeneration failure' >&2
	exit 1
fi

printf '%s\n' 'PASS: incremental deployment regenerates derived runtime config and propagates failures'
exit 0
