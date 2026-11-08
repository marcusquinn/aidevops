#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../worktree-archive-helper.sh"
TEST_ROOT="$(mktemp -d)"
export WORKTREE_REGISTRY_DIR="${TEST_ROOT}/registry"
export WORKTREE_REGISTRY_DB="${WORKTREE_REGISTRY_DIR}/worktree-registry.db"
export AIDEVOPS_WORKTREE_BASE_DIR="$TEST_ROOT"
TESTS_RUN=0
TESTS_FAILED=0

cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

result() {
	local name="$1"
	local rc="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
	else
		printf 'FAIL %s\n' "$name"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

setup_repo() {
	local name="$1"
	local bare="$TEST_ROOT/${name}.git"
	local canonical="$TEST_ROOT/${name}-canonical"
	local worktree="$TEST_ROOT/${name}-worktree"
	git init -q --bare "$bare" || return 1
	git clone -q "$bare" "$canonical" || return 1
	git -C "$canonical" config user.email test@example.invalid || return 1
	git -C "$canonical" config user.name Test || return 1
	git -C "$canonical" config commit.gpgsign false || return 1
	git -C "$canonical" checkout -q -b main || return 1
	printf 'base\n' >"$canonical/file.txt"
	git -C "$canonical" add file.txt || return 1
	git -C "$canonical" commit -q -m base || return 1
	git -C "$canonical" push -q -u origin main || return 1
	git -C "$bare" symbolic-ref HEAD refs/heads/main || return 1
	git -C "$canonical" remote set-head origin main || return 1
	git -C "$canonical" worktree add -q -b feature/archive "$worktree" main || return 1
	git -C "$worktree" config user.email test@example.invalid || return 1
	git -C "$worktree" config user.name Test || return 1
	printf '%s\t%s\n' "$canonical" "$worktree"
	return 0
}

test_clean_archive() {
	local paths canonical worktree archive_root archive rc=0
	paths=$(setup_repo clean) || return 1
	IFS=$'\t' read -r canonical worktree <<<"$paths"
	archive_root="$TEST_ROOT/clean-archives"
	archive=$(bash "$HELPER" archive "$worktree" --repo owner/repo --issue 10 \
		--reason post-pr-cleanup --base-branch main --output-root "$archive_root") || return 1
	[[ -f "$archive/manifest.json" && ! -f "$archive/commits.bundle" ]] || rc=1
	python3 - "$archive/manifest.json" <<'PY' || rc=1
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
assert m["dirty_state"] == "clean"
assert m["base_branch"] == "main"
assert m["base_sha"] == m["head_sha"]
assert m["default_branch"] == "main"
PY
	bash "$HELPER" verify "$archive" >/dev/null || rc=1
	[[ "$(bash "$HELPER" list --repo owner/repo --issue 10 --output-root "$archive_root" | wc -l | tr -d ' ')" == "1" ]] || rc=1
	result "clean archive records exact base metadata and verifies" "$rc"
	return 0
}

test_restore_commits_dirty_and_untracked() {
	local paths canonical worktree archive_root archive target rc=0
	paths=$(setup_repo restore) || return 1
	IFS=$'\t' read -r canonical worktree <<<"$paths"
	archive_root="$TEST_ROOT/restore-archives"
	printf 'commit\n' >>"$worktree/file.txt"
	git -C "$worktree" commit -qam local || return 1
	printf 'staged\n' >"$worktree/staged.txt"
	git -C "$worktree" add staged.txt || return 1
	printf 'dirty\n' >>"$worktree/file.txt"
	mkdir -p "$worktree/local"
	printf 'untracked\n' >"$worktree/local/note.txt"
	ln -s ../file.txt "$worktree/local/file-link"
	printf 'cache/\n' >"$worktree/.gitignore"
	mkdir "$worktree/cache"
	printf 'discardable\n' >"$worktree/cache/payload"
	archive=$(bash "$HELPER" archive "$worktree" --repo owner/repo --issue 11 \
		--reason failed-worker --base-branch main --output-root "$archive_root") || return 1
	[[ -s "$archive/commits.bundle" && -s "$archive/diff.patch" && -s "$archive/staged.patch" ]] || rc=1
	[[ -s "$archive/untracked.tar.gz" && -s "$archive/untracked-files.txt" ]] || rc=1
	target="$TEST_ROOT/restored-worktree"
	bash "$HELPER" restore "$archive" --target "$target" >/dev/null || rc=1
	grep -q '^commit$' "$target/file.txt" || rc=1
	grep -q '^dirty$' "$target/file.txt" || rc=1
	[[ "$(git -C "$target" show :staged.txt)" == "staged" ]] || rc=1
	[[ "$(cat "$target/local/note.txt")" == "untracked" ]] || rc=1
	[[ -L "$target/local/file-link" && "$(readlink "$target/local/file-link")" == "../file.txt" ]] || rc=1
	[[ -f "$target/.gitignore" && ! -e "$target/cache" && ! -e "$archive/git-admin.json" ]] || rc=1
	[[ "$(git -C "$target" log -1 --format=%s)" == "local" ]] || rc=1
	[[ "$(sqlite3 "$WORKTREE_REGISTRY_DB" 'SELECT count(*) FROM worktree_owners;')" == "1" ]] || rc=1
	result "restore recovers bundle commits, staged and unstaged patches, and untracked files" "$rc"
	return 0
}

test_shared_base_restore() {
	local paths canonical worktree archive target head_sha rc=0
	local expected actual
	local snapshot_code='import json,sys; sys.path.insert(0,sys.argv[1]); from worktree_archive_snapshot import git_snapshot; print(json.dumps(git_snapshot(sys.argv[2]),sort_keys=True))'
	paths=$(setup_repo independent) || return 1
	IFS=$'\t' read -r canonical worktree <<<"$paths"
	printf 'committed\000binary\n' >"$worktree/binary.dat"
	git -C "$worktree" add binary.dat || return 1
	git -C "$worktree" commit -qm binary || return 1
	head_sha=$(git -C "$worktree" rev-parse HEAD) || return 1
	printf 'staged\000binary\n' >"$worktree/binary.dat"
	chmod +x "$worktree/binary.dat"
	git -C "$worktree" add binary.dat || return 1
	printf 'unstaged\000binary\n' >"$worktree/binary.dat"
	printf 'unusual filename\n' >"$worktree/line"$'\n'"break.txt"
	ln -s binary.dat "$worktree/local-link"
	expected=$(python3 -c "$snapshot_code" "${SCRIPT_DIR}/.." "$worktree") || return 1
	archive=$(bash "$HELPER" archive "$worktree" --repo owner/repo --issue 14 \
		--reason failed-worker --base-branch main \
		--output-root "$TEST_ROOT/independent-archives") || return 1
	# Git provides the unchanged base; archives contain only changes and new files.
	[[ ! -e "$archive/git-admin.json" ]] || rc=1
	bash "$HELPER" verify "$archive" >/dev/null || rc=1
	target="$TEST_ROOT/independent-restored"
	bash "$HELPER" restore "$archive" --target "$target" >/dev/null || return 1
	[[ "$(git -C "$target" rev-parse HEAD)" == "$head_sha" ]] || rc=1
	[[ "$(git -C "$target" ls-files --stage binary.dat)" == 100755* ]] || rc=1
	cmp "$worktree/binary.dat" "$target/binary.dat" || rc=1
	cmp "$worktree/line"$'\n'"break.txt" "$target/line"$'\n'"break.txt" || rc=1
	[[ -L "$target/local-link" && "$(readlink "$target/local-link")" == binary.dat ]] || rc=1
	[[ ! -e "$target/.git/objects/info/alternates" ]] || rc=1
	git -C "$target" fsck --full >/dev/null 2>&1 || rc=1
	actual=$(python3 -c "$snapshot_code" "${SCRIPT_DIR}/.." "$target") || return 1
	[[ "$actual" == "$expected" ]] || rc=1
	result "shared-base restore preserves binary data, modes and unusual names without raw Git metadata" "$rc"
	return 0
}

test_snapshot_protects_unsupported_content() {
	local paths canonical worktree baseline changed rc=0
	local snapshotter="${SCRIPT_DIR}/../worktree_archive_snapshot.py"
	paths=$(setup_repo snapshot) || return 1
	IFS=$'\t' read -r canonical worktree <<<"$paths"
	baseline=$(python3 "$snapshotter" "$worktree") || return 1
	printf 'changed\n' >>"$worktree/file.txt"
	changed=$(python3 "$snapshotter" "$worktree") || return 1
	[[ "$changed" != "$baseline" ]] || rc=1
	printf '.env\n' >"$worktree/.gitignore"
	printf 'fixture-not-a-secret\n' >"$worktree/.env"
	if python3 "$snapshotter" "$worktree" >/dev/null 2>&1; then rc=1; fi
	rm "$worktree/.env" "$worktree/.gitignore"
	printf 'file.txt filter=fixture\n' >"$worktree/.gitattributes"
	if python3 "$snapshotter" "$worktree" >/dev/null 2>&1; then rc=1; fi
	rm "$worktree/.gitattributes"
	mkdir "$worktree/empty"
	if python3 "$snapshotter" "$worktree" >/dev/null 2>&1; then rc=1; fi
	rmdir "$worktree/empty"
	git -C "$worktree" update-index --assume-unchanged file.txt || return 1
	if python3 "$snapshotter" "$worktree" >/dev/null 2>&1; then rc=1; fi
	result "snapshot detects changes and protects ignored data, filters, empty directories and special index flags" "$rc"
	return 0
}

test_verify_detects_tamper() {
	local paths canonical worktree archive rc=0
	paths=$(setup_repo verify) || return 1
	IFS=$'\t' read -r canonical worktree <<<"$paths"
	printf 'dirty\n' >>"$worktree/file.txt"
	archive=$(bash "$HELPER" archive "$worktree" --repo owner/repo --issue 12 \
		--reason failed-worker --base-branch main --output-root "$TEST_ROOT/verify-archives") || return 1
	printf 'tamper\n' >>"$archive/diff.patch"
	if bash "$HELPER" verify "$archive" >/dev/null 2>&1; then rc=1; fi
	result "verify rejects artifact tampering" "$rc"
	return 0
}

# GH#34943: removal must refuse when a late writer changed the source after
# capture. Each mutation class runs against a fresh archive of the same state.
test_source_matches_detects_late_writes() {
	local paths canonical worktree root archive mutation issue=20 rc=0
	paths=$(setup_repo stability) || return 1
	IFS=$'\t' read -r canonical worktree <<<"$paths"
	root="$TEST_ROOT/stability-archives"
	printf 'dirty\n' >>"$worktree/file.txt"
	printf 'note\n' >"$worktree/note.txt"
	for mutation in none tracked staged untracked-new untracked-edit commit; do
		# Distinct issue per archive: same-second timestamps cannot collide.
		issue=$((issue + 1))
		if ! archive=$(bash "$HELPER" archive "$worktree" --repo owner/repo --issue "$issue" \
			--reason failed-worker --base-branch main --output-root "$root"); then
			printf '  archive failed before mutation: %s\n' "$mutation"
			rc=1
			continue
		fi
		case "$mutation" in
		tracked) printf 'late\n' >>"$worktree/file.txt" ;;
		staged) git -C "$worktree" add file.txt ;;
		untracked-new) printf 'late\n' >"$worktree/late.txt" ;;
		untracked-edit) printf 'late\n' >>"$worktree/note.txt" ;;
		commit) git -C "$worktree" add -A && git -C "$worktree" commit -qm late ;;
		esac
		if [[ "$mutation" == none ]]; then
			bash "$HELPER" source-matches "$archive" "$worktree" >/dev/null 2>&1 || rc=1
		elif bash "$HELPER" source-matches "$archive" "$worktree" >/dev/null 2>&1; then
			printf '  source-matches accepted mutation: %s\n' "$mutation"
			rc=1
		fi
	done
	python3 - "$archive/manifest.json" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
