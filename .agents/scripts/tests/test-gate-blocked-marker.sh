#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# GH#40288: gate-blocked worktree marker refuses checks until approval verifies.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
HELPER="${SCRIPT_DIR}/gate-blocked-marker-helper.sh"
FAILED=0

pass() { printf 'PASS %s\n' "$1"; return 0; }
fail() { printf 'FAIL %s\n' "$1" >&2; FAILED=$((FAILED + 1)); return 0; }

TMP_ROOT=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP_ROOT"' EXIT
git init -q "$TMP_ROOT/main" -b main
git -C "$TMP_ROOT/main" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
git -C "$TMP_ROOT/main" worktree add -q -b feature/x "$TMP_ROOT/wt"

# Stub approval helper next to a copy of the helper so verify is controllable.
mkdir -p "$TMP_ROOT/bin"
cp "$HELPER" "$TMP_ROOT/bin/gate-blocked-marker-helper.sh"
printf '%s\n' '#!/usr/bin/env bash' "cat \"${TMP_ROOT}/bin/verdict\"" >"$TMP_ROOT/bin/approval-helper.sh"
chmod +x "$TMP_ROOT/bin/approval-helper.sh" "$TMP_ROOT/bin/gate-blocked-marker-helper.sh"
printf 'NO_APPROVAL' >"$TMP_ROOT/bin/verdict"
H="$TMP_ROOT/bin/gate-blocked-marker-helper.sh"

(cd "$TMP_ROOT/wt" && "$H" check .) && pass "no marker allows" || fail "no marker allows"
(cd "$TMP_ROOT/wt" && "$H" set 40288 owner/repo "blocked") || fail "set"
if (cd "$TMP_ROOT/wt" && "$H" check . >/dev/null); then fail "marker blocks"; else pass "marker blocks"; fi
# Marker is per worktree: canonical checkout is unaffected.
(cd "$TMP_ROOT/main" && "$H" check .) && pass "canonical unaffected" || fail "canonical unaffected"
printf 'VERIFIED' >"$TMP_ROOT/bin/verdict"
(cd "$TMP_ROOT/wt" && "$H" check . >/dev/null) && pass "verified approval releases" || fail "verified approval releases"
printf 'NO_APPROVAL' >"$TMP_ROOT/bin/verdict"
(cd "$TMP_ROOT/wt" && "$H" check . >/dev/null) && pass "release is durable" || fail "release is durable"

(cd "$TMP_ROOT/wt" && "$H" set 40288 owner/repo "blocked" && "$H" clear)
(cd "$TMP_ROOT/wt" && "$H" check . >/dev/null) && pass "clear releases" || fail "clear releases"

printf '\nFailed: %s\n' "$FAILED"
[[ "$FAILED" -eq 0 ]]
