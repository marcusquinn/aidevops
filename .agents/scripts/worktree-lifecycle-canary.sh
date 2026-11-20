#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Installed-runtime canary for the managed worktree lifecycle (GH#38658 items).
# Runs INSTALLED scripts in a disposable HOME, bare origin, repo, worktree base,
# archive root and lifecycle state, then prints a redacted Markdown receipt table.
# Production registries are never written; production state is read only for
# the baseline (deployed SHA, script checksums).
#
# Usage: worktree-lifecycle-canary.sh [--installed DIR] [--source DIR]
#        [--budget SECONDS] [--keep]
#   --installed DIR  installed scripts dir (default: ~/.aidevops/agents/scripts)
#   --source DIR     source scripts dir to compare checksums against (default:
#                    this script's own directory when it differs from --installed)
#   --budget N       per-stage timeout in seconds (default: 180); a timeout is
#                    reported as the distinct result `timeout`
#   --keep           keep the disposable root for inspection
set -uo pipefail

ITEM_BASELINE="1 baseline"
ITEM_ADD="3 worktree add"
ITEM_REMOVE="6 remove+restore"
FAIL_RC1="fail (rc=1)"
FAIL_RC_PREFIX="fail (rc="
REAL_HOME="${HOME:-}"
INSTALLED="${REAL_HOME}/.aidevops/agents/scripts"
SOURCE=""
BUDGET=180
KEEP=0
ROWS=()
FAILED=0
D=""
TIMEOUT_BIN=""
LIFECYCLE_FILES=(
	worktree-helper.sh worktree-archive-helper.sh worker-lifecycle-state.sh
	worktree-managed-lifetime.py worktree_lifetime_archive.py
	worktree-lifecycle-helper.sh ../worker-lifecycle/worker-registry.py
)

die() {
	local msg="$1"
	printf 'worktree-lifecycle-canary: %s\n' "$msg" >&2
	return 1
}

parse_args() {
	while [[ $# -gt 0 ]]; do
		local arg="${1:-}"
		case "$arg" in
		--installed) INSTALLED="${2:-}"; shift 2 ;;
		--source) SOURCE="${2:-}"; shift 2 ;;
		--budget) BUDGET="${2:-}"; shift 2 ;;
		--keep) KEEP=1; shift ;;
		-h | --help) sed -n '2,19p' "${BASH_SOURCE[0]}"; exit 0 ;;
		*) die "unknown argument: ${arg}"; exit 2 ;;
		esac
	done
	[[ "$BUDGET" =~ ^[0-9]+$ && "$BUDGET" -gt 0 ]] || { die "--budget must be a positive integer"; exit 2; }
	[[ -f "${INSTALLED}/worktree-helper.sh" ]] || { die "installed scripts not found: ${INSTALLED}"; exit 2; }
	INSTALLED=$(cd "$INSTALLED" && pwd -P) || exit 2
	if [[ -z "$SOURCE" ]]; then
		SOURCE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) || exit 2
	fi
	return 0
}

# Redact the disposable root and the real HOME from anything printed.
redact() {
	local text="$1"
	text="${text//${D:-@@none@@}/<D>}"
	text="${text//${REAL_HOME:-@@none@@}/<HOME>}"
	printf '%s' "$text"
	return 0
}

record() {
	local item="$1" result="$2" receipt="${3:-}"
	receipt=$(redact "$receipt")
	receipt="${receipt//|/\\|}"
	ROWS+=("| ${item} | ${result} | ${receipt} |")
	[[ "$result" == pass || "$result" == unavailable* || "$result" == partial* ]] || FAILED=1
	return 0
}

pick_timeout() {
	local candidate
	for candidate in timeout gtimeout; do
		if command -v "$candidate" >/dev/null 2>&1; then
			TIMEOUT_BIN=$(command -v "$candidate")
			return 0
		fi
	done
	return 0
}

