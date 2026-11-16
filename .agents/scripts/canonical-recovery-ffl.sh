#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Canonical Recovery FFL -- untracked restore, project config and local fast-forward
# =============================================================================
# Untracked-file noclobber restore, .aidevops.json untrack migration,
# fast-forward-local validation/preserve/reapply and fast_forward_local.
#
# Usage: source "${SCRIPT_DIR}/canonical-recovery-ffl.sh"
#
# Part of aidevops framework: https://aidevops.sh

# shellcheck disable=SC2154  # common_dir is assigned by the orchestrator before fast_forward_local runs

# Include guard
[[ -n "${_CANONICAL_RECOVERY_FFL_LIB_LOADED:-}" ]] && return 0
_CANONICAL_RECOVERY_FFL_LIB_LOADED=1

ffl_block() {
	local message="$1"
	printf 'BLOCKED: %s\n' "$message" >&2
	return 1
}

# Reinstate preserved untracked files after a verified fast-forward or mirror
# synchronization without overwriting anything that now exists at the same
# path. Paths that collide with the new tip or sit under a new non-directory
# or symlink ancestor stay in the backup and are reported as
# UNTRACKED_LEFT_IN_BACKUP= lines. Returns 0 when every path was reinstated,
# 3 when at least one path was left in the backup, and 1 on error (GH#34770).
restore_untracked_noclobber() {
	local repo="$1"
	local backup_dir="$2"
	local list_file="${backup_dir}/untracked-files.nul"
	[[ -f "$list_file" ]] || {
		printf 'UNTRACKED_RESTORED=0\n'
		return 0
	}
	python3 - "$repo" "${backup_dir}/untracked" "$list_file" <<'PY'
import os
import pathlib
import shutil
import stat
import sys

root = pathlib.Path(sys.argv[1]).resolve()
source_root = pathlib.Path(sys.argv[2]).resolve()
paths = pathlib.Path(sys.argv[3]).read_bytes().split(b"\0")


def inside(base, candidate):
    return os.path.commonpath((str(base), str(candidate))) == str(base)


restored = 0
left = []
for raw in paths:
    if not raw:
        continue
    relative = pathlib.Path(os.fsdecode(raw))
    if relative.is_absolute() or ".." in relative.parts:
        raise SystemExit("invalid restore inventory")
    source_parent = (source_root / relative.parent).resolve(strict=False)
    if not inside(source_root, source_parent):
        raise SystemExit("untracked backup escaped payload root")
    source = source_parent / relative.name
    metadata = source.lstat()
    if not (stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode)):
        raise SystemExit("unsupported untracked backup file type")
    # Walk parents without following symlinks: an incoming tracked symlink or
    # file at any ancestor is a collision, never a destination to write through.
    target_parent = root
    collided = False
    for part in relative.parent.parts:
        target_parent = target_parent / part
        try:
            parent_meta = target_parent.lstat()
        except FileNotFoundError:
            try:
                target_parent.mkdir()
            except OSError:
                collided = True
                break
            continue
        if not stat.S_ISDIR(parent_meta.st_mode):
            collided = True
            break
    if collided:
        left.append(raw)
        continue
    target = target_parent / relative.name
    try:
        if stat.S_ISLNK(metadata.st_mode):
            os.symlink(os.readlink(source), target)
        else:
            flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
            descriptor = os.open(target, flags, 0o600)
            with os.fdopen(descriptor, "wb") as destination, source.open("rb") as payload:
                shutil.copyfileobj(payload, destination)
            shutil.copystat(source, target, follow_symlinks=False)
    except FileExistsError:
        left.append(raw)
        continue
    restored += 1
for raw in left:
    print("UNTRACKED_LEFT_IN_BACKUP=" + raw.decode("utf-8", "backslashreplace"))
print(f"UNTRACKED_RESTORED={restored}")
sys.exit(3 if left else 0)
PY
	return $?
}

PROJECT_CONFIG_PATH=".aidevops.json"
PROJECT_CONFIG_PAYLOAD="payload"
PCU_DIR=""

