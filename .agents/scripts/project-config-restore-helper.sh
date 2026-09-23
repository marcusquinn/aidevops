#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

# Explicit local-only repair. Never call init, register_repo, or Git write commands.
set -euo pipefail
umask 077

usage() {
	printf '%s\n' 'Usage: aidevops project-config restore <registered-slug> [--backup FILE] [--apply]' \
		'Preview by default. --apply requires an attached terminal and typing the registered path.' \
		'Without a backup, only explicitly enabled registry features and a valid init_scope are recovered.'
}

[[ "${1:-}" == "restore" ]] || { usage; exit 2; }
shift
[[ $# -gt 0 && "$1" != -* ]] || { usage; exit 2; }
selector="$1"
shift
backup="" apply=false
while [[ $# -gt 0 ]]; do
	case "$1" in
	--backup) [[ $# -ge 2 && -z "$backup" ]] || exit 2; backup="$2"; shift 2 ;;
	--apply) apply=true; shift ;;
	*) usage; exit 2 ;;
	esac
done

command -v jq >/dev/null || { printf 'jq is required\n' >&2; exit 1; }
registry="${AIDEVOPS_REPOS_FILE:-${HOME}/.config/aidevops/repos.json}"
[[ -f "$registry" && ! -L "$registry" ]] || { printf 'Missing or unsafe registry\n' >&2; exit 1; }
count=$(jq -er --arg slug "$selector" '[.initialized_repos[]? | select(.slug == $slug)] | length' "$registry") || exit 1
[[ "$count" == 1 ]] || { printf 'Expected exactly one registered slug\n' >&2; exit 1; }
repo=$(jq -er --arg slug "$selector" '.initialized_repos[] | select(.slug == $slug) | .path | select(type == "string" and length > 0)' "$registry") || exit 1
registry_digest=$(cksum <"$registry") || exit 1
[[ "$repo" == /* && -d "$repo" && ! -L "$repo" ]] || { printf 'Unsafe registered path\n' >&2; exit 1; }
real_repo=$(cd "$repo" && pwd -P) || exit 1
# Capture each platform probe separately: GNU stat -f can print filesystem
# metadata before failing, which must not contaminate the fallback UID.
owner=$(stat -c '%u' "$repo" 2>/dev/null) || owner=""
if [[ ! "$owner" =~ ^[0-9]+$ ]]; then
	owner=$(stat -f '%u' "$repo" 2>/dev/null) || owner=""
fi
[[ "$repo" == "$real_repo" && "$owner" =~ ^[0-9]+$ && "$(id -u)" == "$owner" ]] || { printf 'Registered path or owner changed\n' >&2; exit 1; }
git_root=$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null) || exit 1
[[ "$git_root" == "$repo" ]] || { printf 'Registration does not point to repository root\n' >&2; exit 1; }
common=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir) || exit 1
gitdir=$(git -C "$repo" rev-parse --path-format=absolute --git-dir) || exit 1
[[ "$gitdir" == "$common" ]] || { printf 'Registered path is a linked worktree\n' >&2; exit 1; }
remote=$(git -C "$repo" remote get-url origin 2>/dev/null || true)
if [[ -n "$remote" ]]; then
	case "$remote" in
	"https://github.com/$selector" | "https://github.com/$selector.git" | "git@github.com:$selector" | "git@github.com:$selector.git") ;;
	*) printf 'Registered slug does not match repository origin\n' >&2; exit 1 ;;
	esac
else
	jq -e --arg slug "$selector" '.initialized_repos[] | select(.slug == $slug) | .local_only == true' "$registry" >/dev/null || { printf 'Missing origin on non-local registration\n' >&2; exit 1; }
fi
target="$repo/.aidevops.json"
[[ ! -L "$target" ]] || { printf 'Config symlink refused\n' >&2; exit 1; }
if [[ -e "$target" ]]; then
	printf 'Existing config preserved: %s\n' "$target"
	exit 0
fi
if git -C "$repo" ls-files --error-unmatch -- .aidevops.json >/dev/null 2>&1; then
	printf 'Tracked config requires the audited linked-worktree migration\n' >&2
	exit 1
fi
# Require an explicit root ignore rule; this deliberately fails closed for repos
# that rely on broader/global patterns. Avoid Git operations that change indexes.
[[ -f "$repo/.gitignore" && ! -L "$repo/.gitignore" ]] &&
	grep -Eq '^/?\.aidevops\.json$' "$repo/.gitignore" &&
	! grep -Eq '^!/?\.aidevops\.json$' "$repo/.gitignore" || { printf 'Explicit safe .gitignore rule required\n' >&2; exit 1; }

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) || exit 1
if [[ -n "$backup" ]]; then
	[[ -f "$backup" && ! -L "$backup" ]] || { printf 'Unsafe backup\n' >&2; exit 1; }
	jq -e 'type == "object" and (.version | type == "string") and (.features | type == "object")' "$backup" >/dev/null || { printf 'Invalid backup schema\n' >&2; exit 1; }
	backup_digest=$(cksum <"$backup") || exit 1
	printf 'Source: verified JSON backup %s (verify provenance and local-only settings before applying)\n' "$backup"
	jq '{version, init_scope, features, plugins: (if has("plugins") then "present (details redacted)" else "unknown" end), counter_branch: (if has("counter_branch") then "present (redacted)" else "unknown" end)}' "$backup"
else
	# Only names explicitly present in the registration can be restored as true.
	# Missing feature names remain absent, not false; unknown labels fail closed.
	features=$(jq -ec --arg slug "$selector" '
		.initialized_repos[] | select(.slug == $slug) | (.features // []) |
		if type != "array" or any(.[]; type != "string" or (IN("planning","git-workflow","code-quality","time-tracking","database","beads","sops","security","deployment-context","wordpress-context") | not)) then error("unknown feature")
		else reduce .[] as $f ({}; . + {($f | gsub("-"; "_")): true}) end
	' "$registry") || { printf 'Unknown or malformed registry features; use a verified backup\n' >&2; exit 1; }
	scope=$(jq -er --arg slug "$selector" '.initialized_repos[] | select(.slug == $slug) | .init_scope | select(. == "minimal" or . == "standard" or . == "public")' "$registry") || { printf 'Unknown init_scope; use a verified backup\n' >&2; exit 1; }
	version_file="$script_dir/../../VERSION"
	[[ -f "$version_file" ]] || version_file="$script_dir/../VERSION"
	[[ -f "$version_file" ]] || { printf 'Framework version unavailable\n' >&2; exit 1; }
	version=$(<"$version_file")
	printf 'Source: registration (enabled features only; missing flags and local-only options are UNKNOWN)\n'
	printf 'Proposed init_scope: %s; enabled features: %s; framework version: %s\n' "$scope" "$features" "$version"
fi
printf 'Destination: %s\n' "$target"
[[ "$apply" == true ]] || { printf 'Preview only. Review local-only fields before running --apply.\n'; exit 0; }
[[ -t 0 && -t 1 ]] || { printf 'An attached terminal is required for local metadata repair\n' >&2; exit 1; }
printf 'Type the exact destination to confirm: '
IFS= read -r confirmation
[[ "$confirmation" == "$target" ]] || { printf 'Confirmation mismatch\n' >&2; exit 1; }
[[ "$registry_digest" == "$(cksum <"$registry")" ]] || { printf 'Registry changed during confirmation\n' >&2; exit 1; }
if [[ -n "$backup" ]]; then
	[[ -f "$backup" && ! -L "$backup" && "$backup_digest" == "$(cksum <"$backup")" ]] || { printf 'Backup changed during confirmation\n' >&2; exit 1; }
fi

# Revalidate after confirmation; no rename-overwrite: link is atomic and fails if
# another writer created the destination during preview or confirmation.
[[ ! -e "$target" && ! -L "$target" && "$repo" == "$(cd "$repo" && pwd -P)" ]] || { printf 'Target changed\n' >&2; exit 1; }
[[ "$(git -C "$repo" rev-parse --show-toplevel)" == "$repo" && "$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)" == "$(git -C "$repo" rev-parse --path-format=absolute --git-dir)" ]] || exit 1
[[ "$(git -C "$repo" remote get-url origin 2>/dev/null || true)" == "$remote" ]] || exit 1
[[ -f "$repo/.gitignore" && ! -L "$repo/.gitignore" ]] &&
	grep -Eq '^/?\.aidevops\.json$' "$repo/.gitignore" &&
	! grep -Eq '^!/?\.aidevops\.json$' "$repo/.gitignore" || exit 1
! git -C "$repo" ls-files --error-unmatch -- .aidevops.json >/dev/null 2>&1 || exit 1
tmp=$(mktemp "${repo}/.aidevops.json.restore.XXXXXX") || exit 1
trap 'rm -f "$tmp"' EXIT
if [[ -n "$backup" ]]; then
	# Preserve the backed-up JSON and local options, not an init-derived default.
	jq . "$backup" >"$tmp"
else
	jq -n --arg version "$version" --arg scope "$scope" --argjson features "$features" '{version:$version,init_scope:$scope,features:$features}' >"$tmp"
fi
chmod 600 "$tmp"
ln "$tmp" "$target" || { printf 'Target appeared during restore; left unchanged\n' >&2; exit 1; }
if [[ "$(git -C "$repo" status --short --ignored -- .aidevops.json)" != '!! .aidevops.json' ]]; then
	[[ "$target" -ef "$tmp" ]] && rm -f "$target"
	printf 'Git does not ignore the restored config; rolled back\n' >&2
	exit 1
fi
printf 'Restored ignored local config: %s\n' "$target"