# Run a command under the stage budget. Output goes to $STAGE_OUT; rc 124 = timeout.
run_bounded() {
	local rc=0
	STAGE_OUT=$(
		if [[ -n "$TIMEOUT_BIN" ]]; then
			"$TIMEOUT_BIN" "$BUDGET" "$@" 2>&1
		else
			python3 - "$BUDGET" "$@" <<'PY' 2>&1
import subprocess, sys
try:
    sys.exit(subprocess.run(sys.argv[2:], timeout=int(sys.argv[1])).returncode)
except subprocess.TimeoutExpired:
    sys.exit(124)
PY
		fi
	) || rc=$?
	return "$rc"
}

# stage ITEM RECEIPT_LABEL CMD...: record pass/fail/timeout with the last output line.
stage() {
	local item="$1" label="$2"
	shift 2
	local rc=0 tail_line=""
	run_bounded "$@" || rc=$?
	tail_line=$(printf '%s\n' "$STAGE_OUT" | tail -n 1)
	case "$rc" in
	0) record "$item" pass "${label}: ${tail_line}" ;;
	124) record "$item" timeout "${label}: exceeded ${BUDGET}s" ;;
	*) record "$item" "${FAIL_RC_PREFIX}${rc})" "${label}: ${tail_line}" ;;
	esac
	return "$rc"
}

sha_of() {
	local file="$1"
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$file" | cut -c1-12
	else
		shasum -a 256 "$file" | cut -c1-12
	fi
	return 0
}

stage_baseline() {
	local sha="unavailable" match=0 total=0 file="" a="" b="" anc="no-source-git"
	[[ ! -f "${REAL_HOME}/.aidevops/.deployed-sha" ]] || sha=$(tr -d '[:space:]' <"${REAL_HOME}/.aidevops/.deployed-sha")
	if git -C "$SOURCE" cat-file -e "${sha}^{commit}" 2>/dev/null; then
		anc=not-ancestor
		git -C "$SOURCE" merge-base --is-ancestor "$sha" HEAD 2>/dev/null && anc=ancestor
	fi
	for file in "${LIFECYCLE_FILES[@]}"; do
		total=$((total + 1))
		a="${INSTALLED}/${file}"
		b="${SOURCE}/${file}"
		[[ -f "$a" && -f "$b" ]] || continue
		[[ "$(sha_of "$a")" == "$(sha_of "$b")" ]] && match=$((match + 1))
	done
	if [[ "$INSTALLED" == "$SOURCE" ]]; then
		record "$ITEM_BASELINE" pass "deployed=${sha:0:9} (${anc}); installed == source dir (checksums not independent)"
	elif [[ "$match" -eq "$total" ]]; then
		record "$ITEM_BASELINE" pass "deployed=${sha:0:9} (${anc}); ${match}/${total} lifecycle SHA-256 match source"
	else
		record "$ITEM_BASELINE" "fail (checksum drift)" "deployed=${sha:0:9} (${anc}); ${match}/${total} lifecycle SHA-256 match source"
	fi
	return 0
}