# GH#35659: the supported project-config migration commits an explicit root
# ignore rule and removes only the index entry. `read-tree -u -m` then deletes
# the clean local file from every other checkout, and status stays clean, so
# nothing reports the loss. Returns 0 only for that exact incoming migration.
project_config_untrack_incoming() {
	local repo="$1"
	local old_sha="$2"
	local new_sha="$3"
	local ignore_rules=""
	"$REAL_GIT" -C "$repo" cat-file -e "${old_sha}:${PROJECT_CONFIG_PATH}" 2>/dev/null || return 1
	! "$REAL_GIT" -C "$repo" cat-file -e "${new_sha}:${PROJECT_CONFIG_PATH}" 2>/dev/null || return 1
	ignore_rules=$("$REAL_GIT" -C "$repo" cat-file blob "${new_sha}:.gitignore" 2>/dev/null) || return 1
	# Same explicit-rule contract as project-config-restore-helper.sh; a plain
	# deletion without the rule is an intentional removal, not a migration.
	grep -Eq '^/?\.aidevops\.json$' <<<"$ignore_rules" || return 1
	! grep -Eq '^!/?\.aidevops\.json$' <<<"$ignore_rules" || return 1
	return 0
}

# Copy the local project config aside before a worktree update would delete it.
# Sets PCU_DIR to the private preservation directory, or leaves it empty when no
# untracking migration is incoming or the file is already absent. Returns 1 for
# an unsafe file or, when allow_modified is false, local edits that a three-way
# re-apply could not keep.
project_config_untrack_preserve() {
	local repo="$1"
	local old_sha="$2"
	local new_sha="$3"
	local operation_key="$4"
	local allow_modified="$5"
	local recovery_root="${AIDEVOPS_CANONICAL_RECOVERY_ROOT:-${HOME}/.aidevops/.agent-workspace/recovery/canonical}"
	local preserve_parent=""
	local preserve_dir=""
	local config_file="${repo}/${PROJECT_CONFIG_PATH}"
	local committed_blob=""
	local local_blob=""
	PCU_DIR=""
	project_config_untrack_incoming "$repo" "$old_sha" "$new_sha" || return 0
	if [[ ! -e "$config_file" && ! -L "$config_file" ]]; then
		return 0
	fi
	if [[ -L "$config_file" || ! -f "$config_file" || ! -O "$config_file" ]]; then
		printf 'BLOCKED: incoming commit untracks %s but the local copy is a symlink, not a regular file, or not owned by the current user; nothing was changed\n' \
			"$PROJECT_CONFIG_PATH" >&2
		return 1
	fi
	if [[ "$allow_modified" != "$BOOLEAN_TRUE" ]]; then
		committed_blob=$("$REAL_GIT" -C "$repo" rev-parse --verify "${old_sha}:${PROJECT_CONFIG_PATH}") || return 1
		local_blob=$("$REAL_GIT" -C "$repo" hash-object --no-filters -- "$config_file") || return 1
		if [[ "$committed_blob" != "$local_blob" ]]; then
			printf 'BLOCKED: incoming commit untracks %s but the local copy has edits; nothing was changed. Use sync-mirror on a GitHub-backed repository, or keep the edits and fast-forward after the migration is resolved\n' \
				"$PROJECT_CONFIG_PATH" >&2
			return 1
		fi
	fi
	preserve_parent="${recovery_root}/${operation_key}"
	(umask 077 && mkdir -p "$preserve_parent") || {
		printf 'BLOCKED: project config preservation directory cannot be created\n' >&2
		return 1
	}
	preserve_dir=$(mktemp -d "${preserve_parent}/project-config-${new_sha:0:12}.XXXXXX") || {
		printf 'BLOCKED: project config preservation directory cannot be created\n' >&2
		return 1
	}
	chmod 700 "$preserve_dir" || return 1
	python3 - "$config_file" "$preserve_dir" "$PROJECT_CONFIG_PATH" "$PROJECT_CONFIG_PAYLOAD" <<'PY' || {
import hashlib
import os
import stat
import sys

source, target_dir, config_name, payload_name = sys.argv[1:5]
no_follow = getattr(os, "O_NOFOLLOW", 0)
payload_path = os.path.join(target_dir, payload_name)
descriptor = os.open(source, os.O_RDONLY | no_follow)
with os.fdopen(descriptor, "rb") as handle:
    before = os.fstat(handle.fileno())
    if not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid():
        raise SystemExit("unsafe project config")
    payload = handle.read()
after = os.lstat(source)
if (after.st_ino, after.st_size, after.st_mtime_ns) != (before.st_ino, before.st_size, before.st_mtime_ns):
    raise SystemExit("project config changed during preservation")
digest = hashlib.sha256(payload).hexdigest()
flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | no_follow
with os.fdopen(os.open(payload_path, flags, 0o600), "wb") as copy:
    copy.write(payload)
    copy.flush()
    os.fsync(copy.fileno())
with open(payload_path, "rb") as check:
    if hashlib.sha256(check.read()).hexdigest() != digest:
        raise SystemExit("project config copy could not be verified")
with os.fdopen(os.open(os.path.join(target_dir, "manifest.tsv"), flags, 0o600), "w") as manifest:
    manifest.write(f"path\t{config_name}\nsha256\t{digest}\n")
    manifest.write(f"mode\t{stat.S_IMODE(before.st_mode):o}\nmtime_ns\t{before.st_mtime_ns}\n")
PY
		printf 'BLOCKED: local %s could not be preserved before synchronization; nothing was changed\n' \
			"$PROJECT_CONFIG_PATH" >&2
		return 1
	}
	PCU_DIR="$preserve_dir"
	printf 'PROJECT_CONFIG_PRESERVED_DIR=%s\n' "$preserve_dir"
	return 0
}

