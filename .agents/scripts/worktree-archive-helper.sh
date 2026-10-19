#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

ARCHIVE_ROOT="${AIDEVOPS_WORKTREE_ARCHIVE_ROOT:-${HOME}/.aidevops/recovery/archives}"
MAX_UNTRACKED_FILES="${AIDEVOPS_WORKTREE_ARCHIVE_MAX_UNTRACKED_FILES:-10000}"
MAX_UNTRACKED_BYTES="${AIDEVOPS_WORKTREE_ARCHIVE_MAX_UNTRACKED_BYTES:-1073741824}"
ARCHIVE_SCHEMA="aidevops-worktree-archive-v1"
FINGERPRINT_UNAVAILABLE="worktree fingerprint unavailable"

usage() {
	cat <<'USAGE'
Usage: worktree-archive-helper.sh <command> [options]

Commands:
  archive WORKTREE --repo OWNER/REPO (--issue N|--unattributed)
	  --reason failed-worker|post-pr-cleanup|unattributed-worktree --base-branch BRANCH
      [--base-sha SHA] [--output-root DIR] [--failure-log FILE] [--self-contained]
      [--include-ignored] [--preserve-git-admin]
  restore ARCHIVE_DIR --target NEW_WORKTREE_PATH
  list [--repo OWNER/REPO] [--issue N] [--output-root DIR]
  verify ARCHIVE_DIR
  source-matches ARCHIVE_DIR WORKTREE   Exit 0 only if WORKTREE is unchanged since capture
  prune --older-than 14d --max-total-size 20G [--dry-run|--apply]
      [--output-root DIR]

Environment:
  AIDEVOPS_WORKTREE_ARCHIVE_ROOT                Override the archive root.
  AIDEVOPS_WORKTREE_ARCHIVE_MAX_UNTRACKED_FILES Maximum untracked paths (10000).
  AIDEVOPS_WORKTREE_ARCHIVE_MAX_UNTRACKED_BYTES Maximum untracked bytes (1 GiB).
USAGE
	return 0
}

die() {
	local message="$1"
	printf 'Error: %s\n' "$message" >&2
	return 1
}

require_value() {
	local option="$1"
	local value="${2:-}"
	if [[ -z "$value" ]]; then
		die "$option requires a value"
		return 1
	fi
	return 0
}

