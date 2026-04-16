#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-basename-collision-resolver.sh — t2149 / GH#19399 regression guard.
#
# Verifies that `_resolve_basename_collisions_for_generate` in
# generate-runtime-config.sh:
#
#   1. When two source files share a basename and exactly one declares
#      `bash: false` in its YAML frontmatter, the restrictive source wins.
#
#   2. When two permissive sources share a basename (no `bash: false` in
#      either), the alphabetically-first path wins — deterministic tiebreak.
#
#   3. A warning is emitted to stderr only when the winner's sandbox intent
#      differs from a loser's. Equally-permissive collisions produce no
#      warning (would be noise — the design-library numeric filenames
#      collide by the dozen and all have identical permissions).
#
#   4. The subagent deploy loop, driven by this resolver, no longer races:
#      re-running twice produces the same deployed stub both times.
#
# Failure history: GH#18509 fixed single-file sandbox shadowing but the
# loop still iterated per-source, so a later commit that introduced a
# permissive basename collision with an older sandboxed source would
# silently downgrade it based on xargs -P scheduling. GH#19399 / t2149
# generalises the GH#18509 invariant across basenames.

set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1" rc="$2" extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%sFAIL%s %s %s\n' "$TEST_RED" "$TEST_RESET" "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

# Build a throwaway AGENTS_DIR with three synthetic subtrees:
#   aidevops/architecture.md          — declares bash: false
#   mermaid-diagrams-skill/arch.md    — no frontmatter (permissive)
#   a/shared.md, b/shared.md          — equally permissive collision
#   c/single.md                       — no collision, no frontmatter
build_fixture_agents_dir() {
	local dir="$1"
	mkdir -p "$dir/aidevops" "$dir/mermaid-diagrams-skill" "$dir/a" "$dir/b" "$dir/c"

	cat >"$dir/aidevops/architecture.md" <<'EOF'
---
description: Sandboxed architecture agent
mode: subagent
tools:
  read: true
  bash: false
  webfetch: false
---

Sandboxed content.
EOF

	cat >"$dir/mermaid-diagrams-skill/architecture.md" <<'EOF'
Permissive content — no frontmatter.
EOF

	cat >"$dir/a/shared.md" <<'EOF'
---
description: A shared permissive
mode: subagent
---

From a/.
EOF

	cat >"$dir/b/shared.md" <<'EOF'
---
description: B shared permissive
mode: subagent
---

From b/.
EOF

	cat >"$dir/c/single.md" <<'EOF'
---
description: Single non-colliding permissive
mode: subagent
---

Alone.
EOF

	return 0
}

# --- Setup ---
FIXTURE_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t t2149)
trap 'rm -rf "$FIXTURE_DIR"' EXIT

build_fixture_agents_dir "$FIXTURE_DIR"

# Source the generator (library mode — won't run top-level `main` because
# the script routes subcommands via a case; sourcing at script scope
# defines the functions).
# shellcheck disable=SC1091
source "$TEST_SCRIPTS_DIR/shared-constants.sh"
# generate-runtime-config.sh has `set -euo pipefail` at top; sourcing it
# will apply those set options to this shell. Capture and restore.
set +e
# shellcheck disable=SC1091
source "$TEST_SCRIPTS_DIR/generate-runtime-config.sh" 2>/dev/null || true
set +e

if ! declare -F _resolve_basename_collisions_for_generate >/dev/null; then
	echo "FAIL: _resolve_basename_collisions_for_generate not defined after sourcing"
	exit 1
fi

# --- Run resolver against fixture ---
export AGENTS_DIR="$FIXTURE_DIR"
stderr_log=$(mktemp)
winners_raw=$(mktemp)
_resolve_basename_collisions_for_generate 2>"$stderr_log" >"$winners_raw"
# Convert NUL-delimited output to newline-delimited for assertions
winners=$(tr '\0' '\n' <"$winners_raw" | grep -v '^$' | sort)

# --- Assertions ---

# 1. architecture collision: sandboxed aidevops/ wins over permissive skill/.
if echo "$winners" | grep -qE "/aidevops/architecture\\.md$" &&
	! echo "$winners" | grep -qE "/mermaid-diagrams-skill/architecture\\.md$"; then
	print_result "sandboxed source wins over permissive sibling" 0
else
	print_result "sandboxed source wins over permissive sibling" 1 \
		"winners:\n$winners"
fi

# 2. shared.md collision: alphabetical tiebreak → a/ wins over b/.
if echo "$winners" | grep -qE "/a/shared\\.md$" &&
	! echo "$winners" | grep -qE "/b/shared\\.md$"; then
	print_result "alphabetical tiebreak picks first path deterministically" 0
else
	print_result "alphabetical tiebreak picks first path deterministically" 1 \
		"winners:\n$winners"
fi

# 3. single.md: no collision, included as-is.
if echo "$winners" | grep -qE "/c/single\\.md$"; then
	print_result "non-colliding source included" 0
else
	print_result "non-colliding source included" 1 "winners:\n$winners"
fi

# 4. Exactly one warning: the sandboxed-vs-permissive architecture case.
warn_count=$(grep -cE '^\[WARN\] basename collision' "$stderr_log" || echo 0)
# Strip any whitespace/newlines from wc output
warn_count=$(printf '%s' "$warn_count" | tr -d '[:space:]')
if [[ "$warn_count" == "1" ]]; then
	print_result "warning emitted only for mixed-sandbox collision" 0
else
	print_result "warning emitted only for mixed-sandbox collision" 1 \
		"expected 1 warning, got $warn_count. stderr:\n$(cat "$stderr_log")"
fi

# 5. The warning describes the architecture basename and identifies sandbox vs default.
if grep -qE 'architecture.*bash:default.*loses to.*bash:false' "$stderr_log"; then
	print_result "warning describes bash intent mix" 0
else
	print_result "warning describes bash intent mix" 1 \
		"stderr:\n$(cat "$stderr_log")"
fi

# 6. Winner count: 4 unique basenames (architecture, shared, single — plus
#    the fixture also includes c/single.md which is alone). Expect exactly 3.
winner_count=$(printf '%s\n' "$winners" | wc -l | tr -d '[:space:]')
if [[ "$winner_count" == "3" ]]; then
	print_result "one winner per unique basename (no duplicates)" 0
else
	print_result "one winner per unique basename (no duplicates)" 1 \
		"expected 3 winners, got $winner_count:\n$winners"
fi

# 7. Determinism: running the resolver twice yields the same output.
second_run=$(_resolve_basename_collisions_for_generate 2>/dev/null |
	tr '\0' '\n' | grep -v '^$' | sort)
if [[ "$winners" == "$second_run" ]]; then
	print_result "resolver output is deterministic across runs" 0
else
	print_result "resolver output is deterministic across runs" 1 \
		"first:\n$winners\nsecond:\n$second_run"
fi

rm -f "$stderr_log" "$winners_raw"

# --- Summary ---
echo ""
echo "Tests run: $TESTS_RUN"
echo "Failed:    $TESTS_FAILED"

if [[ "$TESTS_FAILED" -eq 0 ]]; then
	exit 0
fi
exit 1
