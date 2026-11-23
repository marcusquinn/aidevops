#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail
# Supports: sync-mirror --repo PATH --reason aidevops-update
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
FAST_FORWARD_CMD="fast-forward-current"
SYNC_MIRROR_CMD="sync-mirror"
LOCAL_FAST_FORWARD_CMD="fast-forward-local"
VERIFY_BOOTSTRAP_CMD="verify-bootstrap-registration"
REPAIR_UPSTREAM_CMD="repair-upstream"
REPAIR_WORKTREES_CMD="repair-worktrees"
FOLLOW_TRANSFER_CMD="follow-transfer"
CLEAR_STALE_REBASE_CMD="clear-stale-rebase"
CLEAR_ABANDONED_REBASE_CMD="clear-abandoned-rebase"
AIDEVOPS_UPDATE_REASON="aidevops-update"
#aidevops:trust-boundary
# Framework maintenance pins its upstream identity here instead of trusting a
# downstream project registration or a caller-controlled remote name.
AIDEVOPS_FRAMEWORK_GITHUB_SLUG="marcusquinn/aidevops"
ABANDONED_REBASE_MIN_AGE_SECONDS=86400
ABANDONED_REBASE_KIND="abandoned"
HEAD_COMMIT_EXPR='HEAD^{commit}'
NULL_SHA1="0000000000000000000000000000000000000000"
LOCAL_STATE_BORN="born"
LOCAL_STATE_UNBORN="unborn"
BOOLEAN_TRUE="true"

# shellcheck source=./canonical-recovery-state.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/canonical-recovery-state.sh"
# shellcheck source=./canonical-recovery-rebase.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/canonical-recovery-rebase.sh"
# shellcheck source=./canonical-recovery-ffl.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/canonical-recovery-ffl.sh"
# shellcheck source=./canonical-recovery-lock.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/canonical-recovery-lock.sh"
# shellcheck source=./canonical-recovery-hygiene.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/canonical-recovery-hygiene.sh"
# shellcheck source=./worker-lifecycle-state.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/worker-lifecycle-state.sh"


usage() {
	printf '%s\n' \
		'Usage:' \
		"  canonical-recovery-helper.sh ${LOCAL_FAST_FORWARD_CMD} --repo PATH --from-branch BRANCH --task tNNN --confirm FAST_FORWARD_LOCAL_CANONICAL" \
		'  canonical-recovery-helper.sh restore-default --repo PATH --issue N --confirm RESTORE_CANONICAL_DEFAULT' \
		"  canonical-recovery-helper.sh ${CLEAR_STALE_REBASE_CMD} --repo PATH --issue N --confirm CLEAR_CONVERGED_STALE_REBASE" \
		"  canonical-recovery-helper.sh ${CLEAR_ABANDONED_REBASE_CMD} --repo PATH --issue N --confirm CLEAR_ABANDONED_STALE_REBASE" \
		"  canonical-recovery-helper.sh ${FAST_FORWARD_CMD} --repo PATH --branch BRANCH --issue N --confirm FAST_FORWARD_CANONICAL_BRANCH" \
		"  canonical-recovery-helper.sh ${FAST_FORWARD_CMD} --repo PATH --branch BRANCH --reason ${AIDEVOPS_UPDATE_REASON} --confirm FAST_FORWARD_CANONICAL_BRANCH" \
		"  canonical-recovery-helper.sh ${SYNC_MIRROR_CMD} --repo PATH --issue N --confirm SYNCHRONIZE_CANONICAL_MIRROR" \
		"  canonical-recovery-helper.sh ${SYNC_MIRROR_CMD} --repo PATH --reason ${AIDEVOPS_UPDATE_REASON} --confirm SYNCHRONIZE_CANONICAL_MIRROR" \
		"  canonical-recovery-helper.sh ${REPAIR_UPSTREAM_CMD} --repo PATH --issue N --confirm REPAIR_CANONICAL_UPSTREAM" \
		"  canonical-recovery-helper.sh ${REPAIR_WORKTREES_CMD} --repo PATH [--issue N] --confirm REPAIR_WORKTREE_POINTERS" \
		"  canonical-recovery-helper.sh ${FOLLOW_TRANSFER_CMD} --repo PATH --slug OWNER/REPO --confirm FOLLOW_REPOSITORY_TRANSFER" \
		"  canonical-recovery-helper.sh ${VERIFY_BOOTSTRAP_CMD} --repo PATH --slug OWNER/REPO --confirm REGISTER_CANONICAL_REPOSITORY" \
		"  canonical-recovery-helper.sh ${CGH_REPAIR_CMD} --repo PATH [--min-age-minutes N] [--tmp-min-age-days N] [--apply]" \
		"  canonical-recovery-helper.sh ${CGH_GC_CMD} --repo PATH [--min-age-minutes N] [--tmp-min-age-days N] [--apply]"
	return 0
}

# Enrolled trees keep the old admin path in their generation marker; re-bind is
# a separate, journaled step that proves inodes before accepting the move.
_emit_rebind_followups() {
	local registry_entry="${SCRIPT_DIR}/../worker-lifecycle/worker-registry.py"
	local state_dir="" wt_path=""
	state_dir=$(worker_lifecycle_state_dir) || state_dir=""
	if [[ -z "$state_dir" || ! -d "$state_dir" ]]; then
		printf 'REBIND_UNAVAILABLE: existing lifecycle registry unavailable; no registry created\n'
		return 0
	fi
	for wt_path in "$@"; do
		printf 'REBIND_FOLLOWUP: python3 %q --state-dir %q rebind-moved-worktree --path %q\n' \
			"$registry_entry" "$state_dir" "$wt_path"
	done
	return 0
}