validate_repo() {
	local repo="$1"
	if [[ ! "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
		die "invalid repository slug: $repo"
		return 1
	fi
	return 0
}

validate_issue() {
	local issue="$1"
	if [[ ! "$issue" =~ ^[1-9][0-9]*$ ]]; then
		die "issue must be a positive integer"
		return 1
	fi
	return 0
}

validate_branch() {
	local branch="$1"
	if ! git check-ref-format --branch "$branch" >/dev/null 2>&1; then
		die "invalid base branch: $branch"
		return 1
	fi
	return 0
}

validate_archive_dir() {
	local archive_dir="$1"
	if [[ ! -d "$archive_dir" || ! -f "$archive_dir/manifest.json" ]]; then
		die "archive manifest not found: $archive_dir"
		return 1
	fi
	return 0
}

timestamp_utc() {
	date -u '+%Y%m%dT%H%M%SZ'
	return 0
}

iso_utc() {
	date -u '+%Y-%m-%dT%H:%M:%SZ'
	return 0
}

resolve_base_sha() {
	local worktree="$1"
	local base_branch="$2"
	local requested_sha="$3"
	local resolved=""
	if [[ -n "$requested_sha" ]]; then
		resolved=$(git -C "$worktree" rev-parse --verify "${requested_sha}^{commit}" 2>/dev/null) || return 1
	else
		resolved=$(git -C "$worktree" rev-parse --verify "refs/remotes/origin/${base_branch}^{commit}" 2>/dev/null || true)
		if [[ -z "$resolved" ]]; then
			resolved=$(git -C "$worktree" rev-parse --verify "refs/heads/${base_branch}^{commit}" 2>/dev/null) || return 1
		fi
		resolved=$(git -C "$worktree" merge-base --all HEAD "$resolved") || return 1
		[[ "$resolved" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || { die "ambiguous base; supply --base-sha"; return 1; }
	fi
	printf '%s\n' "$resolved"
	return 0
}

# Print a one-line JSON fingerprint of the recoverable source state: HEAD,
# branch, unstaged and staged binary diffs, and every untracked path with its
# type and content (GH#34943). Compact archives record it so removal can
# prove nothing changed between capture and deletion. Index entries flagged
# skip-worktree or assume-unchanged hide edits from the diffs, so they fail
# closed. Ignored files are excluded by default; each one's lstat stamp (mode,
# inode, size, mtime_ns, ctime_ns, as Git's own index stat check) is
# fingerprinted so a late ignored write still blocks removal. Explicit ignored
# capture additionally hashes their contents and modes with the untracked data.
# More than
# AIDEVOPS_WORKTREE_FINGERPRINT_MAX_IGNORED (default 200000) files fails
# closed. Unreadable entries raise, which also fails closed.
source_fingerprint() {
	local worktree="$1"
	local include_ignored="${2:-0}"
	local preserve_git_admin="${3:-0}"
	local -x GIT_OPTIONAL_LOCKS=0
	python3 - "$worktree" "$include_ignored" "$MAX_UNTRACKED_FILES" "$MAX_UNTRACKED_BYTES" "$preserve_git_admin" "$SCRIPT_DIR" <<'PY'
import hashlib
import json
import os
import pathlib
import subprocess
import sys

root = pathlib.Path(sys.argv[1]).resolve()
include_ignored = sys.argv[2] == '1'


def git(*args):
    return subprocess.run(["git", "-c", "diff.autoRefreshIndex=false", "-C", str(root), *args], check=True,
                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout


def listed(*args):
    """Sorted, NUL-delimited `git ls-files` output."""
    return sorted(p for p in git("ls-files", "-z", *args).split(b"\0") if p)


lock = os.fsdecode(git('rev-parse', '--path-format=absolute', '--git-path', 'index.lock').rstrip(b'\n'))
if os.path.lexists(lock):
    raise SystemExit('git_admin:index_locked:index.lock')
try:
    branch = git("symbolic-ref", "--short", "-q", "HEAD").decode().strip()
except subprocess.CalledProcessError:
    branch = "detached"
untracked = hashlib.sha256()
capture_options = () if include_ignored else ("--exclude-standard",)
untracked_paths = listed("--others", *capture_options)
payload_limit_error = "untracked payload exceeds configured limit"
max_payload_bytes = int(sys.argv[4])
if include_ignored:
    # Refuse oversized ignored trees before reading their file contents.
    if len(untracked_paths) > int(sys.argv[3]):
        raise SystemExit(payload_limit_error)
    payload_bytes = sum(root.joinpath(os.fsdecode(raw)).lstat().st_size
                        for raw in untracked_paths)
    if payload_bytes > max_payload_bytes:
        raise SystemExit(payload_limit_error)
hashed_bytes = 0
for raw in untracked_paths:
    target = root.joinpath(os.fsdecode(raw))
    untracked.update(raw + b"\0")
    if include_ignored:
        untracked.update(str(target.lstat().st_mode).encode() + b"\0")
    if target.is_symlink():
        untracked.update(b"L" + os.fsencode(os.readlink(target)))
    elif target.is_file():
        untracked.update(b"F")
        with target.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1048576), b""):
                hashed_bytes += len(chunk)
                if include_ignored and hashed_bytes > max_payload_bytes:
                    raise SystemExit(payload_limit_error)
                untracked.update(chunk)
    else:
        untracked.update(b"?")
    untracked.update(b"\0")
for entry in listed("-v"):
    if entry[:1] == b"S" or entry[:1].islower():
        raise SystemExit("index has skip-worktree/assume-unchanged entries")
ignored = hashlib.sha256()
ignored_paths = listed("--others", "--ignored", "--exclude-standard")
if len(ignored_paths) > int(os.environ.get("AIDEVOPS_WORKTREE_FINGERPRINT_MAX_IGNORED", "200000")):
    raise SystemExit("too many ignored files to fingerprint")
for raw in ignored_paths:
    info = os.lstat(root.joinpath(os.fsdecode(raw.rstrip(b"/"))))
    stamp = "%o:%d:%d:%d:%d" % (info.st_mode, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)
    ignored.update(raw + b"\0" + stamp.encode() + b"\0")
result = {
    "head": git("rev-parse", "--verify", "HEAD").decode().strip(),
    'branch': branch,
    "diff_sha256": hashlib.sha256(git("diff", "--no-ext-diff", "--binary")).hexdigest(),
    "staged_sha256": hashlib.sha256(git("diff", "--no-ext-diff", "--cached", "--binary")).hexdigest(),
    "untracked_sha256": untracked.hexdigest(),
    "ignored_sha256": ignored.hexdigest(),
}
if sys.argv[5] == '1':
    sys.path.insert(0, sys.argv[6])
    from worktree_archive_snapshot import administration, administration_digest, supported_state
    supported_state(root, True, include_ignored)
    result['git_admin'] = administration_digest(administration(root))
print(json.dumps(result, sort_keys=True))
PY
	return $?
}

# Succeed only when WORKTREE is the archive's recorded source and its current
# fingerprint equals the one captured at archive time. Missing fingerprints
# (older archives) or any unreadable evidence fail closed so callers preserve.
source_matches() {
	local archive_dir="${1:-}"
	local worktree="${2:-}"
	local current=""
	local include_ignored=""
	local preserve_git_admin=""
	[[ -n "$archive_dir" && -n "$worktree" ]] || { usage >&2; return 1; }
	validate_archive_dir "$archive_dir" || return 1
	[[ -d "$worktree" ]] || { die "worktree does not exist: $worktree"; return 1; }
	worktree=$(cd "$worktree" && pwd -P) || return 1
	include_ignored=$(python3 - "$archive_dir/manifest.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as handle:
    value = json.load(handle).get('include_ignored', False)
if not isinstance(value, bool):
    raise SystemExit('invalid ignored capture policy')
print(int(value))
PY
	) || return 1
	preserve_git_admin=$(python3 - "$archive_dir/manifest.json" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding='utf-8')).get('git_admin_policy')
if value not in (None, 'preserve-v1'):
    raise SystemExit('invalid Git administration policy')
print(int(value == 'preserve-v1'))
PY
	) || return 1
	current=$(source_fingerprint "$worktree" "$include_ignored" "$preserve_git_admin") || { die "$FINGERPRINT_UNAVAILABLE"; return 1; }
	python3 - "$archive_dir" "$worktree" "$current" <<'PY'
import json
import pathlib
import sys

manifest = json.loads((pathlib.Path(sys.argv[1]) / "manifest.json").read_text(encoding="utf-8"))
recorded = manifest.get('source_fingerprint')
if not isinstance(recorded, dict) or not recorded:
    raise SystemExit("archive has no recorded fingerprint")
if manifest.get('source_worktree') != sys.argv[2]:
    raise SystemExit("archive worktree path mismatch")
if json.loads(sys.argv[3]) != recorded:
    raise SystemExit("worktree changed since archive capture")
print("worktree matches archive")
PY
	return $?
}

capture_untracked() {
	local worktree="$1"
	local archive_dir="$2"
	local include_ignored="${3:-0}"
	local inventory="$archive_dir/untracked-files.nul"
	if [[ "$include_ignored" == "1" ]]; then
		git -C "$worktree" ls-files --others -z >"$inventory" || return 1
	else
		git -C "$worktree" ls-files --others --exclude-standard -z >"$inventory" || return 1
	fi
	python3 - "$worktree" "$inventory" "$archive_dir" "$MAX_UNTRACKED_FILES" "$MAX_UNTRACKED_BYTES" <<'PY'
import os
import pathlib
import sys
import tarfile

root = pathlib.Path(sys.argv[1]).resolve()
inventory = pathlib.Path(sys.argv[2])
archive = pathlib.Path(sys.argv[3])
limit_files = int(sys.argv[4])
limit_bytes = int(sys.argv[5])
raw_paths = [p for p in inventory.read_bytes().split(b"\0") if p]
display = []
total = 0
paths = []
for raw in raw_paths:
    rel = pathlib.PurePosixPath(os.fsdecode(raw))
    if rel.is_absolute() or ".." in rel.parts or '.git' in rel.parts:
        raise SystemExit("unsafe untracked path")
    target = root.joinpath(*rel.parts)
    if not target.is_file() and not target.is_symlink():
        raise SystemExit("unsupported untracked path type")
    total += target.lstat().st_size
    paths.append((raw, rel, target))
    display.append(os.fsdecode(raw).replace("\\", "\\\\").replace("\n", "\\n"))
if len(paths) > limit_files or total > limit_bytes:
    raise SystemExit("untracked payload exceeds configured limit")
(archive / "untracked-files.txt").write_text("".join(path + "\n" for path in display), encoding='utf-8')
inventory.unlink()
if paths:
    with tarfile.open(archive / "untracked.tar.gz", "w:gz") as output:
        for _, rel, target in paths:
            output.add(target, arcname=str(rel), recursive=False)
PY
	return $?
}

write_manifest() {
	local archive_dir="$1"
	local repo="$2"
	local issue="$3"
	local reason="$4"
	local created_at="$5"
	local worktree="$6"
	local branch="$7"
	local head_sha="$8"
	local base_branch="$9"
	local base_sha="${10}"
	local default_branch="${11}"
	local remote_state="${12}"
	local dirty_state="${13}"
	local git_common_dir="${14}"
	local source_fingerprint_json="${15}"
	local self_contained="${16:-0}"
	local include_ignored="${17:-0}"
	local preserve_git_admin="${18:-0}"
	python3 - "$archive_dir" "$repo" "$issue" "$reason" "$created_at" "$worktree" "$branch" "$head_sha" "$base_branch" "$base_sha" "$default_branch" "$remote_state" "$dirty_state" "$git_common_dir" "$ARCHIVE_SCHEMA" "$source_fingerprint_json" "$self_contained" "$include_ignored" "$preserve_git_admin" <<'PY'
import hashlib
import json
import pathlib
import sys

archive = pathlib.Path(sys.argv[1])
names = sorted(path.name for path in archive.iterdir() if path.name != 'manifest.json')
artifacts = []
for name in names:
    path = archive / name
    if not path.is_file():
        continue
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    artifacts.append({'name': name, "size": path.stat().st_size, "sha256": digest})
manifest = {
    'schema': sys.argv[15],
    'repo': sys.argv[2],
    'issue': None if sys.argv[3] == 'unattributed' else int(sys.argv[3]),
    "reason": sys.argv[4],
    "created_at": sys.argv[5],
    "source_worktree": sys.argv[6],
    'source_git_common_dir': sys.argv[14],
    'self_contained': sys.argv[17] == '1',
    'include_ignored': sys.argv[18] == '1',
    "branch": sys.argv[7],
    "head_sha": sys.argv[8],
    "base_branch": sys.argv[9],
    "base_sha": sys.argv[10],
    "default_branch": sys.argv[11],
    "remote_branch_state": sys.argv[12],
    "dirty_state": sys.argv[13],
    'source_fingerprint': json.loads(sys.argv[16]),
    "artifacts": artifacts,
    "restore_instructions": f"worktree-archive-helper.sh restore {archive} --target <new-worktree-path>",
}
if sys.argv[19] == '1':
    manifest['git_admin_policy'] = 'preserve-v1'
(archive / 'manifest.json').write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding='utf-8')
PY
	return $?
}

