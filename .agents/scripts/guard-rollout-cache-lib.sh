#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Conservative setup optimization: receipts never replace installer policy.

[[ -n "${_AIDEVOPS_GUARD_CACHE_LOADED:-}" ]] && return 0
_AIDEVOPS_GUARD_CACHE_LOADED=1
GUARD_CACHE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=git-hooks-path-lib.sh
source "${GUARD_CACHE_LIB_DIR}/git-hooks-path-lib.sh"

guard_rollout_hash() {
	local digest=""
	if command -v sha256sum >/dev/null 2>&1; then
		digest=$(sha256sum "$@" 2>/dev/null) || return 1
	else
		digest=$(shasum -a 256 "$@" 2>/dev/null) || return 1
	fi
	printf '%s\n' "$digest"
	return 0
}

# Once per rollout stage, not per repository. Hash contents (not mtimes),
# including the source templates and resolver used by the installer.
guard_rollout_fingerprint() {
	local installer="$1"
	local dir="${installer%/*}" inputs=""
	dir=$(cd "$dir" && pwd) || return 1
	installer="$dir/${installer##*/}"
	inputs=$(guard_rollout_hash "$installer" \
		"$GUARD_CACHE_LIB_DIR/guard-rollout-cache-lib.sh" \
		"$dir/git-hooks-path-lib.sh" "$dir"/../hooks/*.sh \
		"$dir/pre-commit-hook.sh") || return 1
	printf '%s\n' "$inputs" | guard_rollout_hash
	return "${PIPESTATUS[1]}"
}

# A receipt binds the entire executable dispatcher, not just a copyable header.
# Rewrites by another installer invalidate it safely. Never source receipts.
guard_rollout_record() {
	local hook="$1" installer="$2"
	local fingerprint="" digest="" staged=""
	[[ -f "$hook" && ! -L "$hook" && -x "$hook" ]] || return 1
	fingerprint=$(guard_rollout_fingerprint "$installer") || return 1
	digest=$(guard_rollout_hash "$hook") || return 1
	staged=$(mktemp "${hook}.aidevops-current.XXXXXX") || return 1
	if ! printf '%s\n%s\n' "$fingerprint" "$digest" >"$staged" ||
		! mv -f "$staged" "${hook}.aidevops-current"; then
		rm -f "$staged"
		return 1
	fi
	return 0
}

# Batch file reads and hashing in one process per stage. Git itself resolves
# hooksPath (including includes/worktrees); old Git or any uncertainty is a miss.
# Without Python the original installers remain the sole execution path.
guard_rollout_scan() {
	local registry="$1" hook_name="$2" marker="$3" fingerprint="$4"
	local registrations="${5:-$1}"
	[[ -n "$fingerprint" ]] && command -v python3 >/dev/null 2>&1 || return 1
	python3 - "$registry" "$hook_name" "$marker" "$fingerprint" "$registrations" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

registry, name, marker, fingerprint, registrations = sys.argv[1:]
try:
    entries = json.loads(Path(registry).read_text())["initialized_repos"]
    registered = {entry["path"] for entry in json.loads(Path(registrations).read_text())["initialized_repos"]
                  if "code-quality" in entry.get("features", [])}
except (OSError, ValueError, KeyError, TypeError):
    sys.exit(1)
for entry in entries:
    try:
        repo = entry["path"]
        if not isinstance(repo, str) or "\n" in repo:
            continue
        # Match the existing rollout's leading-tilde expansion, not ~username.
        if name != "pre-push" or marker != "# guard:repo-verify":
            repo = os.environ["HOME"] + repo[1:] if repo.startswith("~") else repo
        if not (Path(repo) / ".git").exists():
            continue
        if marker == "# guard:repo-verify":
            config = json.loads((Path(repo) / ".aidevops.json").read_text())
            if (repo not in registered or config.get("features", {}).get("code_quality") is not True
                    or config.get("verify", {}).get("enabled") is False):
                continue
        result = subprocess.run(["git", "-C", repo, "rev-parse", "--path-format=absolute", "--git-path", "hooks"],
                                capture_output=True, text=True, timeout=5, check=True)
        directory = result.stdout.rstrip("\n")
        if not directory.startswith("/") or "\n" in directory:
            continue
        hook = Path(directory) / name
        if hook.is_symlink() or not hook.is_file() or not os.access(hook, os.X_OK):
            continue
        receipt = Path(str(hook) + ".aidevops-current").read_text().rstrip("\n")
        if not receipt.startswith(fingerprint + "\n"):
            continue
        data = hook.read_bytes()
        digest = hashlib.sha256(data).hexdigest() + "  " + str(hook)
        if marker.encode() in data.splitlines() and receipt == fingerprint + "\n" + digest:
            print(repo)
    except (OSError, ValueError, KeyError, TypeError, AttributeError, subprocess.SubprocessError):
        continue
PY
	return $?
}

# The caller owns a stage-local snapshot, never a persistent path-resolution cache.
guard_rollout_current() {
	local repo="$1" current_repos="$2"
	case $'\n'"$current_repos"$'\n' in
	*$'\n'"$repo"$'\n'*) return 0 ;;
	esac
	return 1
}
