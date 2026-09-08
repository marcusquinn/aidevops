#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HOOK="${SCRIPT_DIR}/../hooks/canonical-on-main-guard.sh"
INSTALLER="${CANONICAL_GUARD_INSTALLER:-${SCRIPT_DIR}/install-canonical-guard.sh}"
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
# Never use or change the operator's deployed hooks in synthetic repositories.
export HOME="${ROOT}/home"
REPO="${ROOT}/repo"
LINKED="${ROOT}/linked"
TESTS=0
FAILURES=0

pass() {
	TESTS=$((TESTS + 1))
	printf 'PASS %s\n' "$1"
	return 0
}
fail() {
	TESTS=$((TESTS + 1))
	FAILURES=$((FAILURES + 1))
	printf 'FAIL %s\n' "$1"
	return 0
}

mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.name Test
git -C "$REPO" config user.email test@example.invalid
git -C "$REPO" config commit.gpgsign false
printf 'seed\n' >"${REPO}/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -q -m seed
git -C "$REPO" remote add origin "$REPO"
git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main

if (cd "$REPO" && bash "$HOOK" HEAD HEAD 1 >/dev/null 2>&1); then
	pass "canonical default branch satisfies invariant"
else
	fail "canonical default branch satisfies invariant"
fi

git -C "$REPO" switch -q -c feature/test
if (cd "$REPO" && bash "$HOOK" HEAD HEAD 1 >/dev/null 2>&1); then
	fail "canonical off-default branch is detected"
else
	[[ "$(git -C "$REPO" branch --show-current)" == "feature/test" ]] && pass "canonical off-default branch is detected without repair" || fail "canonical detector mutated branch"
fi

git -C "$REPO" switch -q --detach main
if (cd "$REPO" && bash "$HOOK" HEAD HEAD 1 >/dev/null 2>&1); then
	fail "canonical detached HEAD is detected"
else
	[[ -z "$(git -C "$REPO" branch --show-current)" ]] && pass "canonical detached HEAD is detected without repair" || fail "detached detector mutated HEAD"
fi

git -C "$REPO" switch -q main
git -C "$REPO" worktree add -q -b feature/linked "$LINKED"
if (cd "$LINKED" && bash "$HOOK" HEAD HEAD 1 >/dev/null 2>&1); then
	pass "linked worktree branch is allowed"
else
	fail "linked worktree branch is allowed"
fi

git -C "$REPO" config core.hooksPath .custom-hooks
if (cd "$REPO" && bash "$INSTALLER" install >/dev/null 2>&1) && [[ -x "${REPO}/.custom-hooks/post-checkout" ]]; then
	pass "installer uses effective core.hooksPath"
else
	fail "installer uses effective core.hooksPath"
fi
if [[ ! -e "${REPO}/.git/hooks/post-checkout" ]]; then
	pass "installer does not report inactive default hook path"
else
	fail "installer wrote inactive default hook path"
fi

POST_CHECKOUT="${REPO}/.custom-hooks/post-checkout"
mkdir -p "${REPO}/.agents/hooks" "${ROOT}/bin" "$HOME"
export TRACE="${ROOT}/trace"
export PATH="${ROOT}/bin:$PATH"
cat >"${REPO}/.agents/hooks/canonical-on-main-guard.sh" <<'GUARD'
#!/usr/bin/env bash
printf 'guard\n' >>"$TRACE"
exit "${GUARD_STATUS:-0}"
GUARD
cat >"${ROOT}/bin/bd" <<'BEADS'
#!/usr/bin/env bash
printf 'beads:%s:%s:%s:%s:%s:%s:%s\n' "${BD_GIT_HOOK:-}" "$1" "$2" "$3" "$4" "$5" "$6" >>"$TRACE"
exit "${BEADS_STATUS:-0}"
BEADS
chmod +x "${REPO}/.agents/hooks/canonical-on-main-guard.sh" "${ROOT}/bin/bd"
cat >"${ROOT}/beads-section" <<'SECTION'
# --- BEGIN BEADS INTEGRATION v1.0.3 ---
# This section is managed by beads. Do not remove these markers.
if command -v bd >/dev/null 2>&1; then
  export BD_GIT_HOOK=1
  bd hooks run post-checkout "$@"
  _bd_exit=$?
  if [ "$_bd_exit" -eq 3 ]; then _bd_exit=0; fi
  if [ "$_bd_exit" -ne 0 ]; then exit "$_bd_exit"; fi
fi
# --- END BEADS INTEGRATION v1.0.3 ---
SECTION
if [[ -n "${CANONICAL_GUARD_HOOK_FIXTURE:-}" ]]; then
	# Exercise a reviewed real-world hook without installing it in its source repo.
	cp "$CANONICAL_GUARD_HOOK_FIXTURE" "$POST_CHECKOUT"
	sed -n '/^# --- BEGIN BEADS INTEGRATION/,$p' "$POST_CHECKOUT" >"${ROOT}/beads-section"
else
	cat "${ROOT}/beads-section" >>"$POST_CHECKOUT"
fi
if (cd "$REPO" && bash "$INSTALLER" install >/dev/null 2>&1); then
	pass "refresh accepts a complete Beads section"
else
	fail "refresh accepts a complete Beads section"
fi
sed -n '/^# --- BEGIN BEADS INTEGRATION/,$p' "$POST_CHECKOUT" >"${ROOT}/retained-section"
if cmp -s "${ROOT}/beads-section" "${ROOT}/retained-section"; then
	pass "refresh preserves Beads section verbatim"
else
	fail "refresh preserves Beads section verbatim"
