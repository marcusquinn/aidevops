#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
FAST_FORWARD_CMD="fast-forward-current"
SYNC_MIRROR_CMD="sync-mirror"

usage() {
	printf '%s\n' \
		'Usage:' \
		'  canonical-recovery-helper.sh restore-default --repo PATH --issue N --confirm RESTORE_CANONICAL_DEFAULT' \
		"  canonical-recovery-helper.sh ${FAST_FORWARD_CMD} --repo PATH --branch BRANCH --issue N --confirm FAST_FORWARD_CANONICAL_BRANCH" \
		"  canonical-recovery-helper.sh ${SYNC_MIRROR_CMD} --repo PATH --issue N --confirm SYNCHRONIZE_CANONICAL_MIRROR"
	return 0
}

cmd="${1:-}"
shift || true
repo_path=""
issue_number=""
confirmation=""
expected_branch=""
while [[ $# -gt 0 ]]; do
	case "$1" in
	--repo)
		repo_path="${2:-}"
		shift 2
		;;
	--issue)
		issue_number="${2:-}"
		shift 2
		;;
	--confirm)
		confirmation="${2:-}"
		shift 2
		;;
	--branch)
		expected_branch="${2:-}"
		shift 2
		;;
	*)
		usage
		exit 2
		;;
	esac
done

case "$cmd" in
restore-default)
	expected_confirmation="RESTORE_CANONICAL_DEFAULT"
	[[ -z "$expected_branch" ]] || {
		usage
		exit 2
	}
	;;
"$FAST_FORWARD_CMD")
	expected_confirmation="FAST_FORWARD_CANONICAL_BRANCH"
	[[ -n "$expected_branch" ]] || {
		usage
		exit 2
	}
	;;
"$SYNC_MIRROR_CMD")
	expected_confirmation="SYNCHRONIZE_CANONICAL_MIRROR"
	[[ -z "$expected_branch" ]] || {
		usage
		exit 2
	}
	;;
*)
	usage
	exit 2
	;;
esac
[[ -d "$repo_path" && "$issue_number" =~ ^[0-9]+$ ]] || {
	usage
	exit 2
}
repo_path=$(cd "$repo_path" && pwd -P) || exit 2
[[ "$confirmation" == "$expected_confirmation" ]] || {
	printf 'BLOCKED: exact recovery confirmation is required\n' >&2
	exit 1
}

REAL_GIT="${AIDEVOPS_REAL_GIT_BIN:-/usr/bin/git}"
git_dir=$("$REAL_GIT" -C "$repo_path" rev-parse --path-format=absolute --git-dir 2>/dev/null)
common_dir=$("$REAL_GIT" -C "$repo_path" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
[[ -n "$git_dir" && "$git_dir" == "$common_dir" ]] || {
	printf 'BLOCKED: recovery target is not the canonical worktree\n' >&2
	exit 1
}
if [[ "$cmd" != "$SYNC_MIRROR_CMD" ]] && [[ -n "$("$REAL_GIT" -C "$repo_path" status --porcelain)" ]]; then
	printf 'BLOCKED: canonical worktree is not clean\n' >&2
	exit 1
fi

policy_helper="${SCRIPT_DIR}/canonical-write-policy-helper.py"
[[ -f "$policy_helper" ]] || {
	printf 'BLOCKED: canonical branch policy helper is unavailable\n' >&2
	exit 1
}
target_branch=$(python3 "$policy_helper" resolve-branch --cwd "$repo_path" --field branch) || exit 1
target_branch_source=$(python3 "$policy_helper" resolve-branch --cwd "$repo_path" --field source) || exit 1
"$REAL_GIT" check-ref-format --branch "$target_branch" >/dev/null 2>&1 || {
	printf 'BLOCKED: resolved canonical branch is invalid\n' >&2
	exit 1
}

if [[ "$cmd" != "restore-default" ]]; then
	current_branch=$("$REAL_GIT" -C "$repo_path" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
	[[ -n "$current_branch" ]] || {
		printf 'BLOCKED: canonical worktree is detached\n' >&2
		exit 1
	}
	if [[ "$cmd" == "$FAST_FORWARD_CMD" && "$expected_branch" != "$target_branch" ]]; then
		printf 'BLOCKED: requested branch %s is not the resolved canonical branch %s\n' \
			"$expected_branch" "$target_branch" >&2
		exit 1
	fi
	[[ "$current_branch" == "$target_branch" ]] || {
		printf 'BLOCKED: canonical worktree is on %s, expected %s\n' "$current_branch" "$target_branch" >&2
		exit 1
	}
fi

occupied_path=""
while IFS= read -r line; do
	case "$line" in
	worktree\ *) occupied_path="${line#worktree }" ;;
	branch\ refs/heads/"$target_branch")
		if [[ "$occupied_path" != "$repo_path" ]]; then
			printf 'BLOCKED: target branch is active in another worktree: %s\n' "$occupied_path" >&2
			exit 1
		fi
		;;
	esac