archive_worktree() {
	local worktree="${1:-}"
	shift || true
	local repo="" issue="" unattributed="false" reason="" base_branch="" base_sha="" output_root="$ARCHIVE_ROOT" failure_log=""
	local self_contained=0 include_ignored=0 preserve_git_admin=0
	local created_at timestamp repo_path archive_dir branch head_sha default_branch remote_state dirty_state git_common_dir commit_count
	local fingerprint_before="" fingerprint_after=""
	local -x GIT_OPTIONAL_LOCKS=0
	[[ -n "$worktree" ]] || { usage >&2; return 1; }
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--repo) require_value "$1" "${2:-}" || return 1; repo="$2"; shift 2 ;;
		--issue) require_value "$1" "${2:-}" || return 1; issue="$2"; shift 2 ;;
		--unattributed) unattributed="true"; shift ;;
		--reason) require_value "$1" "${2:-}" || return 1; reason="$2"; shift 2 ;;
		--base-branch) require_value "$1" "${2:-}" || return 1; base_branch="$2"; shift 2 ;;
		--base-sha) require_value "$1" "${2:-}" || return 1; base_sha="$2"; shift 2 ;;
		--output-root) require_value "$1" "${2:-}" || return 1; output_root="$2"; shift 2 ;;
		--failure-log) require_value "$1" "${2:-}" || return 1; failure_log="$2"; shift 2 ;;
		--self-contained) self_contained=1; shift ;;
		--include-ignored) include_ignored=1; shift ;;
		--preserve-git-admin) preserve_git_admin=1; shift ;;
		*) die "unknown archive option: $1"; return 1 ;;
		esac
	done
	validate_repo "$repo" || return 1
	if [[ "$unattributed" == "true" ]]; then
		[[ -z "$issue" && "$reason" == "unattributed-worktree" ]] || { die "unattributed archive cannot have an issue"; return 1; }
		issue="unattributed"
	else
		validate_issue "$issue" || return 1
		[[ "$reason" == "failed-worker" || "$reason" == "post-pr-cleanup" ]] || { die "invalid archive reason"; return 1; }
	fi
	validate_branch "$base_branch" || return 1
	[[ -d "$worktree" ]] || { die "worktree does not exist: $worktree"; return 1; }
	git -C "$worktree" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { die "not a Git worktree: $worktree"; return 1; }
	worktree=$(cd "$worktree" && pwd -P) || return 1
	fingerprint_before=$(source_fingerprint "$worktree" "$include_ignored" "$preserve_git_admin") || { die "$FINGERPRINT_UNAVAILABLE"; return 1; }
	base_sha=$(resolve_base_sha "$worktree" "$base_branch" "$base_sha") || { die "cannot resolve base SHA"; return 1; }
	head_sha=$(git -C "$worktree" rev-parse HEAD) || return 1
	branch=$(git -C "$worktree" symbolic-ref --short -q HEAD 2>/dev/null || printf 'detached')
	default_branch=$(git -C "$worktree" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)
	default_branch=${default_branch#origin/}
	[[ -n "$default_branch" ]] || default_branch="$base_branch"
	remote_state="unknown"
	if [[ "$branch" != "detached" ]]; then
		local remote_rc=0
		git -C "$worktree" ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1 || remote_rc=$?
		if [[ "$remote_rc" -eq 0 ]]; then
			remote_state="present"
		elif [[ "$remote_rc" -eq 2 ]]; then
			remote_state="missing"
		fi
	fi
	dirty_state=$(git -C "$worktree" status --porcelain=v1)
	if [[ -n "$dirty_state" ]]; then dirty_state="dirty"; else dirty_state="clean"; fi
	git_common_dir=$(git -C "$worktree" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || git -C "$worktree" rev-parse --git-common-dir) || return 1
	timestamp=$(timestamp_utc)
	created_at=$(iso_utc)
	repo_path="${repo//\//__}"
	archive_dir="${output_root%/}/${repo_path}/${issue}/${timestamp}"
	if [[ -e "$archive_dir" ]]; then archive_dir="${archive_dir}-$$"; fi
	mkdir -p "${archive_dir%/*}" || return 1
	mkdir -m 700 "$archive_dir" || return 1
	# diff can refresh the index despite GIT_OPTIONAL_LOCKS=0. Capture must not
	# change the administration that its before/after fingerprints protect.
	git -c diff.autoRefreshIndex=false -C "$worktree" diff --binary --no-ext-diff --no-textconv >"$archive_dir/diff.patch" || return 1
	git -c diff.autoRefreshIndex=false -C "$worktree" diff --cached --binary --no-ext-diff --no-textconv >"$archive_dir/staged.patch" || return 1
	commit_count=$(git -C "$worktree" rev-list --count "${base_sha}..${head_sha}") || return 1
	if [[ "$preserve_git_admin" -eq 1 ]]; then
		local admin_base=""
		if [[ "$self_contained" -eq 0 ]]; then admin_base="$base_sha"; fi
		python3 "${SCRIPT_DIR}/worktree_archive_snapshot.py" admin-capture "$worktree" "$archive_dir" "$include_ignored" "$admin_base" || return 1
	elif [[ "$self_contained" -eq 1 ]]; then
		git -C "$worktree" bundle create "$archive_dir/commits.bundle" HEAD || return 1
	elif [[ "$commit_count" -gt 0 ]]; then
		git -C "$worktree" bundle create "$archive_dir/commits.bundle" HEAD "^${base_sha}" || return 1
	fi
	capture_untracked "$worktree" "$archive_dir" "$include_ignored" || return 1
	if [[ -n "$failure_log" ]]; then
		[[ -f "$failure_log" ]] || { die "failure log does not exist"; return 1; }
		python3 - "$failure_log" "$archive_dir/failure.log" <<'PY'
import pathlib
import sys
source = pathlib.Path(sys.argv[1])
target = pathlib.Path(sys.argv[2])
with source.open("rb") as handle:
    handle.seek(max(0, source.stat().st_size - 262144))
    target.write_bytes(handle.read())
PY
	fi
	# GH#34943: a capture that raced a late writer is not a faithful copy.
	fingerprint_after=$(source_fingerprint "$worktree" "$include_ignored" "$preserve_git_admin") || { die "$FINGERPRINT_UNAVAILABLE"; return 1; }
	if [[ "$fingerprint_before" != "$fingerprint_after" ]]; then
		die "worktree changed during archive capture: $worktree"
		return 1
	fi
	write_manifest "$archive_dir" "$repo" "$issue" "$reason" "$created_at" "$worktree" "$branch" "$head_sha" "$base_branch" "$base_sha" "$default_branch" "$remote_state" "$dirty_state" "$git_common_dir" "$fingerprint_after" "$self_contained" "$include_ignored" "$preserve_git_admin" || return 1
	printf '%s\n' "$archive_dir"
	return 0
}