# Reinstate a preserved project config as ignored local state on the verified
# new tip: exact bytes, mode and mtime, never overwriting or following links.
# Returns 0 when reinstated or nothing was preserved (empty preserve_dir), 3
# when left in the preservation directory, 1 on error.
project_config_reinstate() {
	local repo="$1"
	local preserve_dir="$2"
	local config_file="${repo}/${PROJECT_CONFIG_PATH}"
	local rc=0
	local ignored_status=""
	[[ -n "$preserve_dir" ]] || return 0
	python3 - "$repo" "$preserve_dir" "$PROJECT_CONFIG_PATH" "$PROJECT_CONFIG_PAYLOAD" <<'PY' || rc=$?
import hashlib
import os
import sys
import tempfile

repo, preserve_dir, config_name, payload_name = sys.argv[1:5]
fields = {}
with open(os.path.join(preserve_dir, "manifest.tsv"), "rb") as manifest:
    for line in manifest.read().decode().splitlines():
        key, _, value = line.partition("\t")
        fields[key] = value
if fields.get("path") != config_name:
    raise SystemExit("invalid project config manifest")
with open(os.path.join(preserve_dir, payload_name), "rb") as handle:
    payload = handle.read()
if hashlib.sha256(payload).hexdigest() != fields.get("sha256"):
    raise SystemExit("preserved project config does not match its manifest")
target = os.path.join(repo, config_name)
if os.path.lexists(target):
    sys.exit(3)
descriptor, temp_path = tempfile.mkstemp(prefix=config_name + ".reinstate.", dir=repo)
try:
    with os.fdopen(descriptor, "wb") as temp:
        temp.write(payload)
        temp.flush()
        os.fchmod(temp.fileno(), int(fields["mode"], 8))
        os.fsync(temp.fileno())
    mtime_ns = int(fields["mtime_ns"])
    os.utime(temp_path, ns=(mtime_ns, mtime_ns))
    try:
        # link() is the no-clobber publish step: it fails if anything,
        # including a symlink, appeared at the destination meanwhile.
        os.link(temp_path, target)
    except FileExistsError:
        sys.exit(3)
finally:
    os.unlink(temp_path)
with open(target, "rb") as check:
    if hashlib.sha256(check.read()).hexdigest() != fields["sha256"]:
        raise SystemExit("reinstated project config could not be verified")
PY
	if [[ "$rc" -eq 0 ]]; then
		ignored_status=$("$REAL_GIT" -C "$repo" status --porcelain=v1 --ignored -- "$PROJECT_CONFIG_PATH" 2>/dev/null || true)
		if [[ "$ignored_status" != "!! ${PROJECT_CONFIG_PATH}" ]]; then
			cmp -s "$config_file" "${preserve_dir}/${PROJECT_CONFIG_PAYLOAD}" && rm -f "$config_file"
			rc=3
		fi
	fi
	if [[ "$rc" -eq 0 ]]; then
		printf 'PROJECT_CONFIG_REINSTATED=%s\n' "$PROJECT_CONFIG_PATH"
		return 0
	fi
	printf 'PROJECT_CONFIG_LEFT_IN_BACKUP=%s\n' "$preserve_dir"
	printf 'WARNING: local %s was not reinstated after synchronization; its exact bytes remain in %s\n' \
		"$PROJECT_CONFIG_PATH" "$preserve_dir" >&2
	[[ "$rc" -eq 3 ]] && return 3
	return 1
}

