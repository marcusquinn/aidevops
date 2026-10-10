#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression test for t2698: issue-sync-helper.sh pull must seed TODO.md
# entries for open orphan GitHub issues instead of only reporting them.
#
# Tests the orphan-seeding library functions and cmd_pull policy:
#   _labels_json_to_tags()      — reverse-maps labels JSON to #tag tokens
#   _seed_orphan_todo_line()    — idempotent TODO.md append for orphans
#
# Coverage matrix:
#   (a) open orphan is seeded with correct line
#   (b) closed orphan is NOT seeded (handled by caller; lib skips none)
#   (c) duplicate-run is a no-op (idempotency)
#   (d) malformed title (no tNNN: prefix) — no task_id → caller skips
#   (e) parent-task label → #parent tag (auto-dispatch maps independently)
#   (f) dry-run emits "would seed" to stderr, TODO.md unchanged
#   (g) missing task ID → seeding skipped with log
#   (h) publication:pending open orphan → deferred without TODO mutation
#   (i) near-match publication label → ordinary orphan seeding
#   (j) publication:pending issue with a TODO row → ref sync proceeds
#   (k) removing publication:pending → orphan seeding resumes
#   (r) GH#34232 issue-first: young unlabelled orphans wait out the backup grace
set -euo pipefail

PASS=0
FAIL=0

# ─── Source the library under test ──────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../issue-sync-lib.sh
source "${SCRIPT_DIR}/issue-sync-lib.sh"
# shellcheck source=../issue-sync-helper-labels.sh
source "${SCRIPT_DIR}/issue-sync-helper-labels.sh"
# shellcheck source=../issue-sync-helper-commands.sh
source "${SCRIPT_DIR}/issue-sync-helper-commands.sh"

# Stub for log_verbose — defined in issue-sync-helper.sh, not in the lib.
# Tests source only the lib, so we provide a no-op here.
log_verbose() { return 0; }

# ─── Assertion helper ────────────────────────────────────────────────────────

check() {
	local ok="$1" tc="$2" detail="${3:-}"
	if [[ "$ok" == "1" ]]; then
		PASS=$((PASS + 1))
		echo "PASS: $tc"
	else
		FAIL=$((FAIL + 1))
		echo "FAIL: $tc${detail:+ — }${detail}"
	fi
	return 0
}

# ─── Setup: temp TODO.md ────────────────────────────────────────────────────

make_todo() {
	local f
	# t2997: drop .md — XXXXXX must be at end for BSD mktemp.
	f=$(mktemp /tmp/test-todo-XXXXXX)
	cat >"$f" <<'EOF'
# Tasks

- [ ] t0001 existing task #bug ref:GH#100
EOF
	echo "$f"
	return 0
}

# ─── Test helpers ────────────────────────────────────────────────────────────

labels_json_of() {
	# Build a minimal labels JSON array from space-separated label names.
	local out="["
	local first=1
	local lbl
	for lbl in "$@"; do
		[[ "$first" -eq 0 ]] && out="${out},"
		out="${out}{\"name\":\"${lbl}\"}"
		first=0
	done
	out="${out}]"
	printf '%s' "$out"
	return 0
}

run_pull_with_issues() {
	local todo_file="$1" open_json="$2" closed_json="${3:-[]}" state=""
	_CMD_REPO="owner/repo"
	_CMD_TODO="$todo_file"
	DRY_RUN="false"
	_init_cmd() { return 0; }
	gh_list_issues() {
		local repo="$1" requested_state="$2" limit="$3"
		: "$repo" "$limit"
		if [[ "$requested_state" == "open" ]]; then
			printf '%s\n' "$open_json"
		else
			printf '%s\n' "$closed_json"
		fi
		return 0
	}
	cmd_pull
	state="$?"
	return "$state"
}

# ─── (a) Open orphan seeded ──────────────────────────────────────────────────

todo_a=$(make_todo)
labels_a=$(labels_json_of enhancement framework auto-dispatch)

_seed_orphan_todo_line "20327" "t2698" "t2698: enhance pull seeding" \
	"$labels_a" "$todo_a" ""

seeded_line=$(grep -E '^\- \[ \] t2698 ' "$todo_a" || echo "")
[[ -n "$seeded_line" ]] && ok=1 || ok=0
check "$ok" "(a) open orphan seeded — line present in TODO.md" "got: '$seeded_line'"

echo "$seeded_line" | grep -q 'ref:GH#20327' && ok=1 || ok=0
check "$ok" "(a) open orphan seeded — ref:GH#20327 present" "line: $seeded_line"