fi
cp "$POST_CHECKOUT" "${ROOT}/refreshed-hook"
if (cd "$REPO" && bash "$INSTALLER" install >/dev/null 2>&1) && cmp -s "$POST_CHECKOUT" "${ROOT}/refreshed-hook"; then
	pass "repeated refresh is byte-idempotent"
else
	fail "repeated refresh is byte-idempotent"
fi
printf 'guard\nbeads:1:hooks:run:post-checkout:old value:new value:1\n' >"${ROOT}/expected-trace"
: >"$TRACE"
if (cd "$REPO" && bash "$POST_CHECKOUT" 'old value' 'new value' 1) && cmp -s "$TRACE" "${ROOT}/expected-trace"; then
	pass "guard runs before Beads exactly once with quoted arguments"
else
	fail "guard runs before Beads exactly once with quoted arguments"
fi
fixture_head=$(git -C "$REPO" rev-parse HEAD)
printf 'guard\nbeads:1:hooks:run:post-checkout:%s:%s:0\n' "$fixture_head" "$fixture_head" >"${ROOT}/expected-trace"
: >"$TRACE"
if git -C "$REPO" checkout -- README.md && cmp -s "$TRACE" "${ROOT}/expected-trace"; then
	pass "actual Git file checkout invokes guard then Beads"
else
	fail "actual Git file checkout invokes guard then Beads"
fi
: >"$TRACE"
result=0
(cd "$REPO" && GUARD_STATUS=17 bash "$POST_CHECKOUT" old new 1) || result=$?
if [[ "$result" -eq 17 && "$(cat "$TRACE")" == guard ]]; then
	pass "guard failure propagates and prevents Beads execution"
else
	fail "guard failure propagates and prevents Beads execution"
fi
result=0
(cd "$REPO" && BEADS_STATUS=19 bash "$POST_CHECKOUT" old new 1) || result=$?
[[ "$result" -eq 19 ]] && pass "Beads failure propagates" || fail "Beads failure propagates"
if (cd "$REPO" && BEADS_STATUS=3 bash "$POST_CHECKOUT" old new 1); then
	pass "Beads uninitialized-database policy is preserved"
else
	fail "Beads uninitialized-database policy is preserved"
fi
mv "${REPO}/.agents/hooks/canonical-on-main-guard.sh" "${ROOT}/guard"
: >"$TRACE"
if (cd "$REPO" && bash "$POST_CHECKOUT" old new 1 >/dev/null 2>&1) || [[ -s "$TRACE" ]]; then
	fail "missing guard fails closed before Beads"
else
	pass "missing guard fails closed before Beads"
fi
mkdir -p "${HOME}/.aidevops/agents/hooks"
cp "${ROOT}/guard" "${HOME}/.aidevops/agents/hooks/canonical-on-main-guard.sh"
if (cd "$REPO" && bash "$POST_CHECKOUT" old new 1); then
	pass "deployed fallback still supports Beads chaining"
else
	fail "deployed fallback still supports Beads chaining"
fi
if (cd "$REPO" && bash "$INSTALLER" uninstall >/dev/null 2>&1) || ! cmp -s "$POST_CHECKOUT" "${ROOT}/refreshed-hook"; then
	fail "uninstall refuses to delete a shared Beads hook"
else
	pass "uninstall refuses to delete a shared Beads hook"
fi
for scenario in missing-end duplicate mismatched-version trailing-code invalid-shell; do
	cp "${ROOT}/refreshed-hook" "$POST_CHECKOUT"
	case "$scenario" in
	missing-end) sed '/^# --- END BEADS INTEGRATION/d' "${ROOT}/refreshed-hook" >"$POST_CHECKOUT" ;;
	duplicate) cat "${ROOT}/beads-section" >>"$POST_CHECKOUT" ;;
	mismatched-version) sed 's/END BEADS INTEGRATION v1.0.3/END BEADS INTEGRATION v9.9.9/' "${ROOT}/refreshed-hook" >"$POST_CHECKOUT" ;;
	trailing-code) printf '\nprintf unexpected\n' >>"$POST_CHECKOUT" ;;
	invalid-shell) sed '/^# --- END BEADS INTEGRATION/i\
if\
' "${ROOT}/refreshed-hook" >"$POST_CHECKOUT" ;;
	esac
	cp "$POST_CHECKOUT" "${ROOT}/before-refusal"
	if (cd "$REPO" && bash "$INSTALLER" install >/dev/null 2>&1) || ! cmp -s "$POST_CHECKOUT" "${ROOT}/before-refusal"; then
		fail "refuses $scenario without modifying original hook"
	else
		pass "refuses $scenario without modifying original hook"
	fi
done
rm "$POST_CHECKOUT"
ln -s "${ROOT}/refreshed-hook" "$POST_CHECKOUT"
if (cd "$REPO" && bash "$INSTALLER" install >/dev/null 2>&1) || [[ ! -L "$POST_CHECKOUT" ]]; then
	fail "refuses symbolic-link hook targets"
else
	pass "refuses symbolic-link hook targets"
fi
rm "$POST_CHECKOUT"
printf '#!/usr/bin/env bash\nprintf unmanaged\n' >"$POST_CHECKOUT"
cp "$POST_CHECKOUT" "${ROOT}/unmanaged"
if (cd "$REPO" && bash "$INSTALLER" install >/dev/null 2>&1) || ! cmp -s "$POST_CHECKOUT" "${ROOT}/unmanaged"; then
	fail "refuses unmanaged hooks without overwriting them"
else
	pass "refuses unmanaged hooks without overwriting them"
fi

printf '\nTests: %d, Failures: %d\n' "$TESTS" "$FAILURES"
[[ "$FAILURES" -eq 0 ]]
