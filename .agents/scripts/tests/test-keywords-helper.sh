#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-keywords-helper.sh — context/keywords.md registry regression tests (offline).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
HELPER="$REPO_ROOT/.agents/scripts/keywords-helper.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi
	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	[[ -n "$message" ]] && printf '       %s\n' "$message"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

cleanup() {
	if [[ -n "${TEST_ROOT:-}" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}
trap cleanup EXIT

check() {
	local test_name="$1"
	shift
	local output=""
	if output=$("$@" 2>&1); then
		print_result "$test_name" 0
		return 0
	fi
	print_result "$test_name" 1 "$(printf '%s' "$output" | tail -3)"
	return 0
}

check_fails() {
	local test_name="$1"
	shift
	if "$@" >/dev/null 2>&1; then
		print_result "$test_name" 1 "command unexpectedly succeeded"
		return 0
	fi
	print_result "$test_name" 0
	return 0
}

contains() {
	local file="$1"
	local needle="$2"
	grep -qF -- "$needle" "$file"
	return $?
}

kw() {
	"$HELPER" "$@" --root "$REPO_DIR"
	return $?
}

setup_repo() {
	TEST_ROOT=$(mktemp -d)
	REPO_DIR="$TEST_ROOT/widget"
	mkdir -p "$REPO_DIR/context"
	git -C "$REPO_DIR" init --quiet
	git -C "$REPO_DIR" remote add origin "https://github.com/example/widget.git"
	printf '{"name": "widget-cli", "version": "1.0.0"}\n' >"$REPO_DIR/package.json"
	printf '# Widget\n' >"$REPO_DIR/AGENTS.md"
	cat >"$REPO_DIR/context/target-keywords.md" <<'EOF'
# Target Keywords
## Pillar Topics
### Running shoes
- **Pillar keyword**: running shoes (volume: 12000, difficulty: 64)
- **Cluster keywords**: trail running shoes (vol: 3000), road running shoes (vol: 900)
- **Long-tail variations**: running shoes for flat feet
- **Classic search intent**: commercial
### [Topic Cluster Name]
- **Pillar keyword**: [main keyword] (volume: X, difficulty: Y)
## Current Rankings
| Keyword | Position | URL | Opportunity |
|---|---|---|---|
| running shoes | 14 | https://example.com/running-shoes | striking distance |
EOF
	export AIDEVOPS_KEYWORDS_STORE_DIR="$TEST_ROOT/store"
	export AIDEVOPS_REPOS_FILE="$TEST_ROOT/repos.json"
	export AIDEVOPS_AGENTS_DIR="$TEST_ROOT/no-agents"
	export AIDEVOPS_KEYWORDS_HUB_SLUG=""
	export AIDEVOPS_KEYWORDS_HUB_PATH=""
	return 0
}

test_scaffold_and_migrate() {
	check "scaffold creates strategy and tables" "$HELPER" scaffold "$REPO_DIR" --data tracked
	check "front matter lists detected surfaces" contains "$REPO_DIR/context/keywords.md" "surfaces: [github, npm, ai-answers]"
	check "legacy pillar migrated" contains "$REPO_DIR/context/keywords/targets.toon" "k-0001|running shoes|pillar"
	check "legacy ranking migrated" contains "$REPO_DIR/context/keywords/targets.toon" '"https://example.com/running-shoes"|14'
	check "legacy file kept" test -f "$REPO_DIR/context/target-keywords.md"
	check "AGENTS.md pointer added" contains "$REPO_DIR/AGENTS.md" "context/keywords.md"
	check "registry validates" kw validate
	return 0
}

test_registry_operations() {
	check "score applies priorities" kw score --apply
	kw add modifiers dimension=audience value=beginners applies_to=c-0001 >/dev/null
	kw add modifiers dimension=location value=London >/dev/null
	check "expand stores drill-down candidates" kw expand k-0001 --apply --force
	check "audience pattern applied" contains "$REPO_DIR/context/keywords/targets.toon" "running shoes for beginners"
	check "location pattern applied" contains "$REPO_DIR/context/keywords/targets.toon" "running shoes in London"
	kw add entities name=Widget type=Brand role=self "same_as=https://github.com/example/widget" >/dev/null
	kw add queries "question=What are the best running shoes for flat feet?" cluster_id=c-0001 >/dev/null
	local brief_file="$TEST_ROOT/brief.md"
	kw brief --cluster c-0001 --asset image >"$brief_file"
	check "brief includes image guidance slug" contains "$brief_file" "running-shoes-front-view.webp"
	check "brief includes entity" contains "$brief_file" "Widget (Brand)"
	local duplicate_id
	duplicate_id=$(kw add targets "phrase=Running  Shoes" | jq -r '.id')
	check_fails "duplicate phrase fails validation" kw validate
	kw set targets "$duplicate_id" status=retired >/dev/null
	check "retired duplicate passes validation" kw validate
	return 0
}

test_history_and_budget() {
	local export_file="$TEST_ROOT/gsc-2026-09-01-2026-09-28.toon"
	printf 'domain\texample.com\nsource\tgsc\n---\nquery\tpage\tclicks\timpressions\tctr\tposition\n' >"$export_file"
	printf 'trail running shoes\thttps://example.com/trail\t4\t300\t0.01\t9.4\nunrelated\t/x\t1\t2\t0.5\t50\n' >>"$export_file"
	check "export import writes history" kw track --source export --file "$export_file"
	check "rollup updates positions" kw rollup
	check "rollup wrote last position" contains "$REPO_DIR/context/keywords/targets.toon" "9.4"
	check "index builds" "$HELPER" index
	check "budget within cap" kw budget --estimate 0.5
	check_fails "budget refuses over cap" kw budget --estimate 2
	return 0
}

test_ai_and_routine() {
	local captures="$TEST_ROOT/captures.json"
	cat >"$captures" <<'EOF'
{"captures": [{"capture_id": "c1", "engine": "perplexity", "prompt": "What are the best running shoes for flat feet?",
  "cohort": "baseline", "captured_at": "2026-09-28T10:00:00Z", "status": "complete",
  "answer": "We recommend Widget for flat feet. Source: https://example.com/flat-feet"}]}
EOF
	# Offline front matter: no network surfaces; a cited domain for AI answers.
	python3 - "$REPO_DIR/context/keywords.md" <<'PY'
import re, sys
from pathlib import Path
path = Path(sys.argv[1])
text = re.sub(r"^surfaces: .*$", "surfaces: [ai-answers]", path.read_text(), flags=re.M)
path.write_text(re.sub(r"^domains: .*$", "domains: [example.com]", text, flags=re.M))
PY
	check "AI capture import writes history" kw track --source ai --file "$captures"
	kw rollup >/dev/null
	check "query mention and citation rates rolled up" contains "$REPO_DIR/context/keywords/queries.toon" "1.00|1.00"
	# Routine: registered repo; paid calls impossible without --paid and dataforseo due.
	printf '{"initialized_repos": [{"path": "%s", "slug": "example/widget"}]}\n' "$REPO_DIR" >"$AIDEVOPS_REPOS_FILE"
	check "routine-run completes offline" "$HELPER" routine-run
	check "routine wrote store registry" test -f "$AIDEVOPS_KEYWORDS_STORE_DIR/local/example__widget/keywords/targets.toon"
	return 0
}

test_hub_sync() {
	local bare="$TEST_ROOT/hub.git"
	git init --quiet --bare "$bare"
	git clone --quiet "$bare" "$TEST_ROOT/hub" 2>/dev/null
	git -C "$TEST_ROOT/hub" -c user.email=t@example.com -c user.name=t commit --quiet --allow-empty -m init
	git -C "$TEST_ROOT/hub" push --quiet origin HEAD 2>/dev/null
	git -C "$TEST_ROOT/hub" config user.email t@example.com
	git -C "$TEST_ROOT/hub" config user.name t
	export AIDEVOPS_KEYWORDS_HUB_PATH="$TEST_ROOT/hub"
	check "sync publishes to hub" kw sync
	check "hub has registry" test -f "$TEST_ROOT/hub/example__widget/keywords/targets.toon"
	check "hub has strategy" test -f "$TEST_ROOT/hub/example__widget/keywords.md"
	check "hub pushed to remote" test -n "$(git --git-dir="$bare" log --oneline -1 --grep='keywords: sync')"
	rm -f "$REPO_DIR/context/keywords.md"
	check "sync restores a missing strategy file from the hub" kw sync
	check "strategy file restored" test -f "$REPO_DIR/context/keywords.md"
	printf '\nlocal edit\n' >>"$REPO_DIR/context/keywords.md"
	printf '\nhub edit\n' >>"$TEST_ROOT/hub/example__widget/keywords.md"
	kw sync >/dev/null
	check "divergent edits write a .hub copy" test -f "$REPO_DIR/context/keywords.md.hub"
	check "local edit kept on conflict" contains "$REPO_DIR/context/keywords.md" "local edit"
	export AIDEVOPS_KEYWORDS_HUB_PATH=""
	return 0
}

test_public_repo_ignores_data() {
	local public_repo="$TEST_ROOT/public"
	mkdir -p "$public_repo"
	git -C "$public_repo" init --quiet
	check "scaffold ignored data" "$HELPER" scaffold "$public_repo" --data ignored
	check "gitignore covers registry" contains "$public_repo/.gitignore" "context/keywords/"
	check "git ignores strategy file" git -C "$public_repo" check-ignore -q context/keywords.md
	return 0
}

echo "test-keywords-helper.sh — context/keywords.md registry tests"
echo "============================================================"
setup_repo
test_scaffold_and_migrate
test_registry_operations
test_history_and_budget
test_ai_and_routine
test_hub_sync
test_public_repo_ignores_data
echo ""
echo "Results: $TESTS_RUN tests, $TESTS_FAILED failures"
[[ $TESTS_FAILED -gt 0 ]] && exit 1
exit 0