setup_env() {
	local tmp="${TMPDIR:-/tmp}"
	local native_git=""
	# macOS: use the canonical temp root (GH#39524); Git reports canonical paths.
	tmp=$(cd "$tmp" && pwd -P) || return 1
	D=$(mktemp -d "${tmp%/}/wt-canary.XXXXXX") || return 1
	D=$(cd "$D" && pwd -P) || return 1
	# Canonical-checkout guard: never run from a canonical repo.
	cd "$D" || return 1
	# PATH leads with the aidevops git shim; resolve the real binary through the
	# installed runtime-env helper, falling back to the system default PATH.
	if [[ -f "${INSTALLED}/runtime-env.sh" ]]; then
		# shellcheck source=/dev/null
		native_git=$(source "${INSTALLED}/runtime-env.sh" >/dev/null 2>&1 && aidevops_resolve_native_git 2>/dev/null) || native_git=""
	fi
	[[ -n "$native_git" ]] || native_git=$(command -p -v git) || return 1
	export HOME="${D}/home"
	export AIDEVOPS_WORKTREE_BASE_DIR="${D}/worktrees"
	export AIDEVOPS_LIFECYCLE_STATE_DIR="${D}/lifecycle-state"
	export AIDEVOPS_WORKTREE_ARCHIVE_ROOT="${D}/archives"
	export WORKTREE_REGISTRY_DIR="${D}/registry"
	export WORKTREE_REGISTRY_DB="${D}/registry/worktree-registry.db"
	export AIDEVOPS_ADVISORIES_DIR="${D}/advisories"
	export AIDEVOPS_REAL_GIT_BIN="$native_git"
	export GIT_CONFIG_GLOBAL="${D}/gitconfig"
	export GIT_CONFIG_NOSYSTEM=1
	mkdir -p "$HOME/.config/aidevops" "$AIDEVOPS_WORKTREE_BASE_DIR" "$WORKTREE_REGISTRY_DIR" || return 1
	{
		printf '[user]\n\temail = canary@example.invalid\n\tname = Canary\n'
		printf '[commit]\n\tgpgsign = false\n[init]\n\tdefaultBranch = main\n'
		printf '[protocol "file"]\n\tallow = always\n'
	} >"$GIT_CONFIG_GLOBAL"
	"$native_git" init -q --bare "${D}/origin.git" || return 1
	"$native_git" init -q "${D}/repo" || return 1
	printf 'base\n' >"${D}/repo/README.md"
	printf 'a\nb\nc\n' >"${D}/repo/file.txt"
	"$native_git" -C "${D}/repo" add . || return 1
	"$native_git" -C "${D}/repo" commit -q -m init || return 1
	"$native_git" -C "${D}/repo" remote add origin "${D}/origin.git" || return 1
	"$native_git" -C "${D}/repo" push -q origin main || return 1
	"$native_git" -C "${D}/repo" fetch -q origin || return 1
	"$native_git" -C "${D}/repo" branch -q --set-upstream-to=origin/main main || return 1
	printf '{"initialized_repos":[{"slug":"canary/repo","path":"%s"}]}\n' "${D}/repo" \
		>"${HOME}/.config/aidevops/repos.json" || return 1
	GIT="$native_git"
	return 0
}

# Deterministic dirty-state snapshot of a worktree (item 5/6/7 comparison).
snapshot() {
	local wt="$1" gd="" f="" p=""
	gd=$("$GIT" -C "$wt" rev-parse --absolute-git-dir) || return 1
	{
		printf 'HEAD %s\n' "$("$GIT" -C "$wt" rev-parse HEAD)"
		printf 'LOG\n%s\n' "$("$GIT" -C "$wt" log --format=%H -5)"
		printf 'STAGED\n%s\n' "$("$GIT" -C "$wt" diff --cached --binary)"
		printf 'UNSTAGED\n%s\n' "$("$GIT" -C "$wt" diff --binary)"
		printf 'PORCELAIN\n%s\n' "$("$GIT" -C "$wt" status --porcelain=v1 --untracked-files=all)"
		printf 'STAGES\n%s\n' "$("$GIT" -C "$wt" ls-files -s)"
		while IFS= read -r -d '' p; do
			printf 'UNTRACKED %s %s\n' "$p" "$(sha_of "${wt}/${p}")"
		done < <("$GIT" -C "$wt" ls-files --others --exclude-standard -z)
		for f in ORIG_HEAD MERGE_HEAD MERGE_MSG MERGE_MODE AUTO_MERGE; do
			# ORIG_HEAD is preserved only for a merge in progress (archive contract).
			if [[ "$f" == ORIG_HEAD && ! -f "${gd}/MERGE_HEAD" ]]; then
				printf 'ORIG_HEAD not-compared\n'
			elif [[ -f "${gd}/${f}" ]]; then
				printf '%s %s\n' "$f" "$(sha_of "${gd}/${f}")"
			else
				printf '%s absent\n' "$f"
			fi
		done
	}
	return 0
}

archive_dir_for() {
	local manifest
	manifest=$(find "$AIDEVOPS_WORKTREE_ARCHIVE_ROOT" -name manifest.json 2>/dev/null | sort | tail -n 1)
	[[ -n "$manifest" ]] || return 1
	dirname "$manifest"
	return 0
}

make_dirty() {
	local wt="$1"
	printf 'staged\n' >"${wt}/staged.txt"
	"$GIT" -C "$wt" add staged.txt
	printf 'a\nB-unstaged\nc\n' >"${wt}/file.txt"
	printf 'untracked content\n' >"${wt}/untracked.txt"
	return 0
}