verify_archive() {
	local archive_dir="$1"
	validate_archive_dir "$archive_dir" || return 1
	python3 - "$archive_dir" "$ARCHIVE_SCHEMA" "$SCRIPT_DIR" <<'PY'
import hashlib
import json
import pathlib
import posixpath
import subprocess
import sys
import tarfile
import tempfile

archive = pathlib.Path(sys.argv[1]).resolve()
manifest = json.loads((archive / 'manifest.json').read_text(encoding='utf-8'))
required = ('repo', 'issue', "reason", 'created_at', "source_worktree", "branch", "head_sha", "base_branch", "base_sha", "default_branch", "remote_branch_state", "dirty_state", 'artifacts', "restore_instructions")
if not isinstance(manifest, dict):
    raise SystemExit("manifest must be an object")
missing = [key for key in required if key not in manifest]
if manifest.get('schema') != sys.argv[2] or missing:
    raise SystemExit("invalid manifest schema or missing fields: " + ", ".join(missing))
if not isinstance(manifest.get('include_ignored', False), bool):
    raise SystemExit("invalid ignored capture policy")
artifacts = manifest['artifacts']
if not isinstance(artifacts, list) or not all(isinstance(item, dict) for item in artifacts):
    raise SystemExit("invalid artifact inventory")
names = [item.get('name') for item in artifacts]
mandatory = {'diff.patch', 'staged.patch', 'untracked-files.txt'}
allowed = mandatory | {'commits.bundle', 'untracked.tar.gz', 'failure.log'}
policy = manifest.get('git_admin_policy')
if policy is not None:
    if policy != 'preserve-v1' or not isinstance(manifest.get('self_contained'), bool):
        raise SystemExit('invalid Git administration policy')
    mandatory.add('git-admin.json')
    allowed.add('git-admin.json')
if (not all(isinstance(name, str) and name in allowed for name in names) or
        len(set(names)) != len(names) or not mandatory.issubset(names)):
    raise SystemExit("incomplete or unsafe artifact inventory")
actual = {path.name for path in archive.iterdir()}
if actual - {'manifest.json', '.aidevops-archive-pin'} != set(names):
    raise SystemExit("unlisted or missing archive contents")
if (archive / 'manifest.json').is_symlink():
    raise SystemExit("symlinked manifest")
for artifact in manifest['artifacts']:
    path = archive / artifact['name']
    if path.parent != archive or path.is_symlink() or not path.is_file():
        raise SystemExit("missing or unsafe artifact: " + artifact['name'])
    if path.stat().st_size != artifact["size"] or hashlib.sha256(path.read_bytes()).hexdigest() != artifact["sha256"]:
        raise SystemExit("artifact integrity mismatch: " + artifact['name'])
bundle = archive / "commits.bundle"
if policy is not None:
    sys.path.insert(0, sys.argv[3])
    from worktree_archive_snapshot import load_administration
    load_administration(archive)
if manifest.get('self_contained') is True or policy is not None:
    if manifest.get('self_contained') is True and not bundle.is_file():
        raise SystemExit("self-contained archive requires a bundle")
    # Verify without borrowing any objects from the source repository. Scratch
    # metadata stays beside the archive, never in a host /tmp worktree.
    with tempfile.TemporaryDirectory(prefix='.archive-verify-', dir=archive.parent) as temporary:
        init = ["git", "init", "--bare", "--quiet", temporary]
        if policy is not None:
            init.append('--object-format=' + ('sha256' if len(manifest['head_sha']) == 64 else 'sha1'))
        subprocess.run(init, check=True)
        if manifest.get('self_contained') is not True:
            from worktree_archive_snapshot import seed_base
            seed_base(pathlib.Path(temporary), manifest)
        if bundle.is_file():
            subprocess.run(["git", f"--git-dir={temporary}", "bundle", "verify", str(bundle)],
                           check=True, stdout=subprocess.DEVNULL)
        if policy is not None:
            from worktree_archive_snapshot import verify_administration
            verify_administration(archive, pathlib.Path(temporary), manifest)
elif bundle.exists():
    common_dir = manifest.get('source_git_common_dir', "")
    command = ["git"]
    if common_dir and pathlib.Path(common_dir).is_dir():
        command.append(f"--git-dir={common_dir}")
    command.extend(["bundle", "verify", str(bundle)])
    subprocess.run(command, check=True, stdout=subprocess.DEVNULL)
payload = archive / "untracked.tar.gz"
if payload.exists():
    with tarfile.open(payload, "r:gz") as source:
        for member in source.getmembers():
            path = pathlib.PurePosixPath(member.name)
            link = pathlib.PurePosixPath(member.linkname) if member.issym() else None
            resolved_link = pathlib.PurePosixPath(posixpath.normpath(str(path.parent / link))) if link else None
            if (path.is_absolute() or ".." in path.parts or member.isdev() or
                    member.islnk() or (link and link.is_absolute()) or
                    (resolved_link and ".." in resolved_link.parts)):
                raise SystemExit("unsafe untracked archive member")
print(f"verified {archive}")
PY
	return $?
}

