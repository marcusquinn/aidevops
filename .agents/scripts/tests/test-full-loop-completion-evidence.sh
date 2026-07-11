#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPT_DIR}/.."
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "${ROOT}/bin"

cat >"${ROOT}/bin/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "${COMPLETION_PR_STATE:-MERGED}" == "MERGED" ]]; then
	printf '%s\n' '{"state":"MERGED","mergedAt":"2026-07-11T00:00:00Z","mergeCommit":{"oid":"merge123"}}'
else
	printf '%s\n' '{"state":"OPEN","mergedAt":null,"mergeCommit":null}'
fi
exit 0
STUB
chmod +x "${ROOT}/bin/gh"

runner="${ROOT}/runner.sh"
cat >"$runner" <<RUNNER
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR='${SCRIPTS_DIR}'
STATE_DIR='${ROOT}/state'
STATE_FILE='${ROOT}/state/full-loop.state'
DEFAULT_MAX_TASK_ITERATIONS=50
DEFAULT_MAX_PREFLIGHT_ITERATIONS=5
DEFAULT_MAX_PR_ITERATIONS=20
HEADLESS=false
BOLD=''
GREEN=''
NC=''
print_error() { return 0; }
print_info() { return 0; }
print_warning() { return 0; }
source '${SCRIPTS_DIR}/full-loop-helper-state.sh'
cmd_complete_after_cleanup "\$@"
RUNNER
chmod +x "$runner"

removed_path="${ROOT}/removed-worktree"
cleanup_log="${ROOT}/cleanup.log"
printf '[2026-07-11T00:00:01Z] [test] worktree-removed: %s — branch-merged — mode=permanent\n' "$removed_path" >"$cleanup_log"
AIDEVOPS_CLEANUP_LOG="$cleanup_log" PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" bash "$runner" 42 "$removed_path" testorg/repo >/dev/null || {
	printf 'FAIL complete merged and cleaned evidence was rejected\n'
	exit 1
}
printf 'PASS merged and cleaned evidence completes lifecycle\n'

mkdir -p "$removed_path"
if AIDEVOPS_CLEANUP_LOG="$cleanup_log" PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" bash "$runner" 42 "$removed_path" testorg/repo >/dev/null; then
	printf 'FAIL existing worktree was accepted as cleaned\n'
	exit 1
fi
printf 'PASS existing worktree keeps cleanup pending\n'
rm -rf "$removed_path"

if COMPLETION_PR_STATE=OPEN AIDEVOPS_CLEANUP_LOG="$cleanup_log" PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" bash "$runner" 42 "$removed_path" testorg/repo >/dev/null; then
	printf 'FAIL open PR was accepted as complete\n'
	exit 1
fi
printf 'PASS open PR blocks lifecycle completion\n'

if AIDEVOPS_CLEANUP_LOG="${ROOT}/missing.log" PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" bash "$runner" 42 "$removed_path" testorg/repo >/dev/null; then
	printf 'FAIL absent cleanup audit was accepted as complete\n'
	exit 1
fi
printf 'PASS absent cleanup audit blocks lifecycle completion\n'

exit 0