archive_cycle() {
	local item="$1" wt="$2" want_source_matches="$3" arch="" before="" after="" restored="" rc=0
	before=$(snapshot "$wt") || { record "$item" "$FAIL_RC1" "snapshot before"; return 1; }
	run_bounded "${INSTALLED}/worktree-archive-helper.sh" archive "$wt" --repo canary/repo \
		--unattributed --reason unattributed-worktree --base-branch main || rc=$?
	if [[ "$rc" -ne 0 ]]; then
		[[ "$rc" -eq 124 ]] && record "$item" timeout "archive exceeded ${BUDGET}s" ||
			record "$item" "${FAIL_RC_PREFIX}${rc})" "archive: $(printf '%s\n' "$STAGE_OUT" | tail -n 1)"
		return 1
	fi
	arch=$(archive_dir_for) || { record "$item" "$FAIL_RC1" "no archive manifest"; return 1; }
	if [[ "$want_source_matches" == 1 ]]; then
		run_bounded "${INSTALLED}/worktree-archive-helper.sh" source-matches "$arch" "$wt" ||
			{ record "$item" "fail (source-matches)" "$(printf '%s\n' "$STAGE_OUT" | tail -n 1)"; return 1; }
	fi
	# Restore targets must sit under the managed worktree base.
	restored="${AIDEVOPS_WORKTREE_BASE_DIR}/restore-${item%% *}"
	run_bounded "${INSTALLED}/worktree-archive-helper.sh" restore "$arch" --target "$restored" || rc=$?
	if [[ "$rc" -ne 0 ]]; then
		[[ "$rc" -eq 124 ]] && record "$item" timeout "restore exceeded ${BUDGET}s" ||
			record "$item" "${FAIL_RC_PREFIX}${rc})" "restore: $(printf '%s\n' "$STAGE_OUT" | tail -n 1)"
		return 1
	fi
	after=$(snapshot "$restored") || { record "$item" "$FAIL_RC1" "snapshot after"; return 1; }
	if [[ "$before" == "$after" ]]; then
		record "$item" pass "snapshot identical; archive=$(basename "$arch"); source-matches=${want_source_matches}"
	else
		record "$item" "fail (snapshot diff)" "$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | head -n 3 | tr '\n' ' ')"
		return 1
	fi
	return 0
}