prepare_restore_repository() {
	local archive_dir="$1"
	local target="$2"
	local common_dir head_sha self_contained restore_branch
	IFS=$'\t' read -r common_dir head_sha self_contained < <(python3 - "$archive_dir/manifest.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1], encoding='utf-8'))
print(m.get('source_git_common_dir', ""), m["head_sha"],
      int(m.get('self_contained') is True), sep=chr(9))
PY
	)
	if [[ "$self_contained" -eq 1 ]]; then
		git -c gc.auto=0 -c maintenance.auto=false -c core.hooksPath=/dev/null \
			clone --quiet --no-checkout -- "$archive_dir/commits.bundle" "$target" || return 1
		git -C "$target" -c core.hooksPath=/dev/null checkout --quiet --detach "$head_sha" || return 1
	elif [[ -f "$archive_dir/git-admin.json" ]]; then
		python3 "${SCRIPT_DIR}/worktree_archive_snapshot.py" admin-prepare-restore "$archive_dir" "$target" || return 1
	else
		[[ -d "$common_dir" ]] || { die "source Git repository is unavailable: $common_dir"; return 1; }
		if [[ -f "$archive_dir/commits.bundle" ]]; then
			git --git-dir="$common_dir" fetch "$archive_dir/commits.bundle" HEAD >/dev/null || return 1
		fi
		restore_branch="archive-restore-$(date -u '+%Y%m%d%H%M%S')-$$"
		git --git-dir="$common_dir" worktree add -b "$restore_branch" "$target" "$head_sha" >/dev/null || return 1
	fi
	return 0
}

