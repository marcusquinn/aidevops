#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1

usage() {
	printf 'Usage: canonical-recovery-helper.sh restore-default --repo PATH --issue N --confirm RESTORE_CANONICAL_DEFAULT\n'
	return 0
}

cmd="${1:-}"
shift || true
repo_path=""
issue_number=""
confirmation=""
while [[ $# -gt 0 ]]; do
	case "$1" in
	--repo) repo_path="${2:-}"; shift 2 ;;
	--issue) issue_number="${2:-}"; shift 2 ;;
	--confirm) confirmation="${2:-}"; shift 2 ;;
	*) usage; exit 2 ;;
	esac
done

[[ "$cmd" == "restore-default" ]] || { usage; exit 2; }
[[ -d "$repo_path" && "$issue_number" =~ ^[0-9]+$ ]] || { usage; exit 2; }
[[ "$confirmation" == "RESTORE_CANONICAL_DEFAULT" ]] || {
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
[[ -z "$("$REAL_GIT" -C "$repo_path" status --porcelain)" ]] || {
	printf 'BLOCKED: canonical worktree is not clean\n' >&2
	exit 1
}

default_branch=$("$REAL_GIT" -C "$repo_path" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
default_branch="${default_branch#origin/}"
[[ -n "$default_branch" ]] || {
	printf 'BLOCKED: origin default branch cannot be resolved\n' >&2
	exit 1
}

occupied_path=""
while IFS= read -r line; do
	case "$line" in
	worktree\ *) occupied_path="${line#worktree }" ;;
	branch\ refs/heads/"$default_branch")
		if [[ "$occupied_path" != "$repo_path" ]]; then
			printf 'BLOCKED: default branch is active in another worktree: %s\n' "$occupied_path" >&2
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

local_ref="refs/heads/${default_branch}"
remote_ref="refs/remotes/origin/${default_branch}"
"$REAL_GIT" -C "$repo_path" fetch --no-tags origin \
	"+refs/heads/${default_branch}:${remote_ref}" >/dev/null 2>&1 || {
	printf 'BLOCKED: origin default branch tip could not be fetched\n' >&2
	exit 1
}
target_sha=$("$REAL_GIT" -C "$repo_path" rev-parse --verify "${remote_ref}^{commit}" 2>/dev/null || true)
[[ -n "$target_sha" ]] || {
	printf 'BLOCKED: origin default branch tip cannot be resolved\n' >&2
	exit 1
}
local_sha=$("$REAL_GIT" -C "$repo_path" rev-parse --verify "${local_ref}^{commit}" 2>/dev/null || true)
[[ -n "$local_sha" ]] || {
	printf 'BLOCKED: local default branch tip cannot be resolved\n' >&2
	exit 1
}
preservation_ref=""
if ! "$REAL_GIT" -C "$repo_path" merge-base --is-ancestor "$local_ref" "$target_sha"; then
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
AUDIT_LOG_FILE="$recovery_audit_file" AUDIT_QUIET=true "$audit_helper" log operation.verify "Canonical default-branch recovery authorized" \
	--detail "issue=${issue_number}" --detail "repo=${repo_path}" \
	--detail "target=${default_branch}" --detail "target_sha=${target_sha}" \
	--detail "local_sha=${local_sha}" --detail "preservation_ref=${preservation_ref:-none}" >/dev/null || {
	printf 'BLOCKED: recovery audit record could not be written\n' >&2
	exit 1
}

[[ "$("$REAL_GIT" -C "$repo_path" rev-parse --verify "${remote_ref}^{commit}")" == "$target_sha" ]] || {
	printf 'BLOCKED: origin default branch tip changed during recovery\n' >&2
	exit 1
}
[[ "$("$REAL_GIT" -C "$repo_path" rev-parse --verify "${local_ref}^{commit}")" == "$local_sha" ]] || {
	printf 'BLOCKED: local default branch tip changed during recovery\n' >&2
	exit 1
}
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
"$REAL_GIT" -C "$repo_path" switch "$default_branch"
[[ "$("$REAL_GIT" -C "$repo_path" branch --show-current)" == "$default_branch" ]] || exit 1
"$REAL_GIT" -C "$repo_path" merge --ff-only "$target_sha"
[[ "$("$REAL_GIT" -C "$repo_path" rev-parse HEAD)" == "$target_sha" ]] || exit 1
[[ "$("$REAL_GIT" -C "$repo_path" rev-parse --verify "${remote_ref}^{commit}")" == "$target_sha" ]] || exit 1
if [[ -n "$preservation_ref" ]]; then
	printf 'Preserved divergent canonical tip %s at %s\n' "$local_sha" "$preservation_ref"
fi
printf 'Restored canonical repository to %s\n' "$default_branch"