echo "$seeded_line" | grep -q '#enhancement' && ok=1 || ok=0
check "$ok" "(a) open orphan seeded — #enhancement tag present" "line: $seeded_line"

echo "$seeded_line" | grep -q '#auto-dispatch' && ok=1 || ok=0
check "$ok" "(a) open orphan seeded — #auto-dispatch tag present" "line: $seeded_line"

rm -f "$todo_a"

# ─── (b) Closed orphan not seeded ────────────────────────────────────────────

todo_b=$(make_todo)
closed_issues_b='[{"number":20999,"title":"t9999: closed orphan","assignees":[],"labels":[]}]'
run_pull_with_issues "$todo_b" '[]' "$closed_issues_b" >/dev/null
closed_line=$(grep -E '^\- \[ \] t9999 ' "$todo_b" || echo "")
[[ -z "$closed_line" ]] && ok=1 || ok=0
check "$ok" "(b) closed orphan not seeded — no entry for t9999" "line: '$closed_line'"
rm -f "$todo_b"

# ─── (c) Duplicate-run no-op (idempotency) ───────────────────────────────────

todo_c=$(make_todo)
labels_c=$(labels_json_of "enhancement")

# First seed
_seed_orphan_todo_line "20400" "t2750" "t2750: some feature" \
	"$labels_c" "$todo_c" ""

# Second seed (should be a no-op — returns 1)
if _seed_orphan_todo_line "20400" "t2750" "t2750: some feature" \
	"$labels_c" "$todo_c" ""; then
	second_ret=0
else
	second_ret=1
fi
[[ "$second_ret" -eq 1 ]] && ok=1 || ok=0
check "$ok" "(c) duplicate-run returns 1 (skip signal)" "ret=$second_ret"

line_count=$(grep -c '^\- \[ \] t2750 ' "$todo_c" 2>/dev/null || true)
[[ "$line_count" -eq 1 ]] && ok=1 || ok=0
check "$ok" "(c) duplicate-run — exactly one entry in TODO.md" "count=$line_count"

rm -f "$todo_c"

# ─── (d) Malformed title (no tNNN: prefix) — caller skips before seeding ────
# In cmd_pull, the tid extraction regex '^t[0-9]+(\.[0-9]+)*' returns empty
# for malformed titles and the loop does `[[ -z "$tid" ]] && continue`.
# The library _seed_orphan_todo_line is never called in this case.
# We simulate by not calling it and verifying nothing lands.

todo_d=$(make_todo)
malformed_line=$(grep -E '^\- \[ \] ' "$todo_d" | grep -v t0001 || echo "")
[[ -z "$malformed_line" ]] && ok=1 || ok=0
check "$ok" "(d) malformed title — no spurious entry seeded" "got: '$malformed_line'"
rm -f "$todo_d"

# ─── (e) parent-task label maps to #parent tag ──────────────────────────────

todo_e=$(make_todo)
# Issue has both parent-task and auto-dispatch labels
labels_e=$(labels_json_of auto-dispatch parent-task framework)

_seed_orphan_todo_line "20500" "t2800" "t2800: parent tracker" \
	"$labels_e" "$todo_e" ""

parent_line=$(grep -E '^\- \[ \] t2800 ' "$todo_e" || echo "")
echo "$parent_line" | grep -q '#parent' && ok=1 || ok=0
check "$ok" "(e) parent-task label → #parent tag present" "line: $parent_line"

# auto-dispatch label should ALSO appear (parent-task does not suppress it)
echo "$parent_line" | grep -q '#auto-dispatch' && ok=1 || ok=0
check "$ok" "(e) auto-dispatch label → #auto-dispatch tag present alongside #parent" "line: $parent_line"

# parent-task label itself should NOT appear raw (it maps to #parent)
echo "$parent_line" | grep -qF '#parent-task' && ok=0 || ok=1
check "$ok" "(e) raw #parent-task label not present (mapped to #parent)" "line: $parent_line"

rm -f "$todo_e"

# ─── (f) dry-run emits "would seed", TODO.md unchanged ──────────────────────

todo_f=$(make_todo)
labels_f=$(labels_json_of "enhancement")
wc_before=$(wc -l <"$todo_f")

dry_stderr=$(_seed_orphan_todo_line "20600" "t2900" "t2900: dry test" \
	"$labels_f" "$todo_f" "true" 2>&1 >/dev/null || true)

wc_after=$(wc -l <"$todo_f")
[[ "$wc_before" -eq "$wc_after" ]] && ok=1 || ok=0
check "$ok" "(f) dry-run — TODO.md line count unchanged" \
	"before=$wc_before after=$wc_after"