done < <("$REAL_GIT" -C "$repo_path" worktree list --porcelain)

lock_dir="${common_dir}/aidevops-canonical-recovery.lock"
mkdir "$lock_dir" 2>/dev/null || {
	printf 'BLOCKED: canonical recovery lock is already held\n' >&2
	exit 1
}
trap 'rmdir "$lock_dir" 2>/dev/null || true' EXIT

local_ref="refs/heads/${target_branch}"
remote_ref="refs/remotes/origin/${target_branch}"
"$REAL_GIT" -C "$repo_path" fetch --no-tags origin \
	"+refs/heads/${target_branch}:${remote_ref}" >/dev/null 2>&1 || {
	printf 'BLOCKED: origin/%s tip could not be fetched\n' "$target_branch" >&2
	exit 1
}
target_sha=$("$REAL_GIT" -C "$repo_path" rev-parse --verify "${remote_ref}^{commit}" 2>/dev/null || true)
[[ -n "$target_sha" ]] || {
	printf 'BLOCKED: origin/%s tip cannot be resolved\n' "$target_branch" >&2
	exit 1
}
local_sha=$("$REAL_GIT" -C "$repo_path" rev-parse --verify "${local_ref}^{commit}" 2>/dev/null || true)
[[ -n "$local_sha" ]] || {
	printf 'BLOCKED: local %s tip cannot be resolved\n' "$target_branch" >&2
	exit 1
}