restore_archive() {
	local archive_dir="${1:-}"
	shift || true
	local target=""
	validate_archive_dir "$archive_dir" || return 1
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--target) require_value "$1" "${2:-}" || return 1; target="$2"; shift 2 ;;
		*) die "unknown restore option: $1"; return 1 ;;
		esac
	done
	[[ -n "$target" && ! -e "$target" ]] || { die "restore target must not exist"; return 1; }
	verify_archive "$archive_dir" >/dev/null || return 1
	prepare_restore_repository "$archive_dir" "$target" || return 1
	if [[ -s "$archive_dir/staged.patch" ]]; then git -C "$target" apply --index "$archive_dir/staged.patch" || return 1; fi
	if [[ -s "$archive_dir/diff.patch" ]]; then git -C "$target" apply "$archive_dir/diff.patch" || return 1; fi
	if [[ -f "$archive_dir/untracked.tar.gz" ]]; then
		python3 - "$archive_dir/untracked.tar.gz" "$target" <<'PY' || return 1
import pathlib
import os
import posixpath
import shutil
import sys
import tarfile
source = pathlib.Path(sys.argv[1])
target = pathlib.Path(sys.argv[2]).resolve()

def open_parent(parts):
    descriptor = os.open(target, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for name in parts:
            try:
                os.mkdir(name, dir_fd=descriptor)
            except FileExistsError:
                pass
            child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                            dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise

with tarfile.open(source, "r:gz") as payload:
    for member in payload.getmembers():
        path = pathlib.PurePosixPath(member.name)
        link = pathlib.PurePosixPath(member.linkname) if member.issym() else None
        resolved_link = pathlib.PurePosixPath(posixpath.normpath(str(path.parent / link))) if link else None
        if (not path.parts or path.parts[0] == '.git' or
                path.is_absolute() or ".." in path.parts or member.isdev() or
                member.islnk() or (link and link.is_absolute()) or
                (resolved_link and ".." in resolved_link.parts)):
            raise SystemExit("unsafe untracked archive member")
        parent = open_parent(path.parts[:-1])
        try:
            name = path.parts[-1]
            if member.isdir():
                os.mkdir(name, dir_fd=parent)
            elif member.issym():
                os.symlink(member.linkname, name, dir_fd=parent)
            elif member.isfile():
                source_file = payload.extractfile(member)
                if source_file is None:
                    raise SystemExit("missing untracked file payload")
                descriptor = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                                     os.O_NOFOLLOW, 0o600, dir_fd=parent)
                with os.fdopen(descriptor, 'wb') as output:
                    shutil.copyfileobj(source_file, output)
                    os.fchmod(output.fileno(), member.mode & 0o777)
            else:
                raise SystemExit("unsupported untracked archive member")
        finally:
            os.close(parent)