# Three-way re-apply of preserved tracked edits onto the new tip. Prints
# conflicting paths and returns 1 when the edits cannot be merged cleanly.
ffl_reapply_edits() {
	local repo="$1"
	local base_sha="$2"
	local new_sha="$3"
	local edits_tree="$4"
	local merge_one=""
	local conflicts=""
	merge_one="$("$REAL_GIT" --exec-path)/git-merge-one-file"
	"$REAL_GIT" -C "$repo" read-tree -m -u "${base_sha}^{tree}" "${new_sha}^{tree}" "$edits_tree" || return 1
	[[ -x "$merge_one" ]] || return 1
	if ! "$REAL_GIT" -C "$repo" merge-index -o "$merge_one" -a >/dev/null 2>&1; then
		conflicts=$("$REAL_GIT" -C "$repo" diff --name-only --diff-filter=U)
		printf '%s\n' "$conflicts" | while IFS= read -r conflict_path; do
			[[ -z "$conflict_path" ]] || printf 'CONFLICT_PATH=%s\n' "$conflict_path"
		done
		return 1
	fi
	"$REAL_GIT" -C "$repo" reset -q || return 1
	return 0
}

FFL_DEFAULT_BRANCH=""
FFL_OLD_SHA=""
FFL_NEW_SHA=""
FFL_BACKUP_ID=""
FFL_BACKUP_DIR=""
FFL_EDITS_TREE=""