m = json.loads(p.read_text(encoding="utf-8"))
del m["source_fingerprint"]
p.write_text(json.dumps(m), encoding="utf-8")
PY
	if bash "$HELPER" source-matches "$archive" "$worktree" >/dev/null 2>&1; then rc=1; fi
	result "source-matches refuses late writes and fingerprint-less archives" "$rc"
	return 0
}

test_prune_modes() {
	local paths canonical worktree root archive old_archive rc=0
	paths=$(setup_repo prune) || return 1
	IFS=$'\t' read -r canonical worktree <<<"$paths"
	root="$TEST_ROOT/prune-archives"
	archive=$(bash "$HELPER" archive "$worktree" --repo owner/repo --issue 13 \
		--reason post-pr-cleanup --base-branch main --output-root "$root") || return 1
	old_archive="$archive"
	python3 - "$old_archive/manifest.json" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
m = json.loads(p.read_text(encoding="utf-8"))
m["created_at"] = "2000-01-01T00:00:00Z"
p.write_text(json.dumps(m, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
	bash "$HELPER" prune --older-than 14d --max-total-size 20G --dry-run --output-root "$root" | grep -q "$old_archive" || rc=1
	[[ -d "$old_archive" ]] || rc=1
	bash "$HELPER" prune --older-than 14d --max-total-size 20G --apply --output-root "$root" >/dev/null || rc=1
	[[ ! -e "$old_archive" ]] || rc=1
	result "prune dry-run reports and apply removes expired archives" "$rc"
	return 0
}

# GH#36564: a refused or failed capture must leave no archive bytes behind.
test_failed_capture_leaves_no_archive() {
	local paths canonical worktree root stderr_file reserve rc=0
	paths=$(setup_repo reclaim) || return 1
	IFS=$'\t' read -r canonical worktree <<<"$paths"
	root="$TEST_ROOT/reclaim-archives"
	stderr_file="$TEST_ROOT/reclaim.stderr"
	printf 'commit\n' >>"$worktree/file.txt"
	git -C "$worktree" commit -qam local || return 1
	printf 'untracked\n' >"$worktree/note.txt"
	# Capacity: refuse before allocating anything.
	if AIDEVOPS_WORKTREE_ARCHIVE_RESERVE_BYTES=999999999999999999 bash "$HELPER" archive "$worktree" \
		--repo owner/repo --issue 30 --reason failed-worker --base-branch main \
		--output-root "$root" >/dev/null 2>"$stderr_file"; then rc=1; fi
	grep -q 'producer:insufficient-capacity; estimate=[0-9]*; reserve=999999999999999999; free=[0-9]*; no archive written' "$stderr_file" || rc=1
	[[ ! -e "$root" ]] || rc=1
	# Decimal leading zeros and values beyond signed/unsigned Bash arithmetic
	# must not turn a refusal into a successful capture.
	for reserve in 0999999999999999999 9223372036854775808 18446744073709551615 999999999999999999999999 invalid; do
		if AIDEVOPS_WORKTREE_ARCHIVE_RESERVE_BYTES="$reserve" bash "$HELPER" archive "$worktree" \
			--repo owner/repo --issue 30 --reason failed-worker --base-branch main \
			--output-root "$root" >/dev/null 2>"$stderr_file"; then rc=1; fi
		[[ ! -e "$root" ]] || rc=1
	done
	# With no general reserve, the untracked allowance alone must refuse.
	if AIDEVOPS_WORKTREE_ARCHIVE_RESERVE_BYTES=0 \
		AIDEVOPS_WORKTREE_ARCHIVE_MAX_UNTRACKED_BYTES=999999999999999999 bash "$HELPER" archive "$worktree" \
		--repo owner/repo --issue 30 --reason failed-worker --base-branch main \
		--output-root "$root" >/dev/null 2>"$stderr_file"; then rc=1; fi
	grep -q 'producer:insufficient-capacity;' "$stderr_file" || rc=1
	[[ ! -e "$root" ]] || rc=1
	# Failure after commits.bundle and untracked capture are written (the
	# failure log is checked last): the partial directory is discarded.
	if bash "$HELPER" archive "$worktree" \
		--repo owner/repo --issue 31 --reason failed-worker --base-branch main \
		--failure-log "$TEST_ROOT/missing-failure.log" \
		--output-root "$root" >/dev/null 2>&1; then rc=1; fi
	[[ -d "$root/owner__repo/31" && -z "$(ls -A "$root/owner__repo/31")" ]] || rc=1
	[[ -z "$(find "$root" -type f -print -quit)" ]] || rc=1
	result "refused and failed captures leave no archive bytes" "$rc"
	return 0
}

test_tracked_patch_capacity() {
	local paths canonical worktree root reserve phase rc=0
	paths=$(setup_repo patch-capacity) || return 1
	IFS=$'\t' read -r canonical worktree <<<"$paths"
	root="$TEST_ROOT/patch-capacity-archives"
	for phase in staged unstaged; do
		python3 - "$worktree/file.txt" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
path.write_text(path.read_text() + "tracked change\n" * 10000)
PY
		if [[ "$phase" == staged ]]; then git -C "$worktree" add file.txt || return 1; fi
		reserve=$(python3 -c 'import shutil, sys; print(max(0, shutil.disk_usage(sys.argv[1]).free - 4096))' "$TEST_ROOT") || return 1
		if AIDEVOPS_WORKTREE_ARCHIVE_RESERVE_BYTES="$reserve" AIDEVOPS_WORKTREE_ARCHIVE_MAX_UNTRACKED_BYTES=0 \
			bash "$HELPER" archive "$worktree" --repo owner/repo --issue 32 --reason failed-worker \
			--base-branch main --output-root "$root" >/dev/null 2>"$TEST_ROOT/patch-capacity.stderr"; then rc=1; fi
		grep -q 'producer:insufficient-capacity;' "$TEST_ROOT/patch-capacity.stderr" || rc=1
		[[ ! -e "$root" ]] || rc=1
		git -C "$worktree" reset -q --hard HEAD || return 1
	done
	result "staged and unstaged patches count toward archive capacity" "$rc"
	return 0
}

# GH#36607: a merged/pushed worktree's commits are already on the remote. The
# archive omits the HEAD bundle, records the published head and still restores.
test_published_archive_has_no_bundle() {
	local paths canonical worktree root archive target head_sha state rc=0
	paths=$(setup_repo published) || return 1
	IFS=$'\t' read -r canonical worktree <<<"$paths"
	root="$TEST_ROOT/published-archives"
	printf 'published\n' >>"$worktree/file.txt"
	git -C "$worktree" commit -qam published || return 1
	git -C "$worktree" push -q -u origin feature/archive || return 1
	head_sha=$(git -C "$worktree" rev-parse HEAD) || return 1
	archive=$(bash "$HELPER" archive "$worktree" --repo owner/repo --issue 40 \
		--reason post-pr-cleanup --base-branch main --output-root "$root") || return 1
	[[ ! -e "$archive/commits.bundle" ]] || rc=1
	state=$(python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); print(m["remote_branch_state"], m["dirty_state"], m["head_sha"])' "$archive/manifest.json") || rc=1
	[[ "$state" == "published clean $head_sha" ]] || rc=1
	bash "$HELPER" verify "$archive" >/dev/null || rc=1
	bash "$HELPER" verify-local "$archive" >/dev/null || rc=1
	target="$TEST_ROOT/published-restored"
	bash "$HELPER" restore "$archive" --target "$target" >/dev/null || rc=1
	[[ "$(git -C "$target" rev-parse HEAD)" == "$head_sha" ]] || rc=1
	grep -q '^published$' "$target/file.txt" || rc=1
	# Work reachable only from a non-origin remote keeps the base-relative bundle.
	printf 'local only\n' >>"$worktree/file.txt"
	git -C "$worktree" commit -qam unpushed || return 1
	git -C "$canonical" remote add backup "$(git -C "$canonical" remote get-url origin)" || return 1
	git -C "$worktree" update-ref refs/remotes/backup/feature/archive HEAD || return 1
	archive=$(bash "$HELPER" archive "$worktree" --repo owner/repo --issue 41 \
		--reason post-pr-cleanup --base-branch main --output-root "$root") || return 1
	[[ -s "$archive/commits.bundle" ]] || rc=1
	grep -q '"remote_branch_state": "unpublished"' "$archive/manifest.json" || rc=1
	git -C "$worktree" reset -q --hard HEAD~1 || return 1
	# Local verification gates removal: a published head that is no longer on
	# origin is refused even if another remote-tracking ref still contains it.
	archive=$(bash "$HELPER" archive "$worktree" --repo owner/repo --issue 42 \
		--reason post-pr-cleanup --base-branch main --output-root "$root") || return 1
	git -C "$canonical" update-ref -d refs/remotes/origin/feature/archive || return 1
	if bash "$HELPER" verify-local "$archive" >/dev/null 2>&1; then rc=1; fi
	result "published worktree archives omit the bundle and restore the pushed head" "$rc"
	return 0
}

test_invalid_arguments() {
	local paths canonical worktree rc=0
	paths=$(setup_repo invalid) || return 1
	IFS=$'\t' read -r canonical worktree <<<"$paths"
	if bash "$HELPER" archive "$worktree" --repo bad --issue 1 --reason failed-worker --base-branch main >/dev/null 2>&1; then rc=1; fi
	if bash "$HELPER" archive "$worktree" --repo owner/repo --issue 0 --reason failed-worker --base-branch main >/dev/null 2>&1; then rc=1; fi
	if bash "$HELPER" prune --older-than fourteen --max-total-size 20G --dry-run >/dev/null 2>&1; then rc=1; fi
	if bash "$HELPER" prune --older-than 14d --max-total-size 20G >/dev/null 2>&1; then rc=1; fi
	if bash "$HELPER" restore "$TEST_ROOT/missing" --target "$TEST_ROOT/target" >/dev/null 2>&1; then rc=1; fi
	result "invalid arguments fail safely" "$rc"
	return 0
}

test_clean_archive
test_restore_commits_dirty_and_untracked
test_shared_base_restore || result "shared-base fixture setup" 1
test_snapshot_protects_unsupported_content || result "snapshot fixture setup" 1
test_verify_detects_tamper
test_source_matches_detects_late_writes
test_prune_modes
test_failed_capture_leaves_no_archive || result "failed-capture fixture setup" 1
test_tracked_patch_capacity || result "tracked-patch capacity fixture setup" 1
test_published_archive_has_no_bundle || result "published-archive fixture setup" 1
test_invalid_arguments

printf '%s tests, %s failures\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