stage_lifecycle() {
	local wt="${AIDEVOPS_WORKTREE_BASE_DIR}/canary-main" rc=0 arch="" run_pid="" run_out=""
	local registry="${INSTALLED}/../worker-lifecycle/worker-registry.py"
	cd "${D}/repo" || return 1

	# 2 disposable env
	record "2 disposable env" pass "HOME, worktree base, state, archive root, registry and repos.json under <D>"

	# 3 add -> generation and backend row
	if run_bounded "${INSTALLED}/worktree-helper.sh" add feature/canary "$wt" --base main; then
		record "$ITEM_ADD" pass "created; $(printf '%s\n' "$STAGE_OUT" | tail -n 1)"
	else
		rc=$?
		[[ "$rc" -eq 124 ]] && record "$ITEM_ADD" timeout "exceeded ${BUDGET}s" ||
			record "$ITEM_ADD" "${FAIL_RC_PREFIX}${rc})" "$(printf '%s\n' "$STAGE_OUT" | tail -n 1)"
		return 1
	fi

	# 4 bounded command recorded as a run with PID, start token and boot id
	run_bounded bash "${INSTALLED}/worker-lifecycle-state.sh" sleep 1 || rc=$?
	run_out=$(python3 -E -s -B "$registry" --state-dir "$AIDEVOPS_LIFECYCLE_STATE_DIR" status 2>&1) || true
	if [[ "$rc" -eq 0 && "$run_out" == *run* ]]; then
		record "4 launch identity" pass "run recorded: $(printf '%s' "$run_out" | tr -d '\n' | cut -c1-160)"
	else
		record "4 launch identity" "${FAIL_RC_PREFIX}${rc})" "$(printf '%s' "$run_out" | tr -d '\n' | cut -c1-160)"
	fi
	rc=0

	# 5 reconcile -> ended
	run_out=$(python3 -E -s -B "$registry" --state-dir "$AIDEVOPS_LIFECYCLE_STATE_DIR" reconcile 2>&1) || rc=$?
	if [[ "$rc" -eq 0 ]]; then
		record "5 reconcile" pass "$(printf '%s' "$run_out" | tr -d '\n' | cut -c1-160)"
	else
		record "5 reconcile" "${FAIL_RC_PREFIX}${rc})" "$(printf '%s' "$run_out" | tr -d '\n' | cut -c1-160)"
	fi
	rc=0

	# 6 dirty snapshot -> guarded removal -> archive receipt -> verify -> restore -> diff
	make_dirty "$wt"
	local before after
	before=$(snapshot "$wt") || return 1
	run_bounded "${INSTALLED}/worktree-helper.sh" remove "$wt" || rc=$?
	if [[ "$rc" -ne 0 ]]; then
		[[ "$rc" -eq 124 ]] && record "$ITEM_REMOVE" timeout "remove exceeded ${BUDGET}s" ||
			record "$ITEM_REMOVE" "${FAIL_RC_PREFIX}${rc})" "remove: $(printf '%s\n' "$STAGE_OUT" | tail -n 1)"
		return 1
	fi
	arch=$(archive_dir_for) || { record "$ITEM_REMOVE" "$FAIL_RC1" "no archive receipt after remove"; return 1; }
	local v
	for v in verify-structure verify-local verify; do
		stage "6 ${v}" "$v" "${INSTALLED}/worktree-archive-helper.sh" "$v" "$arch" || true
	done
	if run_bounded "${INSTALLED}/worktree-archive-helper.sh" restore "$arch" --target "${AIDEVOPS_WORKTREE_BASE_DIR}/restore-6"; then
		after=$(snapshot "${AIDEVOPS_WORKTREE_BASE_DIR}/restore-6")
		if [[ "$before" == "$after" ]]; then
			record "$ITEM_REMOVE" pass "source retired (exists=$([[ -d "$wt" ]] && echo yes || echo no)); restore snapshot identical; archive=$(basename "$arch")"
		else
			record "$ITEM_REMOVE" "fail (snapshot diff)" "$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | head -n 3 | tr '\n' ' ')"
		fi
	else
		rc=$?
		[[ "$rc" -eq 124 ]] && record "$ITEM_REMOVE" timeout "restore exceeded ${BUDGET}s" ||
			record "$ITEM_REMOVE" "${FAIL_RC_PREFIX}${rc})" "restore: $(printf '%s\n' "$STAGE_OUT" | tail -n 3 | tr '\n' ' ')"
	fi
	return 0
}

stage_merge_cases() {
	local wt="${D}/merge-wt"
	cd "${D}/repo" || return 1
	"$GIT" worktree add -q -b canary/ours "$wt" main || return 1
	printf 'ours\n' >"${wt}/file.txt"
	"$GIT" -C "$wt" commit -qam ours || return 1
	"$GIT" worktree add -q -b canary/theirs "${D}/theirs-wt" main || return 1
	printf 'theirs\n' >"${D}/theirs-wt/file.txt"
	"$GIT" -C "${D}/theirs-wt" commit -qam theirs || return 1
	"$GIT" -C "$wt" merge --no-edit canary/theirs >/dev/null 2>&1 || true
	if [[ -z "$("$GIT" -C "$wt" ls-files -u)" ]]; then
		record "7 interrupted merge" "fail (setup)" "merge did not conflict"
		return 1
	fi
	archive_cycle "7 interrupted merge" "$wt" 1 || true
	# Standalone AUTO_MERGE: abort the merge, then write AUTO_MERGE from merge-tree.
	"$GIT" -C "$wt" merge --abort >/dev/null 2>&1 || "$GIT" -C "$wt" reset -q --hard HEAD
	local tree gd
	# merge-tree exits 1 on conflicts but still prints the (conflicted) tree first.
	tree=$("$GIT" -C "$wt" merge-tree --write-tree canary/ours canary/theirs 2>/dev/null | head -n 1) || true
	[[ "$tree" =~ ^[0-9a-f]{40,64}$ ]] || tree=""
	gd=$("$GIT" -C "$wt" rev-parse --absolute-git-dir)
	if [[ -n "$tree" ]]; then
		# Standalone: no merge in progress, so no leftover ORIG_HEAD from the abort.
		rm -f "${gd}/ORIG_HEAD" "${gd}/MERGE_HEAD" "${gd}/MERGE_MSG" "${gd}/MERGE_MODE"
		printf '%s\n' "$tree" >"${gd}/AUTO_MERGE"
		archive_cycle "8 standalone AUTO_MERGE" "$wt" 1 || true
	else
		record "8 standalone AUTO_MERGE" "fail (setup)" "git merge-tree produced no tree"
	fi
	return 0
}