# Validate a local fast-forward request. Returns 0 when eligible, 1 when
# blocked, 2 when the default branch already equals the source tip.
ffl_validate() {
	local repo="$1"
	local from_branch="$2"
	local local_ref=""
	local from_ref="refs/heads/${from_branch}"
	local default_branch=""
	local configured_default=""
	local old_sha=""
	local new_sha=""
	local remotes=""
	local line=""
	local occupied_path=""
	local from_linked=false
	local git_path=""

	remotes=$("$REAL_GIT" -C "$repo" remote) || { ffl_block "remote list cannot be read"; return 1; }
	if [[ -n "$remotes" ]]; then
		ffl_block "repository has a remote; use ${SYNC_MIRROR_CMD} (GitHub-backed) instead of ${LOCAL_FAST_FORWARD_CMD}"
		return 1
	fi
	"$REAL_GIT" check-ref-format "$from_ref" >/dev/null 2>&1 || { ffl_block "source branch name is invalid"; return 1; }
	default_branch=$("$REAL_GIT" -C "$repo" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
	[[ -n "$default_branch" ]] || { ffl_block "canonical worktree is detached"; return 1; }
	configured_default=$("$REAL_GIT" -C "$repo" config --get init.defaultBranch 2>/dev/null || true)
	if [[ "$default_branch" != "main" && "$default_branch" != "master" &&
		(-z "$configured_default" || "$default_branch" != "$configured_default") ]]; then
		ffl_block "canonical branch ${default_branch} is not the default branch"
		return 1
	fi
	[[ "$from_branch" != "$default_branch" ]] || { ffl_block "source branch is the canonical default branch"; return 1; }
	local_ref="refs/heads/${default_branch}"
	for git_path in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD REBASE_HEAD rebase-merge rebase-apply; do
		[[ ! -e "$("$REAL_GIT" -C "$repo" rev-parse --path-format=absolute --git-path "$git_path")" ]] ||
			{ ffl_block "canonical worktree has an operation in progress (${git_path})"; return 1; }
	done
	old_sha=$("$REAL_GIT" -C "$repo" rev-parse --verify "${local_ref}^{commit}" 2>/dev/null || true)
	new_sha=$("$REAL_GIT" -C "$repo" rev-parse --verify "${from_ref}^{commit}" 2>/dev/null || true)
	[[ -n "$old_sha" ]] || { ffl_block "local ${default_branch} tip cannot be resolved"; return 1; }
	[[ -n "$new_sha" ]] || { ffl_block "source branch ${from_branch} cannot be resolved"; return 1; }
	while IFS= read -r line; do
		case "$line" in
		worktree\ *) occupied_path="${line#worktree }" ;;
		branch\ refs/heads/"$default_branch")
			[[ "$occupied_path" == "$repo" ]] ||
				{ ffl_block "default branch is active in another worktree: ${occupied_path}"; return 1; }
			;;
		branch\ "$from_ref")
			[[ "$occupied_path" == "$repo" ]] || from_linked=true
			;;
		esac
	done < <("$REAL_GIT" -C "$repo" worktree list --porcelain)
	[[ "$from_linked" == "$BOOLEAN_TRUE" ]] ||
		{ ffl_block "source branch ${from_branch} is not checked out in a linked worktree"; return 1; }
	"$REAL_GIT" -C "$repo" merge-base --is-ancestor "$old_sha" "$new_sha" ||
		{ ffl_block "source branch ${from_branch} is not a pure fast-forward of ${default_branch}"; return 1; }
	FFL_DEFAULT_BRANCH="$default_branch"
	FFL_OLD_SHA="$old_sha"
	FFL_NEW_SHA="$new_sha"
	[[ "$old_sha" != "$new_sha" ]] || return 2
	return 0
}

# Back up, verify and clean dirty canonical state; sets FFL_BACKUP_* globals.
ffl_preserve_and_clean() {
	local repo="$1"
	local task_id="$2"
	local new_sha="$3"
	local backup_helper="${SCRIPT_DIR}/dirty-worktree-backup-helper.sh"
	local status_out=""
	local backup_output=""
	local backup_id=""
	local backup_dir=""
	local edits_tree=""

	status_out=$("$REAL_GIT" -C "$repo" status --porcelain=v1) || { ffl_block "canonical status cannot be read"; return 1; }
	[[ -n "$status_out" ]] || return 0
	[[ -f "$backup_helper" ]] || { ffl_block "dirty-worktree backup helper is unavailable"; return 1; }
	backup_output=$(AIDEVOPS_REAL_GIT_BIN="$REAL_GIT" bash "$backup_helper" backup \
		--repo "$repo" --reason "canonical local fast-forward" \
		--operation-id "canonical-local-ff-${task_id}-${new_sha}" --machine) ||
		{ ffl_block "canonical dirty state could not be preserved"; return 1; }
	IFS='|' read -r backup_id backup_dir <<<"${backup_output##*$'\n'}"
	[[ -n "$backup_id" && -d "$backup_dir" ]] || { ffl_block "canonical backup evidence is incomplete"; return 1; }
	AIDEVOPS_REAL_GIT_BIN="$REAL_GIT" bash "$backup_helper" verify --repo "$repo" --backup "$backup_id" >/dev/null ||
		{ ffl_block "canonical backup verification failed"; return 1; }
	AIDEVOPS_REAL_GIT_BIN="$REAL_GIT" bash "$backup_helper" matches --repo "$repo" --backup "$backup_id" >/dev/null ||
		{ ffl_block "canonical state changed after backup"; return 1; }
	printf 'PRESERVED_BACKUP_ID=%s\n' "$backup_id"
	printf 'PRESERVED_BACKUP_DIR=%s\n' "$backup_dir"
	printf 'RESTORE_COMMAND=%q restore --repo %q --backup %q --confirm RESTORE_DIRTY_WORKTREE_BACKUP\n' \
		"$backup_helper" "$repo" "$backup_id"
	edits_tree=$(awk -F'\t' '$1 == "worktree_tree" { print $2 }' "${backup_dir}/manifest.tsv")
	[[ -n "$edits_tree" ]] || { ffl_block "backup worktree tree is missing"; return 1; }
	AIDEVOPS_REAL_GIT_BIN="$REAL_GIT" bash "$backup_helper" clean --repo "$repo" --backup "$backup_id" \
		--confirm CLEAN_VERIFIED_DIRTY_WORKTREE_BACKUP >/dev/null ||
		{ ffl_block "canonical clean failed (backup ${backup_id})"; return 1; }
	FFL_BACKUP_ID="$backup_id"
	FFL_BACKUP_DIR="$backup_dir"
	FFL_EDITS_TREE="$edits_tree"
	return 0
}