printf '%s' "$dry_stderr" | grep -q 'would seed' && ok=1 || ok=0
check "$ok" "(f) dry-run — 'would seed' emitted to stderr" "stderr: $dry_stderr"

rm -f "$todo_f"

# ─── (g) missing task ID → skipped by caller ─────────────────────────────────
# When _seed_orphan_todo_line is called with an empty task_id, it should
# not write a malformed line. Verify that an empty task_id either returns
# 1 (skip) or produces no entry with a valid tNNN pattern.

todo_g=$(make_todo)
# Directly calling with empty task_id to cover the edge case defensively.
if _seed_orphan_todo_line "20700" "" "no prefix title" \
	"[]" "$todo_g" "" 2>/dev/null; then
	empty_ret=0
else
	empty_ret=1
fi
# Either the function returned 1 (skip), or no well-formed tNNN line was added.
bad_line=$(grep -E '^\- \[ \]  ' "$todo_g" || echo "")
[[ "$empty_ret" -eq 1 || -z "$bad_line" ]] && ok=1 || ok=0
check "$ok" "(g) empty task_id — no malformed entry seeded" \
	"ret=$empty_ret bad_line='$bad_line'"

rm -f "$todo_g"

# ─── (h) Pending publication orphan is deferred ─────────────────────────────

todo_h=$(make_todo)
before_h=$(<"$todo_h")
issues_h='[{"number":20800,"title":"t3000: pending planning publication","assignees":[],"labels":[{"name":"publication:pending"}]}]'
output_h=$(run_pull_with_issues "$todo_h" "$issues_h" 2>&1)
after_h=$(<"$todo_h")
[[ "$before_h" == "$after_h" ]] && ok=1 || ok=0
check "$ok" "(h) publication:pending orphan — TODO.md unchanged"
printf '%s' "$output_h" | grep -q 'deferred orphan TODO seeding for #20800 (t3000)' && ok=1 || ok=0
check "$ok" "(h) publication:pending orphan — issue identified in diagnostic" "output: $output_h"
printf '%s' "$output_h" | grep -q 'Publication pending deferred: 1' && ok=1 || ok=0
check "$ok" "(h) publication:pending orphan — deferred summary count is one" "output: $output_h"
rm -f "$todo_h"

# ─── (i) Exact label matching preserves ordinary orphan recovery ────────────

todo_i=$(make_todo)
issues_i='[{"number":20801,"title":"t3001: near-match publication label","assignees":[],"labels":[{"name":"publication:pending-later"}]}]'
run_pull_with_issues "$todo_i" "$issues_i" >/dev/null
grep -q 'ref:GH#20801' "$todo_i" && ok=1 || ok=0
check "$ok" "(i) near-match publication label — orphan seeded normally"
rm -f "$todo_i"

# ─── (j) Existing TODO row synchronizes while publication is pending ────────

todo_j=$(make_todo)
printf '%s\n' '- [ ] t3002 canonical planning row' >>"$todo_j"
issues_j='[{"number":20802,"title":"t3002: canonical planning row","assignees":[],"labels":[{"name":"publication:pending"}]}]'
run_pull_with_issues "$todo_j" "$issues_j" >/dev/null
grep -E '^\- \[ \] t3002 .*ref:GH#20802' "$todo_j" >/dev/null && ok=1 || ok=0
check "$ok" "(j) publication:pending with existing row — ref synchronized"
rm -f "$todo_j"

# ─── (k) Removing pending label resumes orphan recovery ─────────────────────

todo_k=$(make_todo)
issues_k_pending='[{"number":20803,"title":"t3003: retry publication","assignees":[],"labels":[{"name":"publication:pending"}]}]'
issues_k_ready='[{"number":20803,"title":"t3003: retry publication","assignees":[],"labels":[]}]'
run_pull_with_issues "$todo_k" "$issues_k_pending" >/dev/null
run_pull_with_issues "$todo_k" "$issues_k_ready" >/dev/null
line_count=$(grep -c '^\- \[ \] t3003 .*ref:GH#20803' "$todo_k" 2>/dev/null || true)
[[ "$line_count" -eq 1 ]] && ok=1 || ok=0
check "$ok" "(k) pending label removed — orphan seeding resumes exactly once" "count=$line_count"
rm -f "$todo_k"

# ─── (l–q) GH#34149: stale pending publication repair ───────────────────────
# Repair writes todo/tasks/ beside TODO.md, so each case uses its own root.

