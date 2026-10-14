#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/../prework-discovery-helper.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin"
cat >"$TMP_DIR/bin/gh" <<'SH'
#!/usr/bin/env bash
if [[ "$1 $2" == 'issue list' ]]; then
	printf '%s\n' "$*" >>"$GH_STUB_LOG"
	[[ "$*" == *'--state open'* && "$*" == *'in:title label:status:claimed,origin:interactive'* && "$*" == *'--limit 5'* && "$*" == *'--repo owner/repo'* ]] || exit 1
	printf '[{"number":1,"title":"develop deploy failure","url":"issue-1","assignees":[{"login":"owner"}]},'
	printf '{"number":2,"title":"migration failure","url":"issue-2","assignees":[]},'
	printf '{"number":3,"title":"CI failure","url":"issue-3","assignees":[]},'
	printf '{"number":4,"title":"deploy failure","url":"issue-4","assignees":[]},'
	printf '{"number":5,"title":"migration stalled","url":"issue-5","assignees":[]}]\n'
else
	printf 'stub-pr\n'
fi
SH
chmod +x "$TMP_DIR/bin/gh"
export GH_STUB_LOG="$TMP_DIR/gh.log"

output="$TMP_DIR/out.md"
PATH="$TMP_DIR/bin:$PATH" "$HELPER" --keywords 'helper token efficiency' --files '.agents/AGENTS.md' --repo 'owner/repo' >"$output"

grep -q 'Prework discovery' "$output"
grep -q 'Recently merged related PRs' "$output"
grep -q 'Open related PRs' "$output"
grep -q 'stub-pr' "$output"
grep -q 'Open claimed issues' "$output"
grep -q 'helper token efficiency in:title' "$GH_STUB_LOG"
[[ "$(wc -l <"$GH_STUB_LOG")" -eq 1 ]]

PATH="$TMP_DIR/bin:$PATH" "$HELPER" --blocker 'develop deploy' --repo 'owner/repo' >"$output"
grep -q 'develop deploy failure' "$output"
grep -q 'assignees: owner' "$output"
[[ "$(grep -c '^#1' "$output")" -eq 1 ]]
[[ "$(grep -c '^#[1-5]' "$output")" -eq 5 ]]
grep -q 'develop deploy in:title' "$GH_STUB_LOG"
grep -q 'deploy in:title' "$GH_STUB_LOG"
grep -q 'migration in:title' "$GH_STUB_LOG"
grep -q 'CI in:title' "$GH_STUB_LOG"

if "$HELPER" --blocker >"$output" 2>&1; then
	printf 'FAIL: missing blocker value accepted\n' >&2
	exit 1
fi
grep -q -- '--blocker requires a value' "$output"

printf 'PASS prework-discovery-helper\n'