# Mend linked-worktree pointers after a canonical checkout was moved or renamed.
# Runs `git worktree repair` with each worktree path recorded in the admin dir,
# audits the operation and prints every worktree `.git` pointer it rewrote.
repair_worktree_pointers() {
	local repo="$1"
	local common="$2"
	local issue="$3"
	local audit_file="${HOME}/.aidevops/logs/canonical-recovery-audit.jsonl"
	local audit_tool="${SCRIPT_DIR}/audit-log-helper.sh"
	local gitdir_file="" wt_git="" wt_path="" before="" after="" changed=0 i=0
	local -a wt_paths=() wt_befores=()

	[[ -x "$audit_tool" ]] || {
		printf 'BLOCKED: tamper-evident audit helper is unavailable\n' >&2
		return 1
	}
	AUDIT_LOG_FILE="$audit_file" "$audit_tool" verify --quiet || {
		printf 'BLOCKED: audit chain verification failed\n' >&2
		return 1
	}
	for gitdir_file in "${common}"/worktrees/*/gitdir; do
		[[ -f "$gitdir_file" ]] || continue
		wt_git=$(<"$gitdir_file")
		wt_path="${wt_git%/.git}"
		[[ -d "$wt_path" && -f "${wt_path}/.git" ]] || continue
		wt_paths+=("$wt_path")
		wt_befores+=("$(<"${wt_path}/.git")")
	done
	AUDIT_LOG_FILE="$audit_file" AUDIT_QUIET=true "$audit_tool" log \
		operation.verify "Canonical worktree pointer repair authorized" \
		--detail "issue=${issue}" --detail "repo=${repo}" \
		--detail "operation=${REPAIR_WORKTREES_CMD}" \
		--detail "worktrees=${#wt_paths[@]}" >/dev/null || {
		printf 'BLOCKED: recovery audit record could not be written\n' >&2
		return 1
	}
	"$REAL_GIT" -C "$repo" worktree repair "${wt_paths[@]+"${wt_paths[@]}"}" || {
		printf 'BLOCKED: git worktree repair failed\n' >&2
		return 1
	}
	for ((i = 0; i < ${#wt_paths[@]}; i++)); do
		before="${wt_befores[$i]}"
		after=$(<"${wt_paths[$i]}/.git")
		if [[ "$before" != "$after" ]]; then
			printf 'REWROTE: %s: %s -> %s\n' "${wt_paths[$i]}" "$before" "$after"
			changed=$((changed + 1))
		fi
	done
	printf 'REPAIRED_WORKTREE_POINTERS=%s\n' "$changed"
	_emit_rebind_followups "${wt_paths[@]+"${wt_paths[@]}"}"
	return 0
}

cmd="${1:-}"
shift || true
# GH#39722: stale Git lock/pack debris repair and sanctioned canonical gc use
# their own dry-run-first argument contract.
if [[ "$cmd" == "$CGH_REPAIR_CMD" || "$cmd" == "$CGH_GC_CMD" ]]; then
	hygiene_rc=0
	cgh_main "$cmd" "$@" || hygiene_rc=$?
	exit "$hygiene_rc"
fi
repo_path=""
issue_number=""
maintenance_reason=""
confirmation=""
expected_branch=""
bootstrap_slug=""
from_branch=""
task_id=""
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
	--reason)
		maintenance_reason="${2:-}"
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
	--slug)
		bootstrap_slug="${2:-}"
		shift 2
		;;
	--from-branch)
		from_branch="${2:-}"
		shift 2
		;;
	--task)
		task_id="${2:-}"
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
"$CLEAR_STALE_REBASE_CMD")
	expected_confirmation="CLEAR_CONVERGED_STALE_REBASE"
	[[ -z "$expected_branch" ]] || {
		usage
		exit 2
	}
	;;
"$CLEAR_ABANDONED_REBASE_CMD")
	expected_confirmation="CLEAR_ABANDONED_STALE_REBASE"
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
"$LOCAL_FAST_FORWARD_CMD")
	expected_confirmation="FAST_FORWARD_LOCAL_CANONICAL"
	[[ -z "$expected_branch" && -n "$from_branch" && "$task_id" =~ ^t[0-9]+$ ]] || {
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
"$REPAIR_UPSTREAM_CMD")
	expected_confirmation="REPAIR_CANONICAL_UPSTREAM"
	[[ -z "$expected_branch" ]] || {
		usage
		exit 2
	}
	;;
"$REPAIR_WORKTREES_CMD")
	expected_confirmation="REPAIR_WORKTREE_POINTERS"
	[[ -z "$expected_branch" && -z "$maintenance_reason" ]] || {
		usage
		exit 2
	}
	;;
"$FOLLOW_TRANSFER_CMD")
	expected_confirmation="FOLLOW_REPOSITORY_TRANSFER"
	[[ -z "$expected_branch" && "$bootstrap_slug" =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$ ]] || {
		usage
		exit 2
	}
	;;
"$VERIFY_BOOTSTRAP_CMD")
	expected_confirmation="REGISTER_CANONICAL_REPOSITORY"
	[[ -z "$expected_branch" && "$bootstrap_slug" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || {
		usage
		exit 2
	}
	;;
*)
	usage
	exit 2
	;;
esac
if [[ "$cmd" != "$VERIFY_BOOTSTRAP_CMD" && "$cmd" != "$FOLLOW_TRANSFER_CMD" && -n "$bootstrap_slug" ]]; then
	usage
	exit 2
fi
[[ -d "$repo_path" ]] || {
	usage
	exit 2
}
if [[ "$cmd" != "$LOCAL_FAST_FORWARD_CMD" && (-n "$from_branch" || -n "$task_id") ]]; then
	usage
	exit 2
fi
if [[ "$cmd" == "$LOCAL_FAST_FORWARD_CMD" ]]; then
	[[ -z "$issue_number" && -z "$maintenance_reason" ]] || {
		usage
		exit 2
	}
	audit_reference="task ${task_id}"
elif [[ "$cmd" == "$VERIFY_BOOTSTRAP_CMD" && -z "$issue_number" && -z "$maintenance_reason" ]]; then
	audit_reference="bootstrap registration"
elif [[ "$cmd" == "$FOLLOW_TRANSFER_CMD" && -z "$issue_number" && -z "$maintenance_reason" ]]; then
	audit_reference="repository transfer"
elif [[ "$cmd" == "$REPAIR_WORKTREES_CMD" && -z "$issue_number" ]]; then
	audit_reference="worktree pointer repair"
elif [[ "$issue_number" =~ ^[0-9]+$ && -z "$maintenance_reason" ]]; then
	audit_reference="issue ${issue_number}"
elif [[ -z "$issue_number" && ("$cmd" == "$FAST_FORWARD_CMD" || "$cmd" == "$SYNC_MIRROR_CMD") &&
	"$maintenance_reason" == "$AIDEVOPS_UPDATE_REASON" ]]; then
	audit_reference="reason ${maintenance_reason}"
else
	usage
	exit 2
fi
repo_path=$(cd "$repo_path" && pwd -P) || exit 2
[[ "$confirmation" == "$expected_confirmation" ]] || {
	printf 'BLOCKED: exact recovery confirmation is required\n' >&2
	exit 1
}

# shellcheck source=runtime-env.sh
source "${SCRIPT_DIR}/runtime-env.sh"
REAL_GIT="${AIDEVOPS_REAL_GIT_BIN:-aidevops-native-git-not-found}"
git_dir=$("$REAL_GIT" -C "$repo_path" rev-parse --path-format=absolute --git-dir 2>/dev/null)
common_dir=$("$REAL_GIT" -C "$repo_path" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
[[ -n "$git_dir" && "$git_dir" == "$common_dir" ]] || {
	printf 'BLOCKED: recovery target is not the canonical worktree\n' >&2
	exit 1
}
if [[ "$cmd" == "$REPAIR_WORKTREES_CMD" ]]; then
	repair_worktree_pointers "$repo_path" "$common_dir" "${issue_number:-none}"
	exit $?
fi
if [[ "$cmd" == "$LOCAL_FAST_FORWARD_CMD" ]]; then
	fast_forward_local "$repo_path" "$from_branch" "$task_id"
	exit $?
fi
if [[ "$cmd" == "$FAST_FORWARD_CMD" ]]; then
	# GH#34770: a fast-forward accepts untracked-only state. It is preserved and
	# cleaned below, then reinstated without overwriting after verification.
	ff_tracked_status=$("$REAL_GIT" -C "$repo_path" status --porcelain=v1 --untracked-files=no) || {
		printf 'BLOCKED: canonical tracked/index state cannot be read safely\n' >&2
		exit 1
	}
	[[ -z "$ff_tracked_status" ]] || {
		printf 'BLOCKED: canonical worktree is not clean\n' >&2
		exit 1
	}
elif [[ "$cmd" != "$SYNC_MIRROR_CMD" && "$cmd" != "$VERIFY_BOOTSTRAP_CMD" ]] &&
	[[ -n "$("$REAL_GIT" -C "$repo_path" status --porcelain)" ]]; then
	printf 'BLOCKED: canonical worktree is not clean\n' >&2
	exit 1
fi

registered_slug=""
expected_slug=""
allow_local_mirror=true
allow_equivalent_aliases=false
#aidevops:trust-boundary
# Only framework self-update has an identity pinned independently of repository
# registration, so ordinary canonical recovery keeps rejecting multiple aliases.
if [[ "$cmd" == "$VERIFY_BOOTSTRAP_CMD" ]]; then
	expected_slug="$bootstrap_slug"
	allow_local_mirror=false
elif [[ "$maintenance_reason" == "$AIDEVOPS_UPDATE_REASON" ]]; then
	expected_slug="$AIDEVOPS_FRAMEWORK_GITHUB_SLUG"
	allow_local_mirror=false
	allow_equivalent_aliases=true
else
	registered_slug=$(registered_repo_slug "$repo_path") || {
		printf 'BLOCKED: registered canonical repository identity is invalid or ambiguous\n' >&2
		exit 1
	}
	if [[ -z "$registered_slug" ]]; then
		printf 'BLOCKED: repository is not registered in repos.json; register it with: aidevops repos add --slug OWNER/REPO --confirm REGISTER_CANONICAL_REPOSITORY\n' >&2
		exit 1
	fi
	expected_slug="$registered_slug"
fi
if ! canonical_remote=$(resolve_github_remote \
	"$repo_path" "$expected_slug" "$allow_local_mirror" "$allow_equivalent_aliases"); then
	if [[ "$cmd" == "$VERIFY_BOOTSTRAP_CMD" ]]; then
		printf 'BLOCKED: pinned bootstrap GitHub remote is missing, mismatched, or ambiguous\n' >&2
	elif [[ "$maintenance_reason" == "$AIDEVOPS_UPDATE_REASON" ]]; then
		printf 'BLOCKED: official aidevops GitHub remote is missing, mismatched, or ambiguous\n' >&2
	else
		printf 'BLOCKED: registered GitHub remote is missing, mismatched, or ambiguous\n' >&2
	fi
	exit 1
fi
if [[ "$cmd" == "$VERIFY_BOOTSTRAP_CMD" ]]; then
	audit_bootstrap_identity "$repo_path" "$expected_slug" "$canonical_remote" || exit 1
	printf 'VERIFIED: canonical bootstrap identity %s via remote %s\n' "$expected_slug" "$canonical_remote"
	exit 0
fi
if [[ "$cmd" == "$FOLLOW_TRANSFER_CMD" ]]; then
	[[ "$canonical_remote" == "origin" ]] || {
		printf 'BLOCKED: transfer following requires the registered GitHub origin\n' >&2
		exit 1
	}
	transfer_lock="${common_dir}/aidevops-canonical-recovery.lock"
	crl_acquire "$transfer_lock" "$cmd" || {
		printf 'BLOCKED: canonical recovery lock is already held\n' >&2
		exit 1
	}
	trap 'crl_release "$transfer_lock"' EXIT
	trap 'exit 143' TERM
	# The native Git entrypoint is restricted to this audited recovery operation.
	# No fetch, ref update, checkout, transfer API write, or layout move occurs here.
	python3 - "$repo_path" "$registered_slug" "$bootstrap_slug" \
		"${AIDEVOPS_REPOS_CONFIG:-${HOME}/.config/aidevops/repos.json}" "$REAL_GIT" "$SCRIPT_DIR" <<'PY'
import fcntl
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile

repo, old_slug, new_slug, config_name, git, scripts = sys.argv[1:]
config = Path(config_name).expanduser()
audit = str(Path(scripts) / "audit-log-helper.sh")
origin = 'origin'
remote_command = "remote"
canonical_name = "full_name"
slug_key = "slug"
audit_env = dict(os.environ, AUDIT_QUIET="true",
                 AUDIT_LOG_FILE=str(Path.home() / ".aidevops/logs/canonical-recovery-audit.jsonl"))

def run(*args, env=None):
    return subprocess.run(args, check=True, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, env=env, timeout=60).stdout.strip()

def git_values(key, local_only=False):
    scope = ["--local"] if local_only else []
    result = subprocess.run([git, '-C', repo, "config", *scope, "--get-all", key],
                            text=True, capture_output=True)
    if result.returncode not in (0, 1):
        raise ValueError("cannot enumerate origin configuration")
    return result.stdout.splitlines()

def audit_record(event, message, identity):
    details = ["operation=follow-transfer", f"repo={repo}", f"old_slug={old_slug}",
               f"new_slug={new_slug}", f"repository_id={identity}"]
    args = [arg for detail in details for arg in ("--detail", detail)]
    run(audit, "log", event, message, *args, env=audit_env)

def resolved_origin_matches(expected):
    return (run(git, '-C', repo, remote_command, "get-url", origin) == expected
            and run(git, '-C', repo, remote_command, "get-url", "--push", origin) == expected)

def apply_transfer():
    # Serialize this operation across repos sharing the registry; compare the
    # original bytes too, so unrelated registry changes are never overwritten.
    if config.is_symlink():
        raise ValueError("repos.json must not be a symlink")
    with open(str(config) + ".follow-transfer.lock", "a", encoding="utf-8") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        before = config.read_bytes()
        registry = json.loads(before)
        entries = registry["initialized_repos"]
        matches = [entry for entry in entries if
                   Path(entry.get("path", entry.get("repo_path", ''))).expanduser().resolve() == Path(repo)]
        if len(matches) != 1 or matches[0].get(slug_key, '').casefold() != old_slug.casefold():
            raise ValueError("canonical registration is missing, ambiguous, or changed")
        if any(entry is not matches[0] and entry.get(slug_key, '').casefold() == new_slug.casefold()
               for entry in entries):
            raise ValueError("target slug is already registered at another path")
        url_key = "remote.origin.url"
        push_key = "remote.origin.pushurl"
        urls = git_values(url_key)
        if len(urls) != 1 or git_values(push_key) or git_values(url_key, local_only=True) != urls:
            raise ValueError("origin requires one repository-local URL and no explicit push URL")
        old_url = urls[0]
        pattern = r"(git@github\.com:|(?:https|http|git)://github\.com(?::[0-9]+)?/|ssh://git@github\.com(?::[0-9]+)?/)([^/?#]+/[^/?#]+?)(\.git)?"
        match = re.fullmatch(pattern, old_url)
        if not match or match[2].casefold() != old_slug.casefold():
            raise ValueError("origin URL does not match the registered GitHub slug")
        if not resolved_origin_matches(old_url):
            raise ValueError("origin URL rewrites require separate recovery")
        #aidevops:trust-boundary
        # Both lookups must resolve to the requested canonical name and the same
        # immutable ID: an old name reused by another repository fails closed.
        old = json.loads(run("gh", "api", "--hostname", "github.com", f"repos/{old_slug}"))
        new = json.loads(run("gh", "api", "--hostname", "github.com", f"repos/{new_slug}"))
        if (not isinstance(old.get("id"), int) or old["id"] <= 0 or old["id"] != new.get("id")
                or old.get(canonical_name, '').casefold() != new_slug.casefold()
                or new.get(canonical_name, '').casefold() != new_slug.casefold()):
            raise ValueError("GitHub repository IDs or canonical names do not match")
        new_url = match[1] + new[canonical_name] + (match[3] or "")
        run(audit, "verify", "--quiet", env=audit_env)
        audit_record("operation.verify", "Canonical repository transfer authorized", new["id"])
        matches[0][slug_key] = new[canonical_name]
        payload = (json.dumps(registry, indent=2, ensure_ascii=False) + "\n").encode()
        fd, staging = tempfile.mkstemp(prefix=".repos-transfer-", dir=config.parent)
        try:
            with os.fdopen(fd, "wb") as output:
                os.fchmod(output.fileno(), config.stat().st_mode & 0o777)
                output.write(payload)
                output.flush()
                os.fsync(output.fileno())
            if config.read_bytes() != before or git_values(url_key) != urls or git_values(push_key):
                raise ValueError("registry or origin changed during verification")
            run(git, '-C', repo, remote_command, "set-url", origin, new_url)
            try:
                if git_values(url_key) != [new_url] or git_values(push_key) or not resolved_origin_matches(new_url):
                    raise ValueError("updated origin did not verify")
                if config.read_bytes() != before:
                    raise ValueError("registry changed before replacement")
                os.replace(staging, config)
            except Exception:
                run(git, '-C', repo, remote_command, "set-url", origin, old_url)
                raise
        finally:
            Path(staging).unlink(missing_ok=True)
        audit_record("config.change", "Canonical repository transfer followed", new["id"])
        run(audit, "verify", "--quiet", env=audit_env)
        print(f"FOLLOWED: {old_slug} -> {new['full_name']} (repository ID {new['id']})")
        print("NEXT: aidevops repos migrate-layout plan --workspace ~/Git --output plan.json --include-registered-paths --source " + shlex.quote(repo))

try:
    apply_transfer()
except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
    # Provider errors can contain private URLs or credentials; do not relay stderr.
    print("BLOCKED: transfer identity, origin, registry, or audit verification failed; inspect local state before retrying", file=sys.stderr)
    sys.exit(1)
PY
	exit 0
fi
policy_helper="${SCRIPT_DIR}/canonical-write-policy-helper.py"
[[ -f "$policy_helper" ]] || {
	printf 'BLOCKED: canonical branch policy helper is unavailable\n' >&2
	exit 1
}
target_branch=$(AIDEVOPS_CANONICAL_REMOTE="$canonical_remote" \
	python3 "$policy_helper" resolve-branch --cwd "$repo_path" --field branch) || exit 1
target_branch_source=$(AIDEVOPS_CANONICAL_REMOTE="$canonical_remote" \
	python3 "$policy_helper" resolve-branch --cwd "$repo_path" --field source) || exit 1
"$REAL_GIT" check-ref-format --branch "$target_branch" >/dev/null 2>&1 || {
	printf 'BLOCKED: resolved canonical branch is invalid\n' >&2
	exit 1
}

if [[ "$cmd" != "restore-default" && "$cmd" != "$CLEAR_STALE_REBASE_CMD" &&
	"$cmd" != "$CLEAR_ABANDONED_REBASE_CMD" ]]; then
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

if [[ "$cmd" == "$REPAIR_UPSTREAM_CMD" ]]; then
	repair_remote_ref="refs/remotes/origin/${target_branch}"
	"$REAL_GIT" -C "$repo_path" rev-parse --verify --quiet "${repair_remote_ref}^{commit}" >/dev/null || {
		printf 'BLOCKED: origin/%s does not exist locally; fetch origin first\n' "$target_branch" >&2
		exit 1
	}
	previous_upstream=$("$REAL_GIT" -C "$repo_path" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
	if [[ "$previous_upstream" == "origin/${target_branch}" ]]; then
		printf 'VERIFIED: %s already tracks origin/%s\n' "$target_branch" "$target_branch"
		exit 0
	fi
	repair_audit_helper="${SCRIPT_DIR}/audit-log-helper.sh"
	repair_audit_file="${HOME}/.aidevops/logs/canonical-recovery-audit.jsonl"
	[[ -x "$repair_audit_helper" ]] || {
		printf 'BLOCKED: tamper-evident audit helper is unavailable\n' >&2
		exit 1
	}
	AUDIT_LOG_FILE="$repair_audit_file" "$repair_audit_helper" verify --quiet || {
		printf 'BLOCKED: audit chain verification failed\n' >&2
		exit 1
	}
	AUDIT_LOG_FILE="$repair_audit_file" AUDIT_QUIET=true "$repair_audit_helper" log \
		operation.verify "Canonical upstream repair authorized" \
		--detail "issue=${issue_number:-none}" --detail "repo=${repo_path}" \
		--detail "operation=${cmd}" --detail "target=${target_branch}" \
		--detail "previous_upstream=${previous_upstream:-none}" \
		--detail "new_upstream=origin/${target_branch}" >/dev/null || {
		printf 'BLOCKED: recovery audit record could not be written\n' >&2
		exit 1
	}
	"$REAL_GIT" -C "$repo_path" branch --set-upstream-to="origin/${target_branch}" "$target_branch" >/dev/null || {
		printf 'BLOCKED: upstream could not be set\n' >&2
		exit 1
	}
	printf 'REPAIRED: %s upstream %s -> origin/%s\n' "$target_branch" "${previous_upstream:-none}" "$target_branch"
	exit 0
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
crl_acquire "$lock_dir" "$cmd" || {
	printf 'BLOCKED: canonical recovery lock is already held\n' >&2
	exit 1
}
trap 'crl_release "$lock_dir"' EXIT
trap 'exit 143' TERM

local_ref="refs/heads/${target_branch}"
remote_ref="refs/remotes/${canonical_remote}/${target_branch}"
"$REAL_GIT" -C "$repo_path" fetch --no-tags "$canonical_remote" \
	"+refs/heads/${target_branch}:${remote_ref}" >/dev/null 2>&1 || {
	printf 'BLOCKED: %s/%s tip could not be fetched\n' "$canonical_remote" "$target_branch" >&2
	exit 1
}
target_sha=$("$REAL_GIT" -C "$repo_path" rev-parse --verify "${remote_ref}^{commit}" 2>/dev/null || true)
[[ -n "$target_sha" ]] || {
	printf 'BLOCKED: %s/%s tip cannot be resolved\n' "$canonical_remote" "$target_branch" >&2
	exit 1
}
local_sha=$("$REAL_GIT" -C "$repo_path" rev-parse --verify "${local_ref}^{commit}" 2>/dev/null || true)
local_state="$LOCAL_STATE_BORN"
unborn_empty_tree=""
null_oid="${target_sha//?/0}"
if [[ -z "$local_sha" ]]; then
	# GH#36289: initializing a clean unborn branch to the pinned remote tip is a
	# fast-forward from empty, so full-loop's post-merge fast-forward shares the
	# existing zero-OID compare-and-swap, rollback and verification path.
	[[ "$cmd" == "$SYNC_MIRROR_CMD" || "$cmd" == "$FAST_FORWARD_CMD" ]] || {
		printf 'BLOCKED: local %s tip cannot be resolved\n' "$target_branch" >&2
		exit 1
	}
	local_ref_is_absent "$repo_path" "$local_ref" || {
		printf 'BLOCKED: local %s ref exists but is not a valid commit\n' "$target_branch" >&2
		exit 1
	}
	if ! head_ref=$("$REAL_GIT" -C "$repo_path" symbolic-ref --quiet HEAD 2>&1); then
		head_ref=""
	fi
	[[ "$head_ref" == "$local_ref" ]] || {
		printf 'BLOCKED: unborn canonical HEAD does not target %s\n' "$local_ref" >&2
		exit 1
	}
	# Ignored files and user-hidden untracked files are still local data.
	unborn_status=$("$REAL_GIT" -C "$repo_path" status --porcelain=v1 --ignored --untracked-files=all) || {
		printf 'BLOCKED: unborn canonical worktree status cannot be read safely\n' >&2
		exit 1
	}
	[[ -z "$unborn_status" ]] || {
		printf 'BLOCKED: unborn canonical worktree is not clean\n' >&2
		exit 1
	}
	unborn_empty_tree=$("$REAL_GIT" -C "$repo_path" write-tree) || {
		printf 'BLOCKED: unborn canonical empty index cannot be verified\n' >&2
		exit 1
	}
	"$REAL_GIT" -C "$repo_path" cat-file -e "${unborn_empty_tree}^{tree}" || {
		printf 'BLOCKED: unborn canonical empty tree cannot be resolved\n' >&2
		exit 1
	}
	local_state="$LOCAL_STATE_UNBORN"
fi
if [[ "$cmd" == "$SYNC_MIRROR_CMD" && "$maintenance_reason" == "$AIDEVOPS_UPDATE_REASON" ]]; then
	tracked_status=$("$REAL_GIT" -C "$repo_path" status --porcelain=v1 --untracked-files=no) || {
		printf 'BLOCKED: canonical tracked/index state cannot be read safely\n' >&2
		exit 1
	}
	[[ -z "$tracked_status" ]] || {
		printf 'BLOCKED: routine update synchronization accepts untracked-only state\n' >&2
		exit 1
	}
	[[ "$local_state" == "$LOCAL_STATE_UNBORN" ]] || "$REAL_GIT" -C "$repo_path" merge-base --is-ancestor "$local_ref" "$target_sha" || {
		printf 'BLOCKED: routine update synchronization will not replace local commits\n' >&2
		exit 1
	}
fi

stale_rebase_dir=""
stale_rebase_fingerprint=""
stale_rebase_preservation_dir=""
stale_head_sha=""
stale_index_tree=""
stale_rebase_cleanup_kind=""
stale_rebase_ref_namespace=""
stale_rebase_stopped_sha=""
if [[ "$cmd" == "$CLEAR_STALE_REBASE_CMD" || "$cmd" == "$CLEAR_ABANDONED_REBASE_CMD" ]]; then
	rebase_merge_dir=$("$REAL_GIT" -C "$repo_path" rev-parse --path-format=absolute --git-path rebase-merge)
	rebase_apply_dir=$("$REAL_GIT" -C "$repo_path" rev-parse --path-format=absolute --git-path rebase-apply)
	rebase_head_path=$("$REAL_GIT" -C "$repo_path" rev-parse --path-format=absolute --git-path REBASE_HEAD)
	[[ -d "$rebase_merge_dir" && ! -e "$rebase_apply_dir" ]] || {
		printf 'BLOCKED: exactly one supported interactive rebase state is required\n' >&2
		exit 1
	}
	for required_file in "head-name" "onto" "orig-head" "git-rebase-todo" "done" "msgnum" "end"; do
		[[ -f "${rebase_merge_dir}/${required_file}" ]] || {
			printf 'BLOCKED: stale rebase metadata is malformed or incomplete\n' >&2
			exit 1
		}
	done
	rebase_head_name=$(<"${rebase_merge_dir}/head-name")
	rebase_onto=$(<"${rebase_merge_dir}/onto")
	rebase_orig_head=$(<"${rebase_merge_dir}/orig-head")
	rebase_msgnum=$(<"${rebase_merge_dir}/msgnum")
	rebase_end=$(<"${rebase_merge_dir}/end")
	[[ "$rebase_head_name" == "$local_ref" ]] || {
		printf 'BLOCKED: stale rebase belongs to a different branch\n' >&2
		exit 1
	}
	[[ "$rebase_msgnum" =~ ^[0-9]+$ && "$rebase_end" =~ ^[0-9]+$ ]] || {
		printf 'BLOCKED: rebase sequence counters are malformed\n' >&2
		exit 1
	}
	"$REAL_GIT" -C "$repo_path" rev-parse --verify "${rebase_onto}^{commit}" >/dev/null 2>&1 &&
		"$REAL_GIT" -C "$repo_path" rev-parse --verify "${rebase_orig_head}^{commit}" >/dev/null 2>&1 || {
		printf 'BLOCKED: stale rebase commit metadata is invalid\n' >&2
		exit 1
	}
	[[ -z "$("$REAL_GIT" -C "$repo_path" diff --name-only --diff-filter=U)" ]] || {
		printf 'BLOCKED: rebase has unresolved index entries\n' >&2
		exit 1
	}
	stale_head_sha=$("$REAL_GIT" -C "$repo_path" rev-parse --verify "$HEAD_COMMIT_EXPR")
	stale_index_tree=$("$REAL_GIT" -C "$repo_path" write-tree)
	stale_rebase_dir="$rebase_merge_dir"
	if [[ "$cmd" == "$CLEAR_STALE_REBASE_CMD" ]]; then
		[[ "$rebase_msgnum" == "$rebase_end" ]] || {
			printf 'BLOCKED: rebase sequence is active or malformed\n' >&2
			exit 1
		}
		[[ ! -s "${rebase_merge_dir}/git-rebase-todo" && -s "${rebase_merge_dir}/done" ]] || {
			printf 'BLOCKED: rebase sequence still has active work\n' >&2
			exit 1
		}
		[[ ! -e "$rebase_head_path" && ! -e "${rebase_merge_dir}/stopped-sha" ]] || {
			printf 'BLOCKED: rebase is stopped on an active commit\n' >&2
			exit 1
		}
		[[ "$stale_head_sha" == "$local_sha" && "$local_sha" == "$target_sha" ]] || {
			printf 'BLOCKED: HEAD, local default, and pinned %s default have not converged\n' "$canonical_remote" >&2
			exit 1
		}
		stale_rebase_cleanup_kind="converged"
		stale_rebase_ref_namespace="stale-rebase"
		stale_rebase_fingerprint=$(rebase_state_fingerprint "$stale_rebase_dir")
		stale_rebase_preservation_dir="${AIDEVOPS_CANONICAL_RECOVERY_ROOT:-${HOME}/.aidevops/.agent-workspace/recovery/canonical}/${issue_number}/stale-rebase-${stale_head_sha}"
	else
		[[ "$rebase_msgnum" -ge 1 && "$rebase_msgnum" -lt "$rebase_end" ]] || {
			printf 'BLOCKED: abandoned rebase must retain an incomplete active sequence\n' >&2
			exit 1
		}
		[[ -s "${rebase_merge_dir}/git-rebase-todo" && -s "${rebase_merge_dir}/done" &&
			-f "${rebase_merge_dir}/stopped-sha" && -f "$rebase_head_path" ]] || {
			printf 'BLOCKED: abandoned rebase metadata is not a complete stopped sequence\n' >&2
			exit 1
		}
		stale_rebase_stopped_sha=$(<"${rebase_merge_dir}/stopped-sha")
		rebase_head_sha=$(<"$rebase_head_path")
		stale_rebase_stopped_sha=$("$REAL_GIT" -C "$repo_path" rev-parse --verify "${stale_rebase_stopped_sha}^{commit}" 2>/dev/null || true)
		rebase_head_sha=$("$REAL_GIT" -C "$repo_path" rev-parse --verify "${rebase_head_sha}^{commit}" 2>/dev/null || true)
		[[ -n "$stale_rebase_stopped_sha" && "$stale_rebase_stopped_sha" == "$rebase_head_sha" ]] || {
			printf 'BLOCKED: stopped rebase commit metadata is invalid or inconsistent\n' >&2
			exit 1
		}
		abandoned_current_branch=$("$REAL_GIT" -C "$repo_path" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
		[[ -z "$abandoned_current_branch" ]] || {
			printf 'BLOCKED: abandoned rebase recovery requires a detached canonical HEAD\n' >&2
			exit 1
		}
		[[ "$stale_head_sha" == "$target_sha" && "$stale_head_sha" != "$stale_rebase_stopped_sha" ]] || {
			printf 'BLOCKED: HEAD has not independently converged beyond the stopped rebase commit\n' >&2
			exit 1
		}
		"$REAL_GIT" -C "$repo_path" merge-base --is-ancestor "$local_sha" "$target_sha" || {
			printf 'BLOCKED: local default branch has diverged from the pinned %s default\n' "$canonical_remote" >&2
			exit 1
		}
		rebase_latest_mtime=$(rebase_state_latest_mtime "$stale_rebase_dir" "$rebase_head_path") || {
			printf 'BLOCKED: abandoned rebase age cannot be established\n' >&2
			exit 1
		}
		current_epoch=$(date +%s)
		[[ "$rebase_latest_mtime" =~ ^[0-9]+$ && "$current_epoch" =~ ^[0-9]+$ &&
			"$current_epoch" -ge "$rebase_latest_mtime" &&
			$((current_epoch - rebase_latest_mtime)) -ge "$ABANDONED_REBASE_MIN_AGE_SECONDS" ]] || {
			printf 'BLOCKED: active rebase metadata is too recent to prove abandonment\n' >&2
			exit 1
		}
		stale_rebase_cleanup_kind="$ABANDONED_REBASE_KIND"
		stale_rebase_ref_namespace="abandoned-rebase"
		stale_rebase_fingerprint=$(rebase_marker_fingerprint "$stale_rebase_dir" "$rebase_head_path")
		stale_rebase_preservation_dir="${AIDEVOPS_CANONICAL_RECOVERY_ROOT:-${HOME}/.aidevops/.agent-workspace/recovery/canonical}/${issue_number}/abandoned-rebase-${stale_head_sha}"
	fi
fi

# A fast-forward must refuse divergence before any preservation clean so a
# refused run never moves untracked files out of the checkout (GH#34770).
if [[ "$local_state" == "$LOCAL_STATE_BORN" && "$cmd" == "$FAST_FORWARD_CMD" ]] &&
	! "$REAL_GIT" -C "$repo_path" merge-base --is-ancestor "$local_ref" "$target_sha"; then
	printf 'BLOCKED: local %s has diverged from %s/%s\n' \
		"$target_branch" "$canonical_remote" "$target_branch" >&2
	exit 1
fi

# GH#35659: preserve the local project config before dirty-state cleanup and
# the worktree update can delete it under an incoming untracking migration.
# Local edits are kept too: they are the machine-local state being migrated.
config_preserve_dir=""
if [[ "$local_state" == "$LOCAL_STATE_BORN" &&
	("$cmd" == "$SYNC_MIRROR_CMD" || "$cmd" == "$FAST_FORWARD_CMD" || "$cmd" == "restore-default") ]]; then
	config_old_sha=$("$REAL_GIT" -C "$repo_path" rev-parse --verify "$HEAD_COMMIT_EXPR") || {
		printf 'BLOCKED: canonical HEAD cannot be resolved\n' >&2
		exit 1
	}
	project_config_untrack_preserve "$repo_path" "$config_old_sha" "$target_sha" \
		"${issue_number:-$maintenance_reason}" true || exit 1
	config_preserve_dir="$PCU_DIR"
fi

sync_backup_id=""
sync_backup_dir=""
sync_tracked_dirty=false
if [[ "$cmd" == "$SYNC_MIRROR_CMD" || "$cmd" == "$FAST_FORWARD_CMD" ]]; then
	canonical_status=$("$REAL_GIT" -C "$repo_path" status --porcelain=v1) || {
		printf 'BLOCKED: canonical worktree status cannot be read safely\n' >&2
		exit 1
	}
	if [[ -n "$canonical_status" ]]; then
		tracked_dirty_status=$("$REAL_GIT" -C "$repo_path" status --porcelain=v1 --untracked-files=no) || {
			printf 'BLOCKED: canonical tracked/index state cannot be read safely\n' >&2
			exit 1
		}
		[[ -z "$tracked_dirty_status" ]] || sync_tracked_dirty=true
		backup_helper="${SCRIPT_DIR}/dirty-worktree-backup-helper.sh"
		[[ -f "$backup_helper" ]] || {
			printf 'BLOCKED: dirty-worktree backup helper is unavailable\n' >&2
			exit 1
		}
		backup_operation_key="${issue_number:-$maintenance_reason}"
		backup_reason="canonical mirror synchronization"
		backup_operation_prefix="canonical-sync"
		if [[ "$cmd" == "$FAST_FORWARD_CMD" ]]; then
			backup_reason="canonical fast-forward"
			backup_operation_prefix="canonical-ff"
		fi
		backup_output=$(AIDEVOPS_REAL_GIT_BIN="$REAL_GIT" bash "$backup_helper" backup \
			--repo "$repo_path" --reason "$backup_reason" \
			--issue "$issue_number" \
			--operation-id "${backup_operation_prefix}-${backup_operation_key}-${target_sha}" --machine) || {
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
		printf 'RECOVER_CLEAN_COMMAND=%q recover-clean --repo %q --backup %q --confirm RECOVER_DIRTY_WORKTREE_CLEAN\n' \
			"$backup_helper" "$repo_path" "$sync_backup_id"
		AIDEVOPS_REAL_GIT_BIN="$REAL_GIT" bash "$backup_helper" clean \
			--repo "$repo_path" --backup "$sync_backup_id" \
			--confirm CLEAN_VERIFIED_DIRTY_WORKTREE_BACKUP >/dev/null || {
			if AIDEVOPS_REAL_GIT_BIN="$REAL_GIT" bash "$backup_helper" matches \
				--repo "$repo_path" --backup "$sync_backup_id" >/dev/null 2>&1; then
				printf 'BLOCKED: canonical clean failed and pre-clean state was restored (backup %s)\n' \
					"$sync_backup_id" >&2
			else
				printf 'BLOCKED: canonical clean recovery is required (backup %s)\n' \
					"$sync_backup_id" >&2
			fi
			exit 1
		}
	fi

	if [[ "$cmd" == "$SYNC_MIRROR_CMD" ]]; then
		# shellcheck source=shared-constants.sh
		source "${SCRIPT_DIR}/shared-constants.sh"
		if ! declare -F remove_canonical_worktree_owner >/dev/null 2>&1 ||
			! remove_canonical_worktree_owner "$repo_path"; then
			printf 'BLOCKED: invalid canonical ownership could not be cleared safely\n' >&2
			exit 1
		fi
	fi
	if [[ "$cmd" == "$SYNC_MIRROR_CMD" || -n "$sync_backup_id" ]]; then
		current_branch=$("$REAL_GIT" -C "$repo_path" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
		[[ "$target_branch" == "$current_branch" ]] || {
			printf 'BLOCKED: canonical branch changed during preservation\n' >&2
			exit 1
		}
		verify_initial_local_state "$repo_path" "$local_ref" "$local_state" "$local_sha" || {
			printf 'BLOCKED: canonical local ref changed during preservation\n' >&2
			exit 1
		}
		[[ -z "$("$REAL_GIT" -C "$repo_path" status --porcelain)" ]] || {
			printf 'BLOCKED: canonical worktree remains dirty after preservation\n' >&2
			exit 1
		}
	fi
fi

preservation_ref=""
if [[ "$local_state" == "$LOCAL_STATE_BORN" && "$cmd" != "$FAST_FORWARD_CMD" ]] &&
	! "$REAL_GIT" -C "$repo_path" merge-base --is-ancestor "$local_ref" "$target_sha"; then
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
[[ "$cmd" == "$CLEAR_STALE_REBASE_CMD" ]] && audit_message="Converged stale rebase cleanup authorized"
[[ "$cmd" == "$CLEAR_ABANDONED_REBASE_CMD" ]] && audit_message="Abandoned stale rebase cleanup authorized"
AUDIT_LOG_FILE="$recovery_audit_file" AUDIT_QUIET=true "$audit_helper" log operation.verify "$audit_message" \
	--detail "issue=${issue_number:-none}" --detail "reason=${maintenance_reason:-none}" --detail "repo=${repo_path}" \
	--detail "operation=${cmd}" --detail "target=${target_branch}" --detail "target_source=${target_branch_source}" \
	--detail "remote=${canonical_remote}" --detail "registered_slug=${registered_slug:-none}" \
	--detail "expected_slug=${expected_slug}" \
	--detail "target_sha=${target_sha}" --detail "local_sha=${local_sha:-none}" \
	--detail "local_state=${local_state}" \
	--detail "preservation_ref=${preservation_ref:-none}" --detail "backup_id=${sync_backup_id:-none}" \
	--detail "project_config_preservation=${config_preserve_dir:-none}" \
	--detail "stale_rebase_fingerprint=${stale_rebase_fingerprint:-none}" \
	--detail "stale_rebase_preservation=${stale_rebase_preservation_dir:-none}" >/dev/null || {
	printf 'BLOCKED: recovery audit record could not be written\n' >&2
	exit 1
}

[[ "$("$REAL_GIT" -C "$repo_path" rev-parse --verify "${remote_ref}^{commit}")" == "$target_sha" ]] || {
	printf 'BLOCKED: %s/%s tip changed during recovery\n' "$canonical_remote" "$target_branch" >&2
	exit 1
}
verify_initial_local_state "$repo_path" "$local_ref" "$local_state" "$local_sha" || {
	printf 'BLOCKED: local %s tip changed during recovery\n' "$target_branch" >&2
	exit 1
}
if [[ "$cmd" == "$CLEAR_STALE_REBASE_CMD" || "$cmd" == "$CLEAR_ABANDONED_REBASE_CMD" ]]; then
	preservation_parent=${stale_rebase_preservation_dir%/*}
	mkdir -p "$preservation_parent"
	if [[ -d "$stale_rebase_preservation_dir" ]]; then
		preserved_rebase_fingerprint=""
		if [[ "$stale_rebase_cleanup_kind" == "$ABANDONED_REBASE_KIND" ]]; then
			preserved_rebase_fingerprint=$(rebase_marker_fingerprint \
				"${stale_rebase_preservation_dir}/rebase-merge" \
				"${stale_rebase_preservation_dir}/REBASE_HEAD") || true
		else
			preserved_rebase_fingerprint=$(rebase_state_fingerprint "$stale_rebase_preservation_dir") || true
		fi
		[[ "$preserved_rebase_fingerprint" == "$stale_rebase_fingerprint" ]] || {
			printf 'BLOCKED: existing stale rebase preservation evidence differs\n' >&2
			exit 1
		}
	else
		preservation_temp="${stale_rebase_preservation_dir}.tmp.$$"
		mkdir "$preservation_temp"
		if [[ "$stale_rebase_cleanup_kind" == "$ABANDONED_REBASE_KIND" ]]; then
			mkdir "${preservation_temp}/rebase-merge"
			cp -R "${stale_rebase_dir}/." "${preservation_temp}/rebase-merge/"
			cp "$rebase_head_path" "${preservation_temp}/REBASE_HEAD"
			preserved_rebase_fingerprint=$(rebase_marker_fingerprint \
				"${preservation_temp}/rebase-merge" "${preservation_temp}/REBASE_HEAD") || true
		else
			cp -R "${stale_rebase_dir}/." "$preservation_temp/"
			preserved_rebase_fingerprint=$(rebase_state_fingerprint "$preservation_temp") || true
		fi
		[[ "$preserved_rebase_fingerprint" == "$stale_rebase_fingerprint" ]] || {
			printf 'BLOCKED: stale rebase metadata copy could not be verified\n' >&2
			rm -rf "$preservation_temp"
			exit 1
		}
		mv "$preservation_temp" "$stale_rebase_preservation_dir"
	fi
	for metadata_commit in "$stale_head_sha" "$local_sha" "$target_sha" "$rebase_onto" \
		"$rebase_orig_head" "$stale_rebase_stopped_sha"; do
		[[ -n "$metadata_commit" ]] || continue
		preserve_rebase_commit_ref "$repo_path" "$issue_number" \
			"$stale_rebase_ref_namespace" "$metadata_commit" || {
			printf 'BLOCKED: stale rebase commit reference could not be preserved\n' >&2
			exit 1
		}
	done
	for sequence_file in "${stale_rebase_dir}/git-rebase-todo" "${stale_rebase_dir}/done"; do
		preserve_rebase_sequence_refs "$repo_path" "$issue_number" \
			"$stale_rebase_ref_namespace" "$sequence_file" || {
			printf 'BLOCKED: stale rebase sequence references are malformed or could not be preserved\n' >&2
			exit 1
		}
	done
	if [[ -f "${stale_rebase_dir}/git-rebase-todo.backup" ]]; then
		preserve_rebase_sequence_refs "$repo_path" "$issue_number" \
			"$stale_rebase_ref_namespace" "${stale_rebase_dir}/git-rebase-todo.backup" || {
			printf 'BLOCKED: stale rebase backup references are malformed or could not be preserved\n' >&2
			exit 1
		}
	fi
	preserve_rewritten_rebase_refs "$repo_path" "$issue_number" \
		"$stale_rebase_ref_namespace" "$stale_rebase_dir" || {
		printf 'BLOCKED: rewritten rebase references are malformed or could not be preserved\n' >&2
		exit 1
	}
	for object_metadata_file in "amend" "squash-onto" "update-refs"; do
		preserve_rebase_object_file_refs "$repo_path" "$issue_number" \
			"$stale_rebase_ref_namespace" "${stale_rebase_dir}/${object_metadata_file}" || {
			printf 'BLOCKED: auxiliary rebase object references could not be preserved\n' >&2
			exit 1
		}
	done
	if [[ -f "${stale_rebase_dir}/current-fixups" ]]; then
		preserve_rebase_sequence_refs "$repo_path" "$issue_number" \
			"$stale_rebase_ref_namespace" "${stale_rebase_dir}/current-fixups" || {
			printf 'BLOCKED: current rebase fixup references are malformed or could not be preserved\n' >&2
			exit 1
		}
	fi
	if [[ -n "${AIDEVOPS_CANONICAL_BEFORE_REBASE_CLEANUP_HOOK:-}" ]]; then
		"$AIDEVOPS_CANONICAL_BEFORE_REBASE_CLEANUP_HOOK" "$repo_path" "$stale_rebase_dir" || {
			printf 'BLOCKED: canonical pre-rebase-cleanup hook failed\n' >&2
			exit 1
		}
	fi
	current_rebase_fingerprint=""
	if [[ "$stale_rebase_cleanup_kind" == "$ABANDONED_REBASE_KIND" ]]; then
		current_rebase_fingerprint=$(rebase_marker_fingerprint "$stale_rebase_dir" "$rebase_head_path") || true
	else
		current_rebase_fingerprint=$(rebase_state_fingerprint "$stale_rebase_dir") || true
	fi
	[[ "$current_rebase_fingerprint" == "$stale_rebase_fingerprint" ]] &&
		[[ "$("$REAL_GIT" -C "$repo_path" rev-parse --verify "$HEAD_COMMIT_EXPR")" == "$stale_head_sha" ]] &&
		[[ "$("$REAL_GIT" -C "$repo_path" rev-parse --verify "${local_ref}^{commit}")" == "$local_sha" ]] &&
		[[ "$("$REAL_GIT" -C "$repo_path" rev-parse --verify "${remote_ref}^{commit}")" == "$target_sha" ]] &&
		[[ "$("$REAL_GIT" -C "$repo_path" write-tree)" == "$stale_index_tree" ]] &&
		[[ -z "$("$REAL_GIT" -C "$repo_path" status --porcelain)" ]] || {
		printf 'BLOCKED: canonical or rebase state changed before cleanup\n' >&2
		exit 1
	}
	stale_rebase_quarantine_dir="${stale_rebase_dir}.aidevops-quarantine.${issue_number}.$$"
	stale_rebase_quarantine_head="${rebase_head_path}.aidevops-quarantine.${issue_number}.$$"
	[[ ! -e "$stale_rebase_quarantine_dir" && ! -e "$stale_rebase_quarantine_head" ]] || {
		printf 'BLOCKED: stale rebase quarantine path already exists\n' >&2
		exit 1
	}
	if [[ -n "${AIDEVOPS_CANONICAL_BEFORE_REBASE_QUARANTINE_HOOK:-}" ]]; then
		"$AIDEVOPS_CANONICAL_BEFORE_REBASE_QUARANTINE_HOOK" "$repo_path" "$stale_rebase_dir" || {
			printf 'BLOCKED: canonical pre-rebase-quarantine hook failed\n' >&2
			exit 1
		}
	fi
	if [[ "$stale_rebase_cleanup_kind" == "$ABANDONED_REBASE_KIND" ]]; then
		cp "$rebase_head_path" "$stale_rebase_quarantine_head" || {
			printf 'BLOCKED: REBASE_HEAD could not be copied for quarantine\n' >&2
			exit 1
		}
		[[ "$("$REAL_GIT" hash-object "$stale_rebase_quarantine_head")" == "$("$REAL_GIT" hash-object "$rebase_head_path")" ]] || {
			printf 'BLOCKED: REBASE_HEAD quarantine copy could not be verified\n' >&2
			rm -f "$stale_rebase_quarantine_head"
			exit 1
		}
		if ! "$REAL_GIT" -C "$repo_path" update-ref -d REBASE_HEAD "$stale_rebase_stopped_sha"; then
			printf 'BLOCKED: REBASE_HEAD changed before compare-and-delete\n' >&2
			rm -f "$stale_rebase_quarantine_head"
			exit 1
		fi
		[[ ! -e "$rebase_head_path" ]] || {
			printf 'BLOCKED: REBASE_HEAD remained after compare-and-delete\n' >&2
			rm -f "$stale_rebase_quarantine_head"
			exit 1
		}
		if [[ -n "${AIDEVOPS_CANONICAL_BEFORE_REBASE_DIRECTORY_QUARANTINE_HOOK:-}" ]]; then
			if ! "$AIDEVOPS_CANONICAL_BEFORE_REBASE_DIRECTORY_QUARANTINE_HOOK" \
				"$repo_path" "$stale_rebase_dir" "$rebase_head_path" "$target_sha"; then
				if restore_deleted_rebase_head_copy "$repo_path" "$rebase_head_path" \
					"$stale_rebase_stopped_sha" "$stale_rebase_quarantine_head"; then
					printf 'BLOCKED: canonical pre-directory-quarantine hook failed\n' >&2
				else
					printf 'CRITICAL: pre-directory-quarantine hook failed and REBASE_HEAD recovery evidence was retained\n' >&2
				fi
				exit 1
			fi
		fi
	fi
	mv "$stale_rebase_dir" "$stale_rebase_quarantine_dir" || {
		if [[ "$stale_rebase_cleanup_kind" == "$ABANDONED_REBASE_KIND" ]]; then
			if ! restore_deleted_rebase_head_copy "$repo_path" "$rebase_head_path" \
				"$stale_rebase_stopped_sha" "$stale_rebase_quarantine_head"; then
				printf 'CRITICAL: directory quarantine failed and REBASE_HEAD recovery evidence was retained\n' >&2
				exit 1
			fi
		fi
		printf 'BLOCKED: stale rebase metadata could not be quarantined\n' >&2
		exit 1
	}
	quarantined_rebase_fingerprint=""
	if [[ "$stale_rebase_cleanup_kind" == "$ABANDONED_REBASE_KIND" ]]; then
		quarantined_rebase_fingerprint=$(rebase_marker_fingerprint \
			"$stale_rebase_quarantine_dir" "$stale_rebase_quarantine_head") || true
	else
		quarantined_rebase_fingerprint=$(rebase_state_fingerprint "$stale_rebase_quarantine_dir") || true
	fi
	quarantine_valid=1
	[[ "$quarantined_rebase_fingerprint" == "$stale_rebase_fingerprint" ]] || quarantine_valid=0
	[[ ! -e "$stale_rebase_dir" && ! -e "$rebase_apply_dir" && ! -e "$rebase_head_path" ]] || quarantine_valid=0
	[[ "$("$REAL_GIT" -C "$repo_path" rev-parse --verify "$HEAD_COMMIT_EXPR")" == "$stale_head_sha" ]] || quarantine_valid=0
	[[ "$("$REAL_GIT" -C "$repo_path" rev-parse --verify "${local_ref}^{commit}")" == "$local_sha" ]] || quarantine_valid=0
	[[ "$("$REAL_GIT" -C "$repo_path" rev-parse --verify "${remote_ref}^{commit}")" == "$target_sha" ]] || quarantine_valid=0
	[[ "$("$REAL_GIT" -C "$repo_path" write-tree)" == "$stale_index_tree" ]] || quarantine_valid=0
	[[ -z "$("$REAL_GIT" -C "$repo_path" status --porcelain)" ]] || quarantine_valid=0
	if [[ "$quarantine_valid" -ne 1 ]]; then
		if restore_quarantined_rebase_state "$repo_path" "$stale_rebase_dir" "$rebase_head_path" \
			"$stale_rebase_quarantine_dir" "$stale_rebase_quarantine_head" \
			"$stale_rebase_cleanup_kind" "$stale_rebase_stopped_sha"; then
			printf 'BLOCKED: canonical or rebase state changed during quarantine; metadata restored\n' >&2
		else
			printf 'CRITICAL: quarantined stale rebase metadata requires manual recovery\n' >&2
		fi
		exit 1
	fi
	rm -rf "$stale_rebase_quarantine_dir"
	[[ "$stale_rebase_cleanup_kind" != "$ABANDONED_REBASE_KIND" ]] || rm -f "$stale_rebase_quarantine_head"
	[[ ! -e "$stale_rebase_dir" && ! -e "$rebase_apply_dir" && ! -e "$rebase_head_path" ]] &&
		[[ ! -e "$stale_rebase_quarantine_dir" && ! -e "$stale_rebase_quarantine_head" ]] &&
		[[ "$("$REAL_GIT" -C "$repo_path" rev-parse --verify "$HEAD_COMMIT_EXPR")" == "$stale_head_sha" ]] &&
		[[ "$("$REAL_GIT" -C "$repo_path" rev-parse --verify "${local_ref}^{commit}")" == "$local_sha" ]] &&
		[[ "$("$REAL_GIT" -C "$repo_path" rev-parse --verify "${remote_ref}^{commit}")" == "$target_sha" ]] &&
		[[ "$("$REAL_GIT" -C "$repo_path" write-tree)" == "$stale_index_tree" ]] &&
		[[ -z "$("$REAL_GIT" -C "$repo_path" status --porcelain)" ]] || {
		printf 'CRITICAL: stale rebase cleanup changed canonical repository state\n' >&2
		exit 1
	}
	if [[ "$stale_rebase_cleanup_kind" == "$ABANDONED_REBASE_KIND" ]]; then
		printf 'CLEARED_ABANDONED_STALE_REBASE=true\n'
	else
		printf 'CLEARED_CONVERGED_STALE_REBASE=true\n'
	fi
	printf 'PRESERVED_REBASE_DIR=%s\n' "$stale_rebase_preservation_dir"
	exit 0
fi
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
	if [[ "$local_state" == "$LOCAL_STATE_UNBORN" ]]; then
		"$REAL_GIT" -C "$repo_path" read-tree --dry-run -u -m "$target_sha" || {
			printf 'BLOCKED: canonical worktree cannot be initialized without overwriting local changes\n' >&2
			exit 1
		}
	else
		"$REAL_GIT" -C "$repo_path" read-tree --dry-run -u -m "$local_sha" "$target_sha" || {
			printf 'BLOCKED: canonical worktree cannot be updated without overwriting local changes\n' >&2
			exit 1
		}
	fi
	if [[ -n "${AIDEVOPS_CANONICAL_BEFORE_REF_UPDATE_HOOK:-}" ]]; then
		"$AIDEVOPS_CANONICAL_BEFORE_REF_UPDATE_HOOK" "$repo_path" "$target_branch" "$local_sha" "$target_sha" || {
			printf 'BLOCKED: canonical pre-update hook failed\n' >&2
			exit 1
		}
	fi
	expected_local_oid="$local_sha"
	[[ "$local_state" == "$LOCAL_STATE_BORN" ]] || expected_local_oid="$null_oid"
	if ! printf '%s\n' \
		'start' \
		"verify ${remote_ref} ${target_sha}" \
		"update ${local_ref} ${target_sha} ${expected_local_oid}" \
		'prepare' \
		'commit' | "$REAL_GIT" -C "$repo_path" update-ref \
		-m "${fast_forward_reflog} for ${audit_reference}" --stdin >/dev/null; then
		printf 'BLOCKED: canonical local or %s ref changed during fast-forward\n' "$canonical_remote" >&2
		exit 1
	fi
	rollback_message="${fast_forward_reflog} rollback for ${audit_reference}"
	if ! verify_post_cas_state "$repo_path" "$local_ref" "$target_branch" "$remote_ref" "$target_sha"; then
		if ! rollback_local_ref "$repo_path" "$local_ref" "$local_state" "$local_sha" \
			"$target_sha" "$rollback_message"; then
			printf 'CRITICAL: canonical state changed after compare-and-swap and the local ref rollback failed\n' >&2
			exit 1
		fi
		if ! verify_initial_local_state "$repo_path" "$local_ref" "$local_state" "$local_sha" ||
			[[ -n "$("$REAL_GIT" -C "$repo_path" status --porcelain)" ]]; then
			printf 'CRITICAL: canonical local ref rolled back but the pre-update state is inconsistent\n' >&2
			exit 1
		fi
		printf 'BLOCKED: canonical branch or %s ref changed during fast-forward; local ref rolled back\n' \
			"$canonical_remote" >&2
		exit 1
	fi
	if [[ -n "${AIDEVOPS_CANONICAL_BEFORE_WORKTREE_UPDATE_HOOK:-}" ]]; then
		if ! "$AIDEVOPS_CANONICAL_BEFORE_WORKTREE_UPDATE_HOOK" "$repo_path" "$target_branch" "$local_sha" "$target_sha"; then
			if ! rollback_local_ref "$repo_path" "$local_ref" "$local_state" "$local_sha" \
				"$target_sha" "$rollback_message"; then
				printf 'CRITICAL: canonical pre-worktree-update hook failed and the local ref rollback also failed\n' >&2
				exit 1
			fi
			if ! verify_initial_local_state "$repo_path" "$local_ref" "$local_state" "$local_sha" ||
				[[ -n "$("$REAL_GIT" -C "$repo_path" status --porcelain)" ]]; then
				printf 'CRITICAL: canonical pre-worktree-update rollback left inconsistent state\n' >&2
				exit 1
			fi
			printf 'BLOCKED: canonical pre-worktree-update hook failed\n' >&2
			exit 1
		fi
	fi
	if ! verify_post_cas_state "$repo_path" "$local_ref" "$target_branch" "$remote_ref" "$target_sha"; then
		if ! rollback_local_ref "$repo_path" "$local_ref" "$local_state" "$local_sha" \
			"$target_sha" "$rollback_message"; then
			printf 'CRITICAL: canonical state changed before the worktree update and the local ref rollback failed\n' >&2
			exit 1
		fi
		if ! verify_initial_local_state "$repo_path" "$local_ref" "$local_state" "$local_sha" ||
			[[ -n "$("$REAL_GIT" -C "$repo_path" status --porcelain)" ]]; then
			printf 'CRITICAL: canonical pre-worktree drift rollback left inconsistent state\n' >&2
			exit 1
		fi
		printf 'BLOCKED: canonical branch or %s ref changed before the worktree update; local ref rolled back\n' \
			"$canonical_remote" >&2
		exit 1
	fi
	worktree_update_failed=false
	if [[ "$local_state" == "$LOCAL_STATE_UNBORN" ]]; then
		"$REAL_GIT" -C "$repo_path" read-tree -u -m "$target_sha" || worktree_update_failed=true
	else
		"$REAL_GIT" -C "$repo_path" read-tree -u -m "$local_sha" "$target_sha" || worktree_update_failed=true
	fi
	if [[ "$worktree_update_failed" == "$BOOLEAN_TRUE" ]]; then
		if ! rollback_local_ref "$repo_path" "$local_ref" "$local_state" "$local_sha" \
			"$target_sha" "$rollback_message"; then
			printf 'CRITICAL: canonical worktree update failed and the local ref rollback also failed\n' >&2
			exit 1
		fi
		if [[ "$local_state" == "$LOCAL_STATE_UNBORN" ]] &&
			! restore_unborn_worktree "$repo_path" "$target_sha" "$unborn_empty_tree"; then
			printf 'CRITICAL: canonical worktree update failed and the unborn worktree could not be restored\n' >&2
			exit 1
		fi
		if ! verify_initial_local_state "$repo_path" "$local_ref" "$local_state" "$local_sha" ||
			[[ -n "$("$REAL_GIT" -C "$repo_path" status --porcelain)" ]]; then
			printf 'CRITICAL: canonical worktree update rollback left inconsistent state\n' >&2
			exit 1
		fi
		printf 'BLOCKED: canonical worktree update failed; local ref rolled back\n' >&2
		exit 1
	fi
	post_update_branch=$("$REAL_GIT" -C "$repo_path" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
	if ! post_update_local_sha=$("$REAL_GIT" -C "$repo_path" rev-parse --verify "${local_ref}^{commit}" 2>&1); then
		post_update_local_sha=""
	fi
	post_update_remote_sha=$("$REAL_GIT" -C "$repo_path" rev-parse --verify "${remote_ref}^{commit}" 2>/dev/null || true)
	if [[ "$post_update_branch" != "$target_branch" || "$post_update_local_sha" != "$target_sha" ||
		"$post_update_remote_sha" != "$target_sha" ]]; then
		restore_unborn_state=false
		if [[ "$post_update_branch" == "$target_branch" ]]; then
			if [[ "$local_state" == "$LOCAL_STATE_UNBORN" ]]; then
				restore_worktree_sha="$unborn_empty_tree"
				restore_unborn_state=true
			else
				restore_worktree_sha="$local_sha"
			fi
		else
			if ! restore_worktree_sha=$("$REAL_GIT" -C "$repo_path" rev-parse --verify "$HEAD_COMMIT_EXPR" 2>&1); then
				restore_worktree_sha=""
			fi
		fi
		if ! rollback_local_ref "$repo_path" "$local_ref" "$local_state" "$local_sha" \
			"$target_sha" "$rollback_message"; then
			printf 'CRITICAL: canonical state changed after the worktree update and the local ref rollback failed\n' >&2
			exit 1
		fi
		[[ -n "$restore_worktree_sha" ]] || restore_worktree_sha="$local_sha"
		if ! "$REAL_GIT" -C "$repo_path" read-tree --dry-run -u -m "$target_sha" "$restore_worktree_sha" ||
			! "$REAL_GIT" -C "$repo_path" read-tree -u -m "$target_sha" "$restore_worktree_sha"; then
			printf 'CRITICAL: canonical ref was rolled back but the concurrent branch worktree could not be restored\n' >&2
			exit 1
		fi
		if [[ "$restore_unborn_state" == "$BOOLEAN_TRUE" ]]; then
			if ! verify_initial_local_state "$repo_path" "$local_ref" "$local_state" "$local_sha" ||
				[[ -n "$("$REAL_GIT" -C "$repo_path" status --porcelain)" ]]; then
				printf 'CRITICAL: canonical ref was rolled back but the unborn worktree remains inconsistent\n' >&2
				exit 1
			fi
		else
			if ! current_head_sha=$("$REAL_GIT" -C "$repo_path" rev-parse --verify "$HEAD_COMMIT_EXPR" 2>&1); then
				current_head_sha=""
			fi
			if [[ "$current_head_sha" != "$restore_worktree_sha" ]] ||
				[[ -n "$("$REAL_GIT" -C "$repo_path" status --porcelain)" ]]; then
				printf 'CRITICAL: canonical ref was rolled back but the concurrent branch remains inconsistent\n' >&2
				exit 1
			fi
		fi
		printf 'BLOCKED: canonical branch or %s ref changed during worktree update; ref and worktree restored\n' \
			"$canonical_remote" >&2
		exit 1
	fi
	[[ "$("$REAL_GIT" -C "$repo_path" rev-parse HEAD)" == "$target_sha" ]] || exit 1
	[[ "$("$REAL_GIT" -C "$repo_path" rev-parse --verify "${local_ref}^{commit}")" == "$target_sha" ]] || exit 1
	[[ "$("$REAL_GIT" -C "$repo_path" rev-parse --verify "${remote_ref}^{commit}")" == "$target_sha" ]] || exit 1
	[[ -z "$("$REAL_GIT" -C "$repo_path" status --porcelain)" ]] || exit 1
	if [[ -n "$config_preserve_dir" ]]; then
		project_config_reinstate "$repo_path" "$config_preserve_dir" || true
	fi
	if [[ "$maintenance_reason" == "$AIDEVOPS_UPDATE_REASON" ]] &&
		! fetch_aidevops_release_tag "$repo_path" "$canonical_remote"; then
		printf 'WARNING: exact release tag for the updated VERSION is not available from %s\n' \
			"$canonical_remote" >&2
	fi
	# GH#34770: reinstate preserved untracked files on top of the verified new
	# tip. Colliding paths stay in the backup, which then stays open so it is
	# never acknowledged or pruned while it holds the only copy.
	if [[ -n "$sync_backup_id" ]]; then
		untracked_restore_rc=0
		restore_untracked_noclobber "$repo_path" "$sync_backup_dir" || untracked_restore_rc=$?
		if [[ "$untracked_restore_rc" -ne 0 && "$untracked_restore_rc" -ne 3 ]]; then
			printf 'WARNING: preserved untracked files could not be reinstated; they remain in backup %s\n' \
				"$sync_backup_id" >&2
		fi
		if [[ "$untracked_restore_rc" -eq 0 ]] &&
			[[ "$maintenance_reason" == "$AIDEVOPS_UPDATE_REASON" || "$sync_tracked_dirty" != "$BOOLEAN_TRUE" ]]; then
			if ! AIDEVOPS_REAL_GIT_BIN="$REAL_GIT" bash "$backup_helper" acknowledge \
				--backup "$sync_backup_id" --confirm ACKNOWLEDGE_DIRTY_WORKTREE_BACKUP >/dev/null; then
				printf 'WARNING: synchronized backup remains open and requires manual acknowledgement: %s\n' \
					"$sync_backup_id" >&2
			elif [[ "$maintenance_reason" == "$AIDEVOPS_UPDATE_REASON" ]]; then
				retention_days="${AIDEVOPS_DIRTY_BACKUP_RETENTION_DAYS:-30}"
				[[ "$retention_days" =~ ^[0-9]+$ ]] || retention_days=30
				if ! AIDEVOPS_REAL_GIT_BIN="$REAL_GIT" bash "$backup_helper" prune \
					--force --retention-days "$retention_days" >/dev/null; then
					printf 'WARNING: synchronized mirror succeeded but expired backup pruning failed\n' >&2
				fi
			fi
		fi
	fi
	if [[ "$cmd" == "$SYNC_MIRROR_CMD" ]]; then
		printf 'SYNCHRONIZED_CANONICAL_MIRROR=true\n'
		printf 'OLD_STATE=%s\n' "$local_state"
		printf 'OLD_SHA=%s\n' "${local_sha:-none}"
		printf 'NEW_SHA=%s\n' "$target_sha"
		printf 'CANONICAL_BRANCH=%s\n' "$target_branch"
		printf 'BRANCH_SOURCE=%s\n' "$target_branch_source"
		printf 'PRESERVATION_REF=%s\n' "${preservation_ref:-none}"
	else
		printf 'Fast-forwarded canonical %s to %s/%s\n' \
			"$target_branch" "$canonical_remote" "$target_branch"
	fi
	# Post-sync maintenance is opt-in and cannot invalidate a converged sync.
	# The runner independently rejects worker sessions and untrusted config.
	if [[ -n "$local_sha" && "$local_sha" != "$target_sha" ]]; then
		if ! python3 "${SCRIPT_DIR}/canonical-post-sync.py" "$repo_path" "$local_sha" "$target_sha" "$REAL_GIT"; then
			printf 'WARNING: POST_SYNC outcome=warning reason=runner_unavailable\n' >&2
		fi
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
if [[ -n "$config_preserve_dir" ]]; then
	project_config_reinstate "$repo_path" "$config_preserve_dir" || true
fi
if [[ -n "$preservation_ref" ]]; then
	printf 'Preserved divergent canonical tip %s at %s\n' "$local_sha" "$preservation_ref"
fi
printf 'Restored canonical repository to %s\n' "$target_branch"