# Count sealed and restore-verified rows in the disposable SQLite stores (read-only).
scan_seals() {
	python3 - "$D" <<'PY'
import os, sqlite3, sys
seal = idle = bound = 0
for root, _, files in os.walk(sys.argv[1]):
    for name in files:
        if not name.endswith((".db", ".sqlite", ".sqlite3")):
            continue
        try:
            con = sqlite3.connect("file:%s?mode=ro" % os.path.join(root, name), uri=True)
            for (table,) in con.execute("select name from sqlite_master where type='table'").fetchall():
                for row in con.execute('select * from "%s"' % table.replace('"', "")):
                    text = " ".join(str(v).lower() for v in row)
                    seal += "sealed" in text
                    idle += "restore-verified" in text
                    bound += '"launches": [{' in text
        except sqlite3.Error:
            pass
print("launch_bound_rows=%d sealed_rows=%d restore_verified_rows=%d" % (bound, seal, idle))
PY
	return 0
}

stage_platform() {
	local item="9 managed seal + restore-verified idle receipt" hits="" run_note=""
	case "$(uname -s)" in
	Linux)
		local swt="${AIDEVOPS_WORKTREE_BASE_DIR}/canary-seal" runner="${INSTALLED}/worktree-managed-run.py"
		if ! python3 "$runner" --check-backend >/dev/null 2>&1; then
			record "$item" "unavailable (no rootless managed-lifetime backend)" "worktree-managed-run.py --check-backend"
			return 0
		fi
		cd "${D}/repo" || return 1
		run_bounded "${INSTALLED}/worktree-helper.sh" add feature/canary-seal "$swt" --base main || true
		if [[ -d "$swt" ]]; then
			cd "$swt" || return 1
			run_bounded python3 "$runner" --timeout-seconds "$BUDGET" --after true -- true || run_note="managed-run rc=$?: $(printf '%s\n' "$STAGE_OUT" | tail -n 1)"
			cd "${D}/repo" || return 1
		fi
		hits=$(scan_seals) || hits="sealed_rows=0 (scan failed)"
		if [[ "$hits" == *"launch_bound_rows=0"* ]]; then
			record "$item" "fail (no managed launch bound)" "${hits} ${run_note}"
		elif [[ "$hits" == *"sealed_rows=0"* ]]; then
			# Launch bound but not sealed: reported, never promoted to pass.
			record "$item" "partial (launch bound, not sealed)" "${hits} ${run_note}"
		else
			# The idle receipt needs a >=24h idle authorization: zero is expected here.
			record "$item" pass "${hits} (idle receipt needs >=24h idle)"
		fi
		;;
	*) record "9 managed seal + restore-verified idle receipt" "unavailable (Linux-only, GH#39513)" "$(uname -s)" ;;
	esac
	return 0
}

cleanup() {
	cd / || true
	if [[ -n "$D" && -d "$D" && "$KEEP" -eq 0 ]]; then
		rm -rf "$D"
	fi
	return 0
}

main() {
	parse_args "$@"
	pick_timeout
	stage_baseline
	trap cleanup EXIT
	if ! setup_env; then
		record "2 disposable env" "$FAIL_RC1" "setup failed"
	else
		stage_lifecycle || true
		stage_merge_cases || true
		stage_platform
	fi
	printf '| Item | Result | Receipt |\n|---|---|---|\n'
	printf '%s\n' "${ROWS[@]}"
	[[ "$KEEP" -eq 0 ]] || printf '\nkept: <D> (disposable root)\n'
	return "$FAILED"
}

main "$@"