PY
	fi
	if [[ -f "$archive_dir/git-admin.json" ]]; then
		python3 "${SCRIPT_DIR}/worktree_archive_snapshot.py" admin-restore "$target" "$archive_dir" || return 1
	fi
	printf '%s\n' "$target"
	return 0
}

list_archives() {
	local repo="" issue="" output_root="$ARCHIVE_ROOT"
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--repo) require_value "$1" "${2:-}" || return 1; repo="$2"; shift 2 ;;
		--issue) require_value "$1" "${2:-}" || return 1; issue="$2"; shift 2 ;;
		--output-root) require_value "$1" "${2:-}" || return 1; output_root="$2"; shift 2 ;;
		*) die "unknown list option: $1"; return 1 ;;
		esac
	done
	[[ -z "$repo" ]] || validate_repo "$repo" || return 1
	[[ -z "$issue" ]] || validate_issue "$issue" || return 1
	python3 - "$output_root" "$repo" "$issue" <<'PY'
import json
import pathlib
import sys
root = pathlib.Path(sys.argv[1])
repo_filter, issue_filter = sys.argv[2:]
if root.is_dir():
    for manifest_path in sorted(root.glob("*/*/*/manifest.json")):
        try:
            manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
        except (OSError, ValueError):
            continue
        if repo_filter and manifest.get('repo') != repo_filter:
            continue
        if issue_filter and str(manifest.get('issue')) != issue_filter:
            continue
        print(f"{manifest.get('created_at', '-')}\t{manifest.get('repo', '-')}#{manifest.get('issue', '-')}\t{manifest.get('reason', '-')}\t{manifest_path.parent}")