# Fast-forward a remote-less (local_only) canonical default branch to a
# linked-worktree branch tip. Dirty user state is backed up, verified, and
# re-applied after the fast-forward.
fast_forward_local() {
	local repo="$1"
	local from_branch="$2"
	local task_id="$3"
	local default_branch=""
	local local_ref=""
	local old_sha=""
	local new_sha=""
	local validate_status=0
	local lock="${common_dir}/aidevops-canonical-recovery.lock"
	local audit="${SCRIPT_DIR}/audit-log-helper.sh"
	local audit_file="${HOME}/.aidevops/logs/canonical-recovery-audit.jsonl"
	local backup_id=""
	local backup_dir=""
	local edits_tree=""
	local config_preserve_dir=""

	ffl_validate "$repo" "$from_branch" || validate_status=$?
	if [[ "$validate_status" -eq 2 ]]; then
		printf 'VERIFIED: %s already at %s\n' "$FFL_DEFAULT_BRANCH" "$from_branch"
		return 0
	fi
	[[ "$validate_status" -eq 0 ]] || return 1
	default_branch="$FFL_DEFAULT_BRANCH"
	old_sha="$FFL_OLD_SHA"
	new_sha="$FFL_NEW_SHA"
	local_ref="refs/heads/${default_branch}"
	[[ -x "$audit" ]] || { ffl_block "tamper-evident audit helper is unavailable"; return 1; }

	mkdir "$lock" 2>/dev/null || { ffl_block "canonical recovery lock is already held"; return 1; }
	# shellcheck disable=SC2064
	trap "rmdir '${lock}' 2>/dev/null || true" EXIT

	# GH#35659: three-way re-apply cannot keep edits to an untracked config.
	project_config_untrack_preserve "$repo" "$old_sha" "$new_sha" "$task_id" false || return 1
	config_preserve_dir="$PCU_DIR"

	AUDIT_LOG_FILE="$audit_file" "$audit" verify --quiet || { ffl_block "audit chain verification failed"; return 1; }
	AUDIT_LOG_FILE="$audit_file" AUDIT_QUIET=true "$audit" log operation.verify \
		"Canonical local fast-forward authorized" \
		--detail "task=${task_id}" --detail "repo=${repo}" --detail "operation=${LOCAL_FAST_FORWARD_CMD}" \
		--detail "target=${default_branch}" --detail "from_branch=${from_branch}" \
		--detail "old_sha=${old_sha}" --detail "new_sha=${new_sha}" \
		--detail "project_config_preservation=${config_preserve_dir:-none}" >/dev/null ||
		{ ffl_block "recovery audit record could not be written"; return 1; }

	ffl_preserve_and_clean "$repo" "$task_id" "$new_sha" || return 1
	backup_id="$FFL_BACKUP_ID"
	backup_dir="$FFL_BACKUP_DIR"
	edits_tree="$FFL_EDITS_TREE"

	# shellcheck source=shared-constants.sh
	source "${SCRIPT_DIR}/shared-constants.sh"
	if declare -F remove_canonical_worktree_owner >/dev/null 2>&1; then
		remove_canonical_worktree_owner "$repo" || { ffl_block "invalid canonical ownership could not be cleared safely"; return 1; }
	fi
	[[ -z "$("$REAL_GIT" -C "$repo" status --porcelain)" ]] || { ffl_block "canonical worktree remains dirty after preservation"; return 1; }
	"$REAL_GIT" -C "$repo" read-tree --dry-run -u -m "$old_sha" "$new_sha" ||
		{ ffl_block "canonical worktree cannot be updated"; return 1; }
	"$REAL_GIT" -C "$repo" update-ref -m "aidevops canonical local fast-forward for task ${task_id}" \
		"$local_ref" "$new_sha" "$old_sha" || { ffl_block "canonical local ref changed during fast-forward"; return 1; }
	if ! "$REAL_GIT" -C "$repo" read-tree -u -m "$old_sha" "$new_sha"; then
		rollback_local_ref "$repo" "$local_ref" "$LOCAL_STATE_BORN" "$old_sha" "$new_sha" \
			"aidevops canonical local fast-forward rollback for task ${task_id}" || {
			printf 'CRITICAL: local fast-forward failed and the local ref rollback failed\n' >&2
			return 1
		}
		"$REAL_GIT" -C "$repo" read-tree --reset -u "$old_sha" || true
		ffl_block "canonical worktree update failed; local ref rolled back"
		return 1
	fi
	if [[ "$("$REAL_GIT" -C "$repo" rev-parse HEAD)" != "$new_sha" ||
		"$("$REAL_GIT" -C "$repo" symbolic-ref --quiet --short HEAD)" != "$default_branch" ]]; then
		printf 'CRITICAL: canonical branch or HEAD changed during local fast-forward\n' >&2
		return 1
	fi

	if [[ -n "$backup_id" ]]; then
		if ! ffl_reapply_edits "$repo" "$old_sha" "$new_sha" "$edits_tree"; then
			"$REAL_GIT" -C "$repo" read-tree --reset -u "$new_sha" || true
			project_config_reinstate "$repo" "$config_preserve_dir" || true
			printf 'FAST_FORWARDED_LOCAL_CANONICAL=true\nNEW_SHA=%s\n' "$new_sha"
			printf 'BLOCKED: preserved edits conflict with the new tip; they remain in backup %s\n' "$backup_id" >&2
			return 1
		fi
		local restore_rc=0
		restore_untracked_noclobber "$repo" "$backup_dir" || restore_rc=$?
		[[ "$restore_rc" -eq 0 || "$restore_rc" -eq 3 ]] ||
			{ ffl_block "preserved untracked files could not be restored (backup ${backup_id})"; return 1; }
	fi
	[[ "$("$REAL_GIT" -C "$repo" rev-parse --verify "${local_ref}^{commit}")" == "$new_sha" ]] ||
		{ ffl_block "default ref does not match the source tip after fast-forward"; return 1; }
	project_config_reinstate "$repo" "$config_preserve_dir" || true
	AUDIT_LOG_FILE="$audit_file" "$audit" verify --quiet || { ffl_block "audit chain verification failed after fast-forward"; return 1; }
	printf 'FAST_FORWARDED_LOCAL_CANONICAL=true\nOLD_SHA=%s\nNEW_SHA=%s\nCANONICAL_BRANCH=%s\nBACKUP_ID=%s\n' \
		"$old_sha" "$new_sha" "$default_branch" "${backup_id:-none}"
	return 0
}
