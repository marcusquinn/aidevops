#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pipe-early-exit-check:disable — fixtures embed the anti-pattern deliberately
#
# test-pipe-early-exit-check.sh — fixtures for pipe-early-exit-check.sh

set -u
set +e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="${SCRIPT_DIR}/../pipe-early-exit-check.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

FAILED=0
RUN=0

# expect <name> <expected-rc> <file> [extra args before file...]
expect() {
	local _name="$1"
	local _want="$2"
	shift 2
	local _out
	_out=$(bash "$CHECK" --scan-files "$@" 2>&1)
	local _rc=$?
	RUN=$((RUN + 1))
	if [[ "$_rc" -eq "$_want" ]]; then
		printf 'PASS: %s\n' "$_name"
	else
		printf 'FAIL: %s (rc=%s want=%s)\n%s\n' "$_name" "$_rc" "$_want" "$_out"
		FAILED=$((FAILED + 1))
	fi
	LAST_OUT="$_out"
	return 0
}

LAST_OUT=""

# 1. printf | grep -qF under pipefail is flagged, naming file and line
cat >"$TMP/bad.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
body="x"
printf '%s\n' "$body" | grep -qF "$marker"
EOF
expect "flags pipe to grep -q" 1 "$TMP/bad.sh"
if [[ "$LAST_OUT" != *"bad.sh:4:"* ]]; then
	printf 'FAIL: output lacks file:line\n%s\n' "$LAST_OUT"
	FAILED=$((FAILED + 1))
fi

# 2. here-string passes
cat >"$TMP/good.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
grep -qF -- "$marker" <<<"$body"
EOF
expect "allows here-string" 0 "$TMP/good.sh"

# 3. head and grep -m1 flagged
cat >"$TMP/head.sh" <<'EOF'
set -o pipefail
a=$(list | head -n 1)
b=$(list | grep -m1 foo)
c=$(list | grep -m 10 foo)
EOF
expect "flags head and grep -m1" 1 "$TMP/head.sh"
if [[ "$LAST_OUT" != *"head.sh:2:"* || "$LAST_OUT" != *"head.sh:3:"* || "$LAST_OUT" == *"head.sh:4:"* ]]; then
	printf 'FAIL: unexpected line set\n%s\n' "$LAST_OUT"
	FAILED=$((FAILED + 1))
fi

# 4. no pipefail -> ignored
cat >"$TMP/nopf.sh" <<'EOF'
set -eu
printf x | grep -q x
EOF
expect "ignores file without pipefail" 0 "$TMP/nopf.sh"

# 5. disable directive
cat >"$TMP/dis.sh" <<'EOF'
# pipe-early-exit-check:disable
set -o pipefail
printf x | grep -q x
EOF
expect "honours disable directive" 0 "$TMP/dis.sh"

# 6. comments and || are ignored
cat >"$TMP/cmt.sh" <<'EOF'
set -o pipefail
# printf x | grep -q x
true || grep -q x file
EOF
expect "ignores comments and ||" 0 "$TMP/cmt.sh"

# 7. non-.sh file and no-.sh set are ignored
printf 'printf x | grep -q x\n' >"$TMP/readme.md"
expect "ignores non-.sh files" 0 "$TMP/readme.md"

# 8. diff-scoped: legacy match passes, added match fails
(
	cd "$TMP" || exit 1
	git init -q . && git config user.email t@example.com && git config user.name t
	git config commit.gpgsign false
	printf 'set -o pipefail\nprintf x | grep -q x\n' >legacy.sh
	git add legacy.sh && git commit -q -m base
	printf 'echo ok\n' >>legacy.sh
) >/dev/null 2>&1
(cd "$TMP" && bash "$CHECK" --scan-files --diff-base HEAD legacy.sh >/dev/null 2>&1)
RC=$?
RUN=$((RUN + 1))
if [[ "$RC" -eq 0 ]]; then printf 'PASS: diff-scope ignores legacy match\n'; else
	printf 'FAIL: diff-scope legacy rc=%s\n' "$RC"
	FAILED=$((FAILED + 1))
fi
printf 'printf y | grep -q y\n' >>"$TMP/legacy.sh"
(cd "$TMP" && bash "$CHECK" --scan-files --diff-base HEAD legacy.sh >/dev/null 2>&1)
RC=$?
RUN=$((RUN + 1))
if [[ "$RC" -eq 1 ]]; then printf 'PASS: diff-scope flags added match\n'; else
	printf 'FAIL: diff-scope added rc=%s\n' "$RC"
	FAILED=$((FAILED + 1))
fi

printf '\n%d run, %d failed\n' "$RUN" "$FAILED"
[[ "$FAILED" -eq 0 ]]