sync_backup_id=""
sync_backup_dir=""
if [[ "$cmd" == "$SYNC_MIRROR_CMD" ]]; then
	canonical_status=$("$REAL_GIT" -C "$repo_path" status --porcelain=v1) || {
		printf 'BLOCKED: canonical worktree status cannot be read safely\n' >&2
		exit 1
	}
	if [[ -n "$canonical_status" ]]; then
		backup_helper="${SCRIPT_DIR}/dirty-worktree-backup-helper.sh"
		[[ -f "$backup_helper" ]] || {
			printf 'BLOCKED: dirty-worktree backup helper is unavailable\n' >&2
			exit 1
		}
		backup_output=$(AIDEVOPS_REAL_GIT_BIN="$REAL_GIT" bash "$backup_helper" backup \
			--repo "$repo_path" --reason "canonical mirror synchronization" \
			--issue "$issue_number" \
			--operation-id "canonical-sync-${issue_number}-${target_sha}" --machine) || {
			printf 'BLOCKED: canonical dirty state could not be preserved\n' >&2
			exit 1
		}
		backup_record="${backup_output##*$'\n'}"
		IFS='|' read -r sync_backup_id sync_backup_dir <<<"$backup_record"
		[[ -n "$sync_backup_id" && -d "$sync_backup_dir" ]] || {
			printf 'BLOCKED: canonical backup evidence is incomplete\n' >&2
			exit 1
		}
		AIDEVOPS_REAL_GIT_BIN="$REAL_GIT" bash "$backup_helper" verify \
			--repo "$repo_path" --backup "$sync_backup_id" >/dev/null || {
			printf 'BLOCKED: canonical backup verification failed\n' >&2
			exit 1
		}
		AIDEVOPS_REAL_GIT_BIN="$REAL_GIT" bash "$backup_helper" matches \
			--repo "$repo_path" --backup "$sync_backup_id" >/dev/null || {
			printf 'BLOCKED: canonical state changed after backup\n' >&2
			exit 1
		}
		printf 'PRESERVED_BACKUP_ID=%s\n' "$sync_backup_id"
		printf 'PRESERVED_BACKUP_DIR=%s\n' "$sync_backup_dir"
		printf 'RESTORE_COMMAND=%q restore --repo %q --backup %q --confirm RESTORE_DIRTY_WORKTREE_BACKUP\n' \
			"$backup_helper" "$repo_path" "$sync_backup_id"
		AIDEVOPS_REAL_GIT_BIN="$REAL_GIT" bash "$backup_helper" clean \
			--repo "$repo_path" --backup "$sync_backup_id" \
			--confirm CLEAN_VERIFIED_DIRTY_WORKTREE_BACKUP >/dev/null || {
			printf 'BLOCKED: verified canonical state could not be cleaned\n' >&2
			exit 1
		}
	fi

	# shellcheck source=shared-constants.sh
	source "${SCRIPT_DIR}/shared-constants.sh"
	if ! declare -F remove_canonical_worktree_owner >/dev/null 2>&1 ||
		! remove_canonical_worktree_owner "$repo_path"; then
		printf 'BLOCKED: invalid canonical ownership could not be cleared safely\n' >&2
		exit 1
	fi
	current_branch=$("$REAL_GIT" -C "$repo_path" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
	current_local_sha=$("$REAL_GIT" -C "$repo_path" rev-parse --verify "${local_ref}^{commit}" 2>/dev/null || true)
	[[ "$target_branch" == "$current_branch" ]] || {
		printf 'BLOCKED: canonical branch changed during preservation\n' >&2
		exit 1
	}
	[[ "$local_sha" == "$current_local_sha" ]] || {
		printf 'BLOCKED: canonical local ref changed during preservation\n' >&2
		exit 1
	}
	[[ -z "$("$REAL_GIT" -C "$repo_path" status --porcelain)" ]] || {
		printf 'BLOCKED: canonical worktree remains dirty after preservation\n' >&2
		exit 1
	}
fi

preservation_ref=""
if [[ "$cmd" == "$FAST_FORWARD_CMD" ]] && ! "$REAL_GIT" -C "$repo_path" merge-base --is-ancestor "$local_ref" "$target_sha"; then
	printf 'BLOCKED: local %s has diverged from origin/%s\n' "$target_branch" "$target_branch" >&2
	exit 1
fi
if [[ "$cmd" != "$FAST_FORWARD_CMD" ]] && ! "$REAL_GIT" -C "$repo_path" merge-base --is-ancestor "$local_ref" "$target_sha"; then
	preservation_ref="refs/aidevops/canonical-recovery/issue-${issue_number}/${local_sha}"
	"$REAL_GIT" check-ref-format "$preservation_ref" >/dev/null || {
		printf 'BLOCKED: canonical preservation ref is invalid\n' >&2
		exit 1
	}
fi

audit_helper="${SCRIPT_DIR}/audit-log-helper.sh"
recovery_audit_file="${HOME}/.aidevops/logs/canonical-recovery-audit.jsonl"
[[ -x "$audit_helper" ]] || {
	printf 'BLOCKED: tamper-evident audit helper is unavailable\n' >&2
	exit 1
}
AUDIT_LOG_FILE="$recovery_audit_file" "$audit_helper" verify --quiet || {
	printf 'BLOCKED: audit chain verification failed\n' >&2
	exit 1
}
audit_message="Canonical default-branch recovery authorized"
[[ "$cmd" == "$FAST_FORWARD_CMD" ]] && audit_message="Canonical current-branch fast-forward authorized"
[[ "$cmd" == "$SYNC_MIRROR_CMD" ]] && audit_message="Canonical mirror synchronization authorized"
AUDIT_LOG_FILE="$recovery_audit_file" AUDIT_QUIET=true "$audit_helper" log operation.verify "$audit_message" \
	--detail "issue=${issue_number}" --detail "repo=${repo_path}" \
	--detail "operation=${cmd}" --detail "target=${target_branch}" --detail "target_source=${target_branch_source}" \
	--detail "target_sha=${target_sha}" --detail "local_sha=${local_sha}" \
	--detail "preservation_ref=${preservation_ref:-none}" --detail "backup_id=${sync_backup_id:-none}" >/dev/null || {
	printf 'BLOCKED: recovery audit record could not be written\n' >&2
	exit 1
}

[[ "$("$REAL_GIT" -C "$repo_path" rev-parse --verify "${remote_ref}^{commit}")" == "$target_sha" ]] || {
	printf 'BLOCKED: origin/%s tip changed during recovery\n' "$target_branch" >&2
	exit 1
}
[[ "$("$REAL_GIT" -C "$repo_path" rev-parse --verify "${local_ref}^{commit}")" == "$local_sha" ]] || {
	printf 'BLOCKED: local %s tip changed during recovery\n' "$target_branch" >&2
	exit 1
}
if [[ "$cmd" == "$SYNC_MIRROR_CMD" && -n "$preservation_ref" ]]; then
	existing_preservation_sha=$("$REAL_GIT" -C "$repo_path" rev-parse --verify "${preservation_ref}^{commit}" 2>/dev/null || true)
	if [[ -n "$existing_preservation_sha" && "$existing_preservation_sha" != "$local_sha" ]]; then
		printf 'BLOCKED: canonical preservation ref already points elsewhere\n' >&2
		exit 1
	fi
	if [[ -z "$existing_preservation_sha" ]]; then
		"$REAL_GIT" -C "$repo_path" update-ref "$preservation_ref" "$local_sha" \
			"0000000000000000000000000000000000000000" || {
			printf 'BLOCKED: canonical preservation ref could not be created\n' >&2
			exit 1
		}
	fi
	[[ "$("$REAL_GIT" -C "$repo_path" rev-parse --verify "${preservation_ref}^{commit}")" == "$local_sha" ]] || {
		printf 'BLOCKED: divergent canonical commit was not preserved\n' >&2
		exit 1
	}
fi
if [[ "$cmd" == "$FAST_FORWARD_CMD" || "$cmd" == "$SYNC_MIRROR_CMD" ]]; then
	fast_forward_reflog="aidevops canonical fast-forward"
	[[ "$cmd" == "$SYNC_MIRROR_CMD" ]] && fast_forward_reflog="aidevops canonical mirror synchronization"
	current_branch=$("$REAL_GIT" -C "$repo_path" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
	[[ "$current_branch" == "$target_branch" ]] || {
		printf 'BLOCKED: canonical branch changed during fast-forward\n' >&2
		exit 1
	}
	[[ -z "$("$REAL_GIT" -C "$repo_path" status --porcelain)" ]] || {
		printf 'BLOCKED: canonical worktree changed during fast-forward\n' >&2
		exit 1
	}
	"$REAL_GIT" -C "$repo_path" read-tree --dry-run -u -m "$local_sha" "$target_sha" || {
		printf 'BLOCKED: canonical worktree cannot be updated without overwriting local changes\n' >&2
		exit 1
	}
	if [[ -n "${AIDEVOPS_CANONICAL_BEFORE_REF_UPDATE_HOOK:-}" ]]; then
		"$AIDEVOPS_CANONICAL_BEFORE_REF_UPDATE_HOOK" "$repo_path" "$target_branch" "$local_sha" "$target_sha" || {
			printf 'BLOCKED: canonical pre-update hook failed\n' >&2
			exit 1
		}
	fi
	if ! printf '%s\n' \
		'start' \
		"verify ${remote_ref} ${target_sha}" \
		"update ${local_ref} ${target_sha} ${local_sha}" \
		'prepare' \
		'commit' | "$REAL_GIT" -C "$repo_path" update-ref \
		-m "${fast_forward_reflog} for issue ${issue_number}" --stdin >/dev/null; then
		printf 'BLOCKED: canonical local or origin ref changed during fast-forward\n' >&2
		exit 1
	fi
	current_branch=$("$REAL_GIT" -C "$repo_path" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
	current_remote_sha=$("$REAL_GIT" -C "$repo_path" rev-parse --verify "${remote_ref}^{commit}" 2>/dev/null || true)
	if [[ "$current_branch" != "$target_branch" || "$current_remote_sha" != "$target_sha" ]]; then
		if ! "$REAL_GIT" -C "$repo_path" update-ref \
			-m "${fast_forward_reflog} rollback for issue ${issue_number}" \
			"$local_ref" "$local_sha" "$target_sha"; then
			printf 'CRITICAL: canonical branch changed after compare-and-swap and the local ref rollback failed\n' >&2
			exit 1
		fi
		printf 'BLOCKED: canonical branch or origin ref changed during fast-forward; local ref rolled back\n' >&2
		exit 1
	fi
	if [[ -n "${AIDEVOPS_CANONICAL_BEFORE_WORKTREE_UPDATE_HOOK:-}" ]]; then
		if ! "$AIDEVOPS_CANONICAL_BEFORE_WORKTREE_UPDATE_HOOK" "$repo_path" "$target_branch" "$local_sha" "$target_sha"; then
			if ! "$REAL_GIT" -C "$repo_path" update-ref \
				-m "${fast_forward_reflog} rollback for issue ${issue_number}" \
				"$local_ref" "$local_sha" "$target_sha"; then
				printf 'CRITICAL: canonical pre-worktree-update hook failed and the local ref rollback also failed\n' >&2
				exit 1
			fi
			printf 'BLOCKED: canonical pre-worktree-update hook failed\n' >&2
			exit 1
		fi
	fi
	if ! "$REAL_GIT" -C "$repo_path" read-tree -u -m "$local_sha" "$target_sha"; then
		if ! "$REAL_GIT" -C "$repo_path" update-ref \
			-m "${fast_forward_reflog} rollback for issue ${issue_number}" \
			"$local_ref" "$local_sha" "$target_sha"; then
			printf 'CRITICAL: canonical worktree update failed and the local ref rollback also failed\n' >&2
			exit 1
		fi
		printf 'BLOCKED: canonical worktree update failed; local ref rolled back\n' >&2
		exit 1
	fi
	post_update_branch=$("$REAL_GIT" -C "$repo_path" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
	post_update_remote_sha=$("$REAL_GIT" -C "$repo_path" rev-parse --verify "${remote_ref}^{commit}" 2>/dev/null || true)
	if [[ "$post_update_branch" != "$target_branch" || "$post_update_remote_sha" != "$target_sha" ]]; then
		if [[ "$post_update_branch" == "$target_branch" ]]; then
			restore_worktree_sha="$local_sha"
		else
			restore_worktree_sha=$("$REAL_GIT" -C "$repo_path" rev-parse --verify "HEAD^{commit}" 2>/dev/null || true)
		fi
		if ! "$REAL_GIT" -C "$repo_path" update-ref \
			-m "${fast_forward_reflog} rollback for issue ${issue_number}" \
			"$local_ref" "$local_sha" "$target_sha"; then
			printf 'CRITICAL: canonical state changed after the worktree update and the local ref rollback failed\n' >&2
			exit 1
		fi
		[[ -n "$restore_worktree_sha" ]] || restore_worktree_sha="$local_sha"
		if ! "$REAL_GIT" -C "$repo_path" read-tree --dry-run -u -m "$target_sha" "$restore_worktree_sha" ||
			! "$REAL_GIT" -C "$repo_path" read-tree -u -m "$target_sha" "$restore_worktree_sha"; then
			printf 'CRITICAL: canonical ref was rolled back but the concurrent branch worktree could not be restored\n' >&2
			exit 1
		fi
		current_head_sha=$("$REAL_GIT" -C "$repo_path" rev-parse --verify "HEAD^{commit}" 2>/dev/null || true)
		if [[ "$current_head_sha" != "$restore_worktree_sha" ]] ||
			[[ -n "$("$REAL_GIT" -C "$repo_path" status --porcelain)" ]]; then
			printf 'CRITICAL: canonical ref was rolled back but the concurrent branch remains inconsistent\n' >&2
			exit 1
		fi
		printf 'BLOCKED: canonical branch or origin ref changed during worktree update; ref and worktree restored\n' >&2
		exit 1
	fi
	[[ "$("$REAL_GIT" -C "$repo_path" rev-parse HEAD)" == "$target_sha" ]] || exit 1
	[[ "$("$REAL_GIT" -C "$repo_path" rev-parse --verify "${local_ref}^{commit}")" == "$target_sha" ]] || exit 1
	[[ "$("$REAL_GIT" -C "$repo_path" rev-parse --verify "${remote_ref}^{commit}")" == "$target_sha" ]] || exit 1
	[[ -z "$("$REAL_GIT" -C "$repo_path" status --porcelain)" ]] || exit 1
	if [[ "$cmd" == "$SYNC_MIRROR_CMD" ]]; then
		printf 'SYNCHRONIZED_CANONICAL_MIRROR=true\n'
		printf 'OLD_SHA=%s\n' "$local_sha"
		printf 'NEW_SHA=%s\n' "$target_sha"
		printf 'CANONICAL_BRANCH=%s\n' "$target_branch"
		printf 'BRANCH_SOURCE=%s\n' "$target_branch_source"
		printf 'PRESERVATION_REF=%s\n' "${preservation_ref:-none}"
	else
		printf 'Fast-forwarded canonical %s to origin/%s\n' "$target_branch" "$target_branch"
	fi
	exit 0
fi
if [[ -n "$preservation_ref" ]]; then
	existing_preservation_sha=$("$REAL_GIT" -C "$repo_path" rev-parse --verify "${preservation_ref}^{commit}" 2>/dev/null || true)
	if [[ -n "$existing_preservation_sha" && "$existing_preservation_sha" != "$local_sha" ]]; then
		printf 'BLOCKED: canonical preservation ref already points elsewhere\n' >&2
		exit 1
	fi
	if [[ -z "$existing_preservation_sha" ]]; then
		"$REAL_GIT" -C "$repo_path" update-ref "$preservation_ref" "$local_sha" "0000000000000000000000000000000000000000"
	fi
	[[ "$("$REAL_GIT" -C "$repo_path" rev-parse --verify "${preservation_ref}^{commit}")" == "$local_sha" ]] || {
		printf 'BLOCKED: divergent canonical commit was not preserved\n' >&2
		exit 1
	}
	"$REAL_GIT" -C "$repo_path" update-ref "$local_ref" "$target_sha" "$local_sha"
fi
"$REAL_GIT" -C "$repo_path" switch "$target_branch"
[[ "$("$REAL_GIT" -C "$repo_path" branch --show-current)" == "$target_branch" ]] || exit 1
"$REAL_GIT" -C "$repo_path" merge --ff-only "$target_sha"
[[ "$("$REAL_GIT" -C "$repo_path" rev-parse HEAD)" == "$target_sha" ]] || exit 1
[[ "$("$REAL_GIT" -C "$repo_path" rev-parse --verify "${remote_ref}^{commit}")" == "$target_sha" ]] || exit 1
if [[ -n "$preservation_ref" ]]; then
	printf 'Preserved divergent canonical tip %s at %s\n' "$local_sha" "$preservation_ref"
fi
printf 'Restored canonical repository to %s\n' "$target_branch"