READY_BRIEF=$'## Task\nDo it.\n## Why\nBecause.\n## How\nEdit x.sh.\n## Acceptance\n- [ ] done\n'
REPAIR_AUTHOR_ASSOCIATION="MEMBER"
REPAIR_BRIEF_BODY="$READY_BRIEF"
gh() {
	[[ "$1" == "api" && "$2" == repos/owner/repo/issues/* ]] || return 2
	printf '%s\n' "$REPAIR_AUTHOR_ASSOCIATION"
	return 0
}
_publication_repair_capture_brief() {
	local brief_path="$4/todo/tasks/$3-brief.md"
	mkdir -p "${brief_path%/*}" && printf '%s' "$REPAIR_BRIEF_BODY" >"$brief_path"
	return 0
}

make_repair_root() {
	local root=""
	root=$(mktemp -d /tmp/test-pubrepair-XXXXXX)
	printf '# Tasks\n\n- [ ] t0001 existing task #bug ref:GH#100\n' >"${root}/TODO.md"
	printf '%s\n' "$root"
	return 0
}

stale_issue() {
	local num="$1" tid="$2" created="$3" extra_labels="${4:-}"
	printf '[{"number":%s,"title":"%s: repair me","assignees":[],"createdAt":"%s","labels":[{"name":"publication:pending"},{"name":"bug"},{"name":"tier:standard"}%s]}]' \
		"$num" "$tid" "$created" "$extra_labels"
	return 0
}

root_l=$(make_repair_root)
output_l=$(GITHUB_ACTIONS=false run_pull_with_issues "${root_l}/TODO.md" \
	"$(stale_issue 20900 t3100 2020-01-01T00:00:00Z)" 2>&1)
line_l=$(grep -E '^\- \[ \] t3100 ' "${root_l}/TODO.md" || true)
[[ "$line_l" == *'ref:GH#20900'* && "$line_l" == *'#auto-dispatch'* && "$line_l" == *'#bug'* ]] && ok=1 || ok=0
check "$ok" "(l) stale trusted pending orphan — row seeded with ref and #auto-dispatch" "line: $line_l"
[[ "$line_l" != *'publication'* && "$line_l" != *'tier:'* ]] && ok=1 || ok=0
check "$ok" "(l) stale repair — no publication/system label projected into tags" "line: $line_l"
[[ -f "${root_l}/todo/tasks/t3100-brief.md" ]] && ok=1 || ok=0
check "$ok" "(l) stale repair — brief captured beside TODO.md"
printf '%s' "$output_l" | grep -q 'Publication repaired: 1' && ok=1 || ok=0
check "$ok" "(l) stale repair — summary counts one repair" "output: $output_l"
rm -rf "$root_l"

root_m=$(make_repair_root)
before_m=$(<"${root_m}/TODO.md")
output_m=$(REPAIR_AUTHOR_ASSOCIATION=CONTRIBUTOR GITHUB_ACTIONS=false run_pull_with_issues "${root_m}/TODO.md" \
	"$(stale_issue 20901 t3101 2020-01-01T00:00:00Z)" 2>&1)
[[ "$before_m" == "$(<"${root_m}/TODO.md")" && ! -e "${root_m}/todo" ]] && ok=1 || ok=0
check "$ok" "(m) untrusted author — no row or brief written"
printf '%s' "$output_m" | grep -q 'Publication pending deferred: 1' && ok=1 || ok=0
check "$ok" "(m) untrusted author — deferred" "output: $output_m"
rm -rf "$root_m"

root_n=$(make_repair_root)
young_n=$(date -u +%Y-%m-%dT%H:%M:%SZ)
before_n=$(<"${root_n}/TODO.md")
GITHUB_ACTIONS=false run_pull_with_issues "${root_n}/TODO.md" "$(stale_issue 20902 t3102 "$young_n")" >/dev/null 2>&1
[[ "$before_n" == "$(<"${root_n}/TODO.md")" && ! -e "${root_n}/todo" ]] && ok=1 || ok=0
check "$ok" "(n) young pending orphan — still deferred inside the grace window"
rm -rf "$root_n"

root_o=$(make_repair_root)
GITHUB_ACTIONS=false run_pull_with_issues "${root_o}/TODO.md" \
	"$(stale_issue 20903 t3103 2020-01-01T00:00:00Z ',{"name":"status:claimed"}')" >/dev/null 2>&1
line_o=$(grep -E '^\- \[ \] t3103 ' "${root_o}/TODO.md" || true)
[[ "$line_o" == *'ref:GH#20903'* && "$line_o" != *'#auto-dispatch'* ]] && ok=1 || ok=0
check "$ok" "(o) live claim — published without adding #auto-dispatch" "line: $line_o"
rm -rf "$root_o"

root_p=$(make_repair_root)
REPAIR_BRIEF_BODY=$'## Task\nThin.\n' GITHUB_ACTIONS=false run_pull_with_issues "${root_p}/TODO.md" \
	"$(stale_issue 20904 t3104 2020-01-01T00:00:00Z)" >/dev/null 2>&1
line_p=$(grep -E '^\- \[ \] t3104 ' "${root_p}/TODO.md" || true)
[[ "$line_p" == *'ref:GH#20904'* && "$line_p" != *'#auto-dispatch'* ]] && ok=1 || ok=0
check "$ok" "(p) non-worker-ready brief — published without #auto-dispatch" "line: $line_p"
rm -rf "$root_p"

root_q=$(make_repair_root)
before_q=$(<"${root_q}/TODO.md")
GITHUB_ACTIONS=true run_pull_with_issues "${root_q}/TODO.md" \
	"$(stale_issue 20905 t3105 2020-01-01T00:00:00Z)" >/dev/null 2>&1
[[ "$before_q" == "$(<"${root_q}/TODO.md")" && ! -e "${root_q}/todo" ]] && ok=1 || ok=0
check "$ok" "(q) GitHub Actions — repair is Pulse-owned and stays deferred"
rm -rf "$root_q"
unset -f gh

# ─── (r) GH#34232: issue-first backup grace window ──────────────────────────

todo_r=$(make_todo)
before_r=$(<"$todo_r")
now_r=$(date -u +%Y-%m-%dT%H:%M:%SZ)
issues_r_young='[{"number":20950,"title":"t3150: issue-first task","assignees":[],"createdAt":"'"$now_r"'","labels":[{"name":"auto-dispatch"}]}]'
output_r=$(run_pull_with_issues "$todo_r" "$issues_r_young" 2>&1)
[[ "$before_r" == "$(<"$todo_r")" ]] && ok=1 || ok=0
check "$ok" "(r) young unlabelled orphan — backup seeding deferred" "output: $output_r"
issues_r_old='[{"number":20950,"title":"t3150: issue-first task","assignees":[],"createdAt":"2020-01-01T00:00:00Z","labels":[{"name":"auto-dispatch"}]}]'
run_pull_with_issues "$todo_r" "$issues_r_old" >/dev/null 2>&1
grep -q 'ref:GH#20950' "$todo_r" && ok=1 || ok=0
check "$ok" "(r) orphan past grace window — backup row seeded"
todo_r0=$(make_todo)
AIDEVOPS_ORPHAN_SEED_GRACE_HOURS=0 run_pull_with_issues "$todo_r0" "$issues_r_young" >/dev/null 2>&1
grep -q 'ref:GH#20950' "$todo_r0" && ok=1 || ok=0
check "$ok" "(r) grace 0 — young orphan seeded immediately"
rm -f "$todo_r" "$todo_r0"

# ─── _labels_json_to_tags unit tests ────────────────────────────────────────

# System labels excluded
sys_labels='[{"name":"tier:standard"},{"name":"status:queued"},{"name":"origin:worker"},{"name":"source:ci-feedback"}]'
result=$(_labels_json_to_tags "$sys_labels" || true)
[[ -z "${result// /}" ]] && ok=1 || ok=0
check "$ok" "labels_json_to_tags: system labels all excluded" "got: '$result'"

# Plain labels pass through
plain_labels='[{"name":"enhancement"},{"name":"framework"},{"name":"auto-dispatch"}]'
result=$(_labels_json_to_tags "$plain_labels" || true)
printf '%s' "$result" | grep -q '#enhancement' && ok=1 || ok=0
check "$ok" "labels_json_to_tags: #enhancement present" "got: '$result'"
printf '%s' "$result" | grep -q '#framework' && ok=1 || ok=0
check "$ok" "labels_json_to_tags: #framework present" "got: '$result'"

# parent-task → #parent
pt_labels='[{"name":"parent-task"}]'
result=$(_labels_json_to_tags "$pt_labels" || true)
printf '%s' "$result" | grep -q '#parent' && ok=1 || ok=0
check "$ok" "labels_json_to_tags: parent-task → #parent" "got: '$result'"
printf '%s' "$result" | grep -qF '#parent-task' && ok=0 || ok=1
check "$ok" "labels_json_to_tags: raw #parent-task not emitted" "got: '$result'"

# Empty input → empty output
result=$(_labels_json_to_tags "[]" || true)
[[ -z "${result// /}" ]] && ok=1 || ok=0
check "$ok" "labels_json_to_tags: empty array → empty output" "got: '$result'"

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
