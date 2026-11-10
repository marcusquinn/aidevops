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

# t18895: stub `aidevops sessions` helper. Rows for #123 and the repo; the
# repo call repeats the #123 session, which the helper must not list twice.
cat >"$TMP_DIR/bin/session-bus-stub" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$BUS_STUB_LOG"
[[ "$1" == who ]] || exit 1
peer='peer-123 · busy · #123 · owner/repo@feature/x · worktree repo-x · task: same issue · 5s ago'
case "$*" in
*'#123'*) printf '%s\n' "$peer" ;;
'who owner/repo') printf '%s\nother-1 · idle · owner/repo@main · worktree repo · 1m ago\n' "$peer" ;;
esac
exit 0
SH
cat >"$TMP_DIR/bin/session-bus-slow" <<'SH'
#!/usr/bin/env bash
sleep 20
printf 'late-row\n'
SH
chmod +x "$TMP_DIR/bin/session-bus-stub" "$TMP_DIR/bin/session-bus-slow"
export BUS_STUB_LOG="$TMP_DIR/bus.log"
# Default: no bus, so the GitHub assertions below stay hermetic.
export AIDEVOPS_SESSION_BUS_HELPER="$TMP_DIR/bin/missing-session-bus"

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
if grep -q 'Live sessions' "$output"; then
	printf 'FAIL: live sessions section printed without a bus helper\n' >&2
	exit 1
fi

# t18895: live sessions from the bus, as warnings; exit code unchanged.
AIDEVOPS_SESSION_BUS_HELPER="$TMP_DIR/bin/session-bus-stub" PATH="$TMP_DIR/bin:$PATH" \
	"$HELPER" --keywords 'fix GH#123 parser' --files 'README.md' --repo 'owner/repo' >"$output"
grep -q '^### Live sessions' "$output"
grep -q '^Warning: live sessions on the same issue, worktree or files' "$output"
grep -q '^Also live in owner/repo:' "$output"
grep -q '^- other-1 · idle' "$output"
[[ "$(grep -c '^- peer-123 ' "$output")" -eq 1 ]]
grep -qxF 'who #123 README.md --repo owner/repo' "$BUS_STUB_LOG"
grep -qxF 'who owner/repo' "$BUS_STUB_LOG"

# A bus helper over its 5 s budget prints nothing extra.
AIDEVOPS_SESSION_BUS_HELPER="$TMP_DIR/bin/session-bus-slow" PATH="$TMP_DIR/bin:$PATH" \
	"$HELPER" --keywords 'fix GH#123 parser' --repo 'owner/repo' >"$output"
if grep -q -e 'Live sessions' -e 'late-row' "$output"; then
	printf 'FAIL: live sessions section printed after the bus timed out\n' >&2
	exit 1
fi

if "$HELPER" --blocker >"$output" 2>&1; then
	printf 'FAIL: missing blocker value accepted\n' >&2
	exit 1
fi
grep -q -- '--blocker requires a value' "$output"

printf 'PASS prework-discovery-helper\n'