PY
	return $?
}

prune_archives() {
	local older_than="" max_total="" mode="" output_root="$ARCHIVE_ROOT"
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--older-than) require_value "$1" "${2:-}" || return 1; older_than="$2"; shift 2 ;;
		--max-total-size) require_value "$1" "${2:-}" || return 1; max_total="$2"; shift 2 ;;
		--dry-run) [[ -z "$mode" ]] || { die "choose only one prune mode"; return 1; }; mode="dry-run"; shift ;;
		--apply) [[ -z "$mode" ]] || { die "choose only one prune mode"; return 1; }; mode="apply"; shift ;;
		--output-root) require_value "$1" "${2:-}" || return 1; output_root="$2"; shift 2 ;;
		*) die "unknown prune option: $1"; return 1 ;;
		esac
	done
	[[ "$older_than" =~ ^[1-9][0-9]*d$ ]] || { die "--older-than must use positive day syntax such as 14d"; return 1; }
	[[ "$max_total" =~ ^[1-9][0-9]*([KMGTP])?$ ]] || { die "invalid --max-total-size"; return 1; }
	[[ -n "$mode" ]] || { die "prune requires --dry-run or --apply"; return 1; }
	python3 "${SCRIPT_DIR}/worktree_archive_prune.py" "$output_root" "${older_than%d}" \
		"$max_total" "$mode" "${SCRIPT_DIR}/worktree-archive-helper.sh"
	return $?
}

main() {
	local command="${1:-help}"
	shift || true
	case "$command" in
	archive) archive_worktree "$@" ;;
	restore) restore_archive "$@" ;;
	list) list_archives "$@" ;;
	verify) [[ $# -eq 1 ]] || { usage >&2; return 1; }; verify_archive "$1" ;;
	source-matches) [[ $# -eq 2 ]] || { usage >&2; return 1; }; source_matches "$@" ;;
	prune) prune_archives "$@" ;;
	help|-h|--help) usage ;;
	*) usage >&2; return 1 ;;
	esac
	return $?
}

main "$@"
