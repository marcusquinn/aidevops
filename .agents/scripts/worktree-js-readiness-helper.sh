#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# worktree-js-readiness-helper.sh -- JavaScript verification-tool readiness
# =============================================================================
# GH#34199: bounded, read-only probe of whether the project-declared
# verification commands (format/lint/typecheck, resolved by
# repo-verify-config-lib.sh) can start in a worktree. It checks worktree-local
# tool binaries and, for ESLint/Next, that every bare package imported by the
# flat config resolves from the worktree root.
#
# The probe never runs a linter, never installs or copies dependencies, never
# reads the canonical checkout, and never accepts a PATH/global binary as ready.
#
# GH#34200: `prepare` (called by worktree-helper.sh add) runs a frozen-lockfile,
# lifecycle-scripts-disabled install into the worktree's own node_modules only
# when the owner recorded a durable approval (`approve`, interactive only) in
# the repo's repos.json entry (`js_dependency_policy`) and its lockfile hash,
# package manager and Node major still match.
#
# Usage:
#   worktree-js-readiness-helper.sh probe <worktree> [--json] [--no-cache]
#   worktree-js-readiness-helper.sh report <worktree>
#   worktree-js-readiness-helper.sh entry <worktree> <session-key>
#   worktree-js-readiness-helper.sh record-restore <worktree> <outcome> [reason]
#   worktree-js-readiness-helper.sh prepare <worktree> [--lock-held]
#   worktree-js-readiness-helper.sh approve|revoke|status <repo-or-worktree>
#
# States:
#   ready                        every declared JS tool can start
#   preparation-needed:<reason>  worktree-local dependencies are missing
#   preparing:<reason>           a concurrent restore held the lock just now
#   blocked:<reason>             automatic preparation refused, or probe failed
#   not-applicable:<reason>      no declared JavaScript verification tool
#
# State files (untracked, inside the worktree's own git dir, removed with the
# worktree): aidevops/js-readiness.json (cache), aidevops/js-restore.json
# (last restore outcome), aidevops/js-readiness-entry (last reported session),
# aidevops/js-prepare.json (last policy install outcome) and
# aidevops/js-install-partial (marks an install in progress or interrupted).
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"
# shellcheck source=repo-verify-config-lib.sh
source "${SCRIPT_DIR}/repo-verify-config-lib.sh"

: "${AIDEVOPS_JS_READINESS_PROBE_TIMEOUT_S:=10}"
: "${AIDEVOPS_JS_READINESS_CONTENTION_WINDOW_S:=120}"
: "${AIDEVOPS_JS_POLICY_INSTALL_TIMEOUT_S:=300}"
readonly JSR_SCHEMA=1
readonly JSR_POLICY_SCOPE="worktree-install"
# Snapshot refusals about controller authority or worktree structure; a
# lockfile install must never route around them.
readonly JSR_NO_INSTALL_SNAPSHOT_REASONS=" controller-not-owner owner-contract-changed foreign-repository not-linked-worktree not-repository-root symlink-component "
readonly JSR_PREPARE_NEEDS_LOCK=3
readonly JSR_MAX_SPECIFIERS=64
readonly JSR_JS_TOOLS=" eslint next biome oxlint prettier tsc vue-tsc tsgo xo standard stylelint svelte-check astro "
readonly JSR_LOCKFILES="package-lock.json npm-shrinkwrap.json pnpm-lock.yaml yarn.lock bun.lock bun.lockb"
readonly JSR_FLAT_CONFIGS="eslint.config.js eslint.config.mjs eslint.config.cjs eslint.config.ts eslint.config.mts eslint.config.cts"
readonly JSR_STATE_READY="ready"
readonly JSR_NODE_MODULES_MISSING="preparation-needed:node-modules-missing"
readonly JSR_DOC_REF='tools/runtime/node-server-admin.md "Linked-worktree tooling readiness"'

JSR_STATE=""
JSR_TOOLS=""
JSR_CACHED=0
JSR_PM=""
JSR_LOCK_SHA=""
JSR_POLICY_STATUS=""
JSR_ARGV=()

_jsr_usage() {
	cat <<'USAGE'
Usage:
  worktree-js-readiness-helper.sh probe <worktree> [--json] [--no-cache]
  worktree-js-readiness-helper.sh report <worktree>
  worktree-js-readiness-helper.sh entry <worktree> <session-key>
  worktree-js-readiness-helper.sh record-restore <worktree> contention|rejected|provisioned [reason]
  worktree-js-readiness-helper.sh prepare <worktree> [--lock-held]
  worktree-js-readiness-helper.sh approve|revoke|status <repo-or-worktree>
USAGE
	return 0
}

# Print the worktree's private state directory. Only a directory that is
# itself the top level of a Git worktree qualifies, so a plain directory
# nested in another repository never writes into that repository.
_jsr_state_dir() {
	local wt="$1"
	local top="" git_dir=""
	top=$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null) || return 1
	[[ -n "$top" ]] || return 1
	[[ "$(cd "$top" && pwd -P)" == "$wt" ]] || return 1
	git_dir=$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null) || return 1
	[[ -n "$git_dir" && -d "$git_dir" ]] || return 1
	printf '%s/aidevops\n' "$git_dir"
	return 0
}

# Write via temp file + mv so readers never see a partial record.
_jsr_write_atomic() {
	local target="$1"
	local content="$2"
	local tmp=""
	mkdir -p "$(dirname "$target")" 2>/dev/null || return 1
	tmp=$(mktemp "${target}.XXXXXX") || return 1
	if printf '%s\n' "$content" >"$tmp" && mv -f "$tmp" "$target"; then
		return 0
	fi
	rm -f "$tmp"
	return 1
}

_jsr_sha256() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum | cut -d' ' -f1
	else
		shasum -a 256 | cut -d' ' -f1
	fi
	return 0
}

# Installed package and binary names (one readdir per level, no recursion).
# Names, not mtimes: second-resolution mtimes miss a remove/re-add within
# the same second, which would serve a stale readiness result.
_jsr_installed_names() {
	local modules="$1"
	local scope=""
	ls -A "$modules" 2>/dev/null || true
	ls -A "${modules}/.bin" 2>/dev/null || true
	for scope in "${modules}"/@*/; do
		if [[ -d "$scope" ]]; then
			printf '%s\n' "$scope"
			ls -A "$scope" 2>/dev/null || true
		fi
	done
	return 0
}

# Cache key: manifests, lockfiles, verify/lint config, installed package and
# binary names, the last restore outcome and the active Node identity.
_jsr_input_key() {
	local wt="$1"
	local state_dir="$2"
	local manifest="" name="" node_version=""
	# shellcheck disable=SC2086 # intentional word splitting of fixed name lists
	for name in package.json .aidevops.json .pnp.cjs $JSR_LOCKFILES $JSR_FLAT_CONFIGS; do
		[[ -f "${wt}/${name}" ]] || continue
		manifest+="${name} $(_jsr_sha256 <"${wt}/${name}")"$'\n'
	done
	if [[ -d "${wt}/node_modules" ]]; then
		manifest+="node_modules $(_jsr_installed_names "${wt}/node_modules" | _jsr_sha256)"$'\n'
	fi
	for name in js-restore.json js-prepare.json; do
		if [[ -f "${state_dir}/${name}" ]]; then
			manifest+="${name} $(_jsr_sha256 <"${state_dir}/${name}")"$'\n'
		fi
	done
	node_version=$(node --version 2>/dev/null || printf 'absent')
	manifest+="node ${node_version} $(command -v node 2>/dev/null || true)"$'\n'
	manifest+="schema ${JSR_SCHEMA}"
	printf '%s' "$manifest" | _jsr_sha256
	return 0
}

# Print the JavaScript tool a declared command starts, or nothing. Follows
# "<manager> run <script>" into package.json scripts (bounded depth) and
# strips env assignments and npx/exec-style runners. Unrecognized commands
# (shell scripts, make, paths) are not JavaScript verification tools.
_jsr_command_tool() {
	local wt="$1"
	local cmd="$2"
	local depth="${3:-0}"
	local segment="" word="" found="" body=""
	local via_manager=0 i=0
	local -a words=()
	((depth < 3)) || return 0
	segment="${cmd%%&&*}"
	segment="${segment%%||*}"
	segment="${segment%%;*}"
	segment="${segment%%|*}"
	read -r -a words <<<"$segment" || true
	while ((i < ${#words[@]})); do
		word="${words[$i]}"
		i=$((i + 1))
		case "$word" in
		*=* | env | cross-env | npx | pnpx | bunx | exec | x | dlx | -*) continue ;;
		npm | pnpm | yarn | bun)
			via_manager=1
			continue
			;;
		run | run-script) [[ "$via_manager" -eq 1 ]] && continue ;;
		esac
		found="$word"
		break
	done
	[[ -n "$found" ]] || return 0
	[[ "$found" == node_modules/.bin/* || "$found" == ./node_modules/.bin/* ]] && found="${found##*/}"
	if [[ "$JSR_JS_TOOLS" == *" ${found} "* ]]; then
		printf '%s\n' "$found"
		return 0
	fi
	[[ "$via_manager" -eq 1 && "$found" != */* ]] || return 0
	body=$(jq -r --arg s "$found" '.scripts[$s] // empty | strings' "${wt}/package.json" 2>/dev/null || true)
	[[ -n "$body" ]] || return 0
	_jsr_command_tool "$wt" "$body" $((depth + 1))
	return 0
}

_jsr_flat_config() {
	local wt="$1"
	local name=""
	for name in $JSR_FLAT_CONFIGS; do
		if [[ -f "${wt}/${name}" ]]; then
			printf '%s\n' "$name"
			return 0
		fi
	done
	return 0
}

# Bare package specifiers from import/require/from clauses. Relative,
# absolute and scheme-qualified (node:, file:) specifiers are excluded.
_jsr_config_specifiers() {
	local config_file="$1"
	{
		grep -Eo "(from|import|require)[[:space:]]*\(?[[:space:]]*['\"][^'\"]+['\"]" "$config_file" 2>/dev/null |
			sed -E "s/.*['\"]([^'\"]+)['\"]\$/\1/" |
			grep -Ev '^(\.|/|[A-Za-z][A-Za-z0-9+.-]*:)' |
			sort -u | awk -v max="$JSR_MAX_SPECIFIERS" 'NR <= max'
	} || true
	return 0
}

# Print package names that do not resolve from the worktree root using the
# Node package lookup chain (<dir>/node_modules/<pkg> walking upward).
# Builtins are skipped. NODE_OPTIONS is cleared so no preload can run.
_jsr_unresolved_packages() {
	local wt="$1"
	shift
	local script='
const path = require("path");
const fs = require("fs");
const mod = require("module");
const isBuiltin = mod.isBuiltin || ((s) => mod.builtinModules.includes(s));
const [root, ...specs] = process.argv.slice(1);
const dirs = [];
for (let d = root; ; d = path.dirname(d)) {
  if (path.basename(d) !== "node_modules") dirs.push(path.join(d, "node_modules"));
  if (path.dirname(d) === d) break;
}
const missing = [];
for (const spec of specs) {
  if (isBuiltin(spec)) continue;
  const parts = spec.split("/");
  const name = spec.startsWith("@") ? parts.slice(0, 2).join("/") : parts[0];
  if (!dirs.some((dir) => fs.existsSync(path.join(dir, name, "package.json")))) missing.push(name);
}
process.stdout.write([...new Set(missing)].join("\n"));
'
	timeout_sec "$AIDEVOPS_JS_READINESS_PROBE_TIMEOUT_S" env -u NODE_OPTIONS node -e "$script" "$wt" "$@"
	return $?
}

# Print the non-ready state for one tool, or nothing when it can start.
_jsr_tool_state() {
	local wt="$1"
	local tool="$2"
	local config="" spec="" missing="" rc=0
	local -a specs=()
	if [[ ! -x "${wt}/node_modules/.bin/${tool}" ]]; then
		printf 'preparation-needed:tool-missing-%s\n' "$tool"
		return 0
	fi
	case "$tool" in
	eslint | next) ;;
	*) return 0 ;;
	esac
	# `next lint` delegates to the project's own ESLint package.
	if [[ "$tool" == next ]]; then
		specs+=("eslint")
	fi
	config=$(_jsr_flat_config "$wt")
	if [[ -n "$config" ]]; then
		while IFS= read -r spec; do
			if [[ -n "$spec" ]]; then
				specs+=("$spec")
			fi
		done < <(_jsr_config_specifiers "${wt}/${config}")
		# ESLint loads TypeScript flat configs through jiti by default.
		if [[ "$config" == *.ts || "$config" == *.mts || "$config" == *.cts ]]; then
			specs+=("jiti")
		fi
	fi
	[[ "${#specs[@]}" -gt 0 ]] || return 0
	if ! command -v node >/dev/null 2>&1; then
		printf 'blocked:node-missing\n'
		return 0
	fi
	missing=$(_jsr_unresolved_packages "$wt" "${specs[@]}") || rc=$?
	if [[ "$rc" -eq 124 ]]; then
		printf 'blocked:probe-timeout\n'
		return 0
	elif [[ "$rc" -ne 0 ]]; then
		printf 'blocked:probe-failed\n'
		return 0
	fi
	[[ -n "$missing" ]] || return 0
	printf 'preparation-needed:config-import-unresolved-%s\n' "$(printf '%s' "${missing%%$'\n'*}" | tr '@/' '-' | sed 's/^-//')"
	return 0
}

# A restore that never produced node_modules explains why: contention is
# transient (preparing) only within the window; a refused snapshot is blocked.
_jsr_apply_restore_outcome() {
	local state_dir="$1"
	local record="${state_dir}/js-restore.json"
	local outcome="" reason="" at=0 now=0
	[[ -n "$state_dir" && -f "$record" ]] || return 0
	outcome=$(jq -r '.outcome // empty' "$record" 2>/dev/null || true)
	reason=$(jq -r '.reason // empty' "$record" 2>/dev/null || true)
	at=$(jq -r '.at // 0' "$record" 2>/dev/null || printf '0')
	[[ "$at" =~ ^[0-9]+$ ]] || at=0
	case "$outcome" in
	contention)
		now=$(date +%s)
		if ((now - at <= AIDEVOPS_JS_READINESS_CONTENTION_WINDOW_S)); then
			JSR_STATE="preparing:lock-contention"
		else
			JSR_STATE="preparation-needed:restore-skipped-lock-contention"
		fi
		;;
	rejected) JSR_STATE="blocked:snapshot-${reason:-provision-refused}" ;;
	esac
	return 0
}

# GH#34200: a refused policy install explains a still-missing tool, but only
# for the lockfile it was evaluated against; never overrides preparing:*.
_jsr_apply_prepare_outcome() {
	local wt="$1"
	local state_dir="$2"
	local record="${state_dir}/js-prepare.json"
	local outcome="" reason="" lock=""
	[[ -n "$state_dir" && -f "$record" ]] || return 0
	case "$JSR_STATE" in
	preparation-needed:* | blocked:snapshot-*) ;;
	*) return 0 ;;
	esac
	outcome=$(jq -r '.outcome // empty' "$record" 2>/dev/null || true)
	reason=$(jq -r '.reason // empty' "$record" 2>/dev/null || true)
	lock=$(jq -r '.lockfile_sha256 // empty' "$record" 2>/dev/null || true)
	[[ "$outcome" == blocked && "$reason" =~ ^[a-z0-9-]{1,64}$ ]] || return 0
	_jsr_lock_identity "$wt" || JSR_LOCK_SHA=""
	[[ "$lock" == "$JSR_LOCK_SHA" ]] || return 0
	JSR_STATE="blocked:${reason}"
	return 0
}

# Compute JSR_STATE/JSR_TOOLS without a cache. Runs in the current shell so
# repo-verify detection globals stay available.
_jsr_compute() {
	local wt="$1"
	local state_dir="$2"
	local cmd="" tool="" tool_state=""
	JSR_STATE=""
	JSR_TOOLS=""
	if [[ ! -f "${wt}/package.json" ]]; then
		JSR_STATE="not-applicable:no-package-json"
		return 0
	fi
	if [[ -f "${wt}/.pnp.cjs" ]]; then
		JSR_STATE="not-applicable:yarn-pnp"
		return 0
	fi
	repo_verify_detect "$wt" >/dev/null 2>&1 || true
	if [[ "$REPO_VERIFY_STATUS" != "$REPO_VERIFY_VALUE_READY" ]]; then
		JSR_STATE="not-applicable:verify-${REPO_VERIFY_STATUS:-none}"
		return 0
	fi
	for cmd in "$REPO_VERIFY_FORMAT" "$REPO_VERIFY_LINT" "$REPO_VERIFY_TYPECHECK"; do
		[[ -n "$cmd" ]] || continue
		tool=$(_jsr_command_tool "$wt" "$cmd")
		[[ -n "$tool" && " ${JSR_TOOLS} " != *" ${tool} "* ]] || continue
		JSR_TOOLS="${JSR_TOOLS:+${JSR_TOOLS} }${tool}"
	done
	if [[ -z "$JSR_TOOLS" ]]; then
		JSR_STATE="not-applicable:no-js-verification-tool"
		return 0
	fi
	if [[ ! -d "${wt}/node_modules" ]]; then
		JSR_STATE="$JSR_NODE_MODULES_MISSING"
		_jsr_apply_restore_outcome "$state_dir"
		_jsr_apply_prepare_outcome "$wt" "$state_dir"
		return 0
	fi
	for tool in $JSR_TOOLS; do
		tool_state=$(_jsr_tool_state "$wt" "$tool")
		if [[ -n "$tool_state" ]]; then
			JSR_STATE="$tool_state"
			_jsr_apply_prepare_outcome "$wt" "$state_dir"
			return 0
		fi
	done
	JSR_STATE="$JSR_STATE_READY"
	return 0
}

_jsr_resolve_worktree() {
	local wt="$1"
	[[ -n "$wt" && -d "$wt" ]] || {
		printf 'worktree-js-readiness: not a directory: %s\n' "$wt" >&2
		return 1
	}
	(cd "$wt" && pwd -P)
	return $?
}

# Probe with cache reuse; sets JSR_STATE, JSR_TOOLS and JSR_CACHED.
_jsr_probe() {
	local wt="$1"
	local use_cache="$2"
	local state_dir="" key="" cache="" cached_key="" content=""
	JSR_CACHED=0
	state_dir=$(_jsr_state_dir "$wt") || state_dir=""
	if [[ -n "$state_dir" ]]; then
		key=$(_jsr_input_key "$wt" "$state_dir")
		cache="${state_dir}/js-readiness.json"
	fi
	if [[ "$use_cache" -eq 1 && -n "$cache" && -f "$cache" ]]; then
		cached_key=$(jq -r --argjson schema "$JSR_SCHEMA" 'select(.schema == $schema) | .key // empty' "$cache" 2>/dev/null || true)
		if [[ -n "$cached_key" && "$cached_key" == "$key" ]]; then
			JSR_STATE=$(jq -r '.state // empty' "$cache" 2>/dev/null || true)
			JSR_TOOLS=$(jq -r '.tools // empty' "$cache" 2>/dev/null || true)
			if [[ -n "$JSR_STATE" ]]; then
				JSR_CACHED=1
				return 0
			fi
		fi
	fi
	_jsr_compute "$wt" "$state_dir"
	# preparing:* is transient by definition; never serve it from cache.
	if [[ -n "$cache" && "$JSR_STATE" != preparing:* ]]; then
		content=$(jq -cn --argjson schema "$JSR_SCHEMA" --arg key "$key" --arg state "$JSR_STATE" \
			--arg tools "$JSR_TOOLS" --argjson at "$(date +%s)" \
			'{schema:$schema,key:$key,state:$state,tools:$tools,checked_at:$at}')
		_jsr_write_atomic "$cache" "$content" || true
	fi
	return 0
}

# --- GH#34200: durable owner-approved install policy -------------------------

# Package-manager identity of a tree: exactly one supported lockfile and no
# conflicting packageManager field. Sets JSR_PM and JSR_LOCK_SHA.
_jsr_lock_identity() {
	local dir="$1"
	local name="" found="" count=0 declared=""
	JSR_PM=""
	JSR_LOCK_SHA=""
	for name in $JSR_LOCKFILES; do
		if [[ -f "${dir}/${name}" ]]; then
			found="$name"
			count=$((count + 1))
		fi
	done
	[[ "$count" -eq 1 ]] || return 1
	case "$found" in
	package-lock.json | npm-shrinkwrap.json) JSR_PM="npm" ;;
	pnpm-lock.yaml) JSR_PM="pnpm" ;;
	yarn.lock) JSR_PM="yarn" ;;
	*) JSR_PM="bun" ;;
	esac
	declared=$(jq -r '.packageManager // empty | strings' "${dir}/package.json" 2>/dev/null || true)
	if [[ -n "$declared" && "${declared%%@*}" != "$JSR_PM" ]]; then
		JSR_PM=""
		return 1
	fi
	local berry_re='^yarn@([2-9]|[1-9][0-9])'
	if [[ "$JSR_PM" == yarn ]] && [[ -f "${dir}/.yarnrc.yml" || "$declared" =~ $berry_re ]]; then
		JSR_PM="yarn-berry"
	fi
	JSR_LOCK_SHA=$(_jsr_sha256 <"${dir}/${found}")
	return 0
}

# Frozen-lockfile, lifecycle-scripts-disabled argv for JSR_PM (JSR_ARGV).
# Yarn Berry has no --ignore-scripts; YARN_ENABLE_SCRIPTS=false is always set.
_jsr_install_argv() {
	case "$JSR_PM" in
	npm) JSR_ARGV=(npm ci --ignore-scripts) ;;
	pnpm) JSR_ARGV=(pnpm install --frozen-lockfile --ignore-scripts) ;;
	yarn) JSR_ARGV=(yarn install --frozen-lockfile --ignore-scripts) ;;
	yarn-berry) JSR_ARGV=(yarn install --immutable) ;;
	bun) JSR_ARGV=(bun install --frozen-lockfile --ignore-scripts) ;;
	*) return 1 ;;
	esac
	return 0
}

_jsr_install_command() {
	local wt="$1"
	if ! _jsr_lock_identity "$wt" || ! _jsr_install_argv; then
		printf 'one supported lockfile with a frozen install and lifecycle scripts disabled'
		return 0
	fi
	[[ "$JSR_PM" != yarn-berry ]] || printf 'YARN_ENABLE_SCRIPTS=false '
	printf '%s' "${JSR_ARGV[*]}"
	return 0
}

_jsr_node_major() {
	local version=""
	version=$(node --version 2>/dev/null || true)
	version="${version#v}"
	version="${version%%.*}"
	[[ "$version" =~ ^[0-9]+$ ]] || version="none"
	printf '%s\n' "$version"
	return 0
}

_jsr_manager_bin() {
	local name="$1"
	local bin=""
	bin=$(command -v "$name" 2>/dev/null || true)
	if [[ -z "$bin" && "$name" == bun && -n "${HOME:-}" && -x "${HOME}/.bun/bin/bun" ]]; then
		bin="${HOME}/.bun/bin/bun"
	fi
	[[ -n "$bin" ]] || return 1
	printf '%s\n' "$bin"
	return 0
}

# Policy writes are owner decisions; refuse every headless/worker context.
_jsr_is_headless() {
	local marker="" lower=""
	for marker in "${AIDEVOPS_HEADLESS:-}" "${FULL_LOOP_HEADLESS:-}" "${OPENCODE_HEADLESS:-}" \
		"${CLAUDE_HEADLESS:-}" "${HEADLESS:-}" "${GITHUB_ACTIONS:-}"; do
		lower=$(printf '%s' "$marker" | tr '[:upper:]' '[:lower:]')
		case "$lower" in
		1 | true | yes | on) return 0 ;;
		esac
	done
	[[ -z "${WORKER_ISSUE_NUMBER:-}${WORKER_TASK_NUMBER:-}${WORKER_WORKTREE_PATH:-}" ]] || return 0
	return 1
}

_jsr_repos_file() {
	printf '%s\n' "${AIDEVOPS_REPOS_FILE:-${HOME:+$HOME/.config/aidevops/repos.json}}"
	return 0
}

# Canonical checkout path of a repository or linked worktree, derived from
# Git metadata only (no canonical file is read). It keys the repos.json entry.
_jsr_canonical_root() {
	local dir="$1"
	local common=""
	common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
	[[ -n "$common" && "${common##*/}" == ".git" ]] || return 1
	printf '%s\n' "${common%/.git}"
	return 0
}

_jsr_tilde_path() {
	local path="$1"
	if [[ -n "${HOME:-}" && "$path" == "${HOME}/"* ]]; then
		# Literal "~/" form, as some repos.json entries store it (not expanded).
		printf '%s/%s\n' '~' "${path#"${HOME}/"}"
	else
		printf '%s\n' "$path"
	fi
	return 0
}

_jsr_policy_get() {
	local canon="$1"
	local repos_file="" tilde=""
	repos_file=$(_jsr_repos_file)
	[[ -n "$repos_file" && -f "$repos_file" ]] || return 0
	tilde=$(_jsr_tilde_path "$canon")
	jq -c --arg p "$canon" --arg t "$tilde" \
		'first(.initialized_repos[]? | select(.path == $p or .path == $t) | .js_dependency_policy // empty | objects) // empty' \
		"$repos_file" 2>/dev/null || true
	return 0
}

# Set (policy JSON) or delete ("null") js_dependency_policy on the repo entry,
# reusing repo-verify's repos.json lock + temp file + mode-preserving mv.
# Returns 2 when the repository is not registered.
_jsr_policy_write() {
	local canon="$1"
	local policy="$2"
	local repos_file="" tilde="" temp_file="" rc=0
	repos_file=$(_jsr_repos_file)
	[[ -n "$repos_file" && -f "$repos_file" ]] || return 2
	tilde=$(_jsr_tilde_path "$canon")
	jq -e --arg p "$canon" --arg t "$tilde" 'any(.initialized_repos[]?; .path == $p or .path == $t)' \
		"$repos_file" >/dev/null 2>&1 || return 2
	_repo_verify_lock_acquire "$repos_file" || return 1
	temp_file=$(mktemp "${repos_file}.tmp.XXXXXX") || {
		_repo_verify_lock_release
		return 1
	}
	if jq --arg p "$canon" --arg t "$tilde" --argjson policy "$policy" '
		.initialized_repos = [(.initialized_repos // [])[] |
			if (.path == $p or .path == $t) then
				(if $policy == null then del(.js_dependency_policy) else .js_dependency_policy = $policy end)
			else . end]' "$repos_file" >"$temp_file"; then
		_repo_verify_preserve_mode "$repos_file" "$temp_file"
		mv -f "$temp_file" "$repos_file" || rc=1
	else
		rm -f "$temp_file"
		rc=1
	fi
	_repo_verify_lock_release
	return "$rc"
}

# JSR_POLICY_STATUS: none | current | unsupported-package-manager |
# stale-scope | stale-package-manager | stale-lockfile | stale-node-major
_jsr_policy_evaluate() {
	local dir="$1"
	local policy="$2"
	JSR_POLICY_STATUS="none"
	[[ -n "$policy" ]] || return 0
	if ! _jsr_lock_identity "$dir"; then
		JSR_POLICY_STATUS="unsupported-package-manager"
	elif [[ "$(jq -r '.scope // empty' <<<"$policy")" != "$JSR_POLICY_SCOPE" ]]; then
		JSR_POLICY_STATUS="stale-scope"
	elif [[ "$(jq -r '.package_manager // empty' <<<"$policy")" != "$JSR_PM" ]]; then
		JSR_POLICY_STATUS="stale-package-manager"
	elif [[ "$(jq -r '.lockfile_sha256 // empty' <<<"$policy")" != "$JSR_LOCK_SHA" ]]; then
		JSR_POLICY_STATUS="stale-lockfile"
	elif [[ "$(jq -r '.node_major // empty | tostring' <<<"$policy")" != "$(_jsr_node_major)" ]]; then
		JSR_POLICY_STATUS="stale-node-major"
	else
		JSR_POLICY_STATUS="current"
	fi
	return 0
}

_jsr_record_prepare() {
	local state_dir="$1"
	local outcome="$2"
	local reason="${3:-}"
	local command="${4:-}"
	local content=""
	content=$(jq -cn --arg outcome "$outcome" --arg reason "$reason" --arg command "$command" \
		--arg lock "$JSR_LOCK_SHA" --argjson at "$(date +%s)" \
		'{schema:1,outcome:$outcome,reason:$reason,command:$command,lockfile_sha256:$lock,at:$at}')
	_jsr_write_atomic "${state_dir}/js-prepare.json" "$content" || true
	return 0
}

# Only missing dependencies or a content/budget snapshot refusal qualify.
_jsr_install_eligible() {
	local reason=""
	case "$JSR_STATE" in
	preparation-needed:*) return 0 ;;
	blocked:snapshot-*)
		reason="${JSR_STATE#blocked:snapshot-}"
		[[ "$JSR_NO_INSTALL_SNAPSHOT_REASONS" == *" ${reason} "* ]] || return 0
		;;
	esac
	return 1
}

# Fail closed before installing. Removes only node_modules that this helper's
# own interrupted install left behind (js-install-partial marker).
_jsr_prepare_preflight() {
	local wt="$1"
	local state_dir="$2"
	local partial="${state_dir}/js-install-partial"
	if [[ -e "${wt}/node_modules" || -L "${wt}/node_modules" ]]; then
		if [[ -f "$partial" && -d "${wt}/node_modules" && ! -L "${wt}/node_modules" ]]; then
			rm -rf -- "${wt}/node_modules"
		else
			_jsr_record_prepare "$state_dir" blocked existing-node-modules
			return 1
		fi
	fi
	rm -f -- "$partial"
	if ! git -C "$wt" check-ignore -q --no-index node_modules/.package-lock.json 2>/dev/null; then
		_jsr_record_prepare "$state_dir" blocked node-modules-not-ignored
		return 1
	fi
	if [[ -n "$(git -C "$wt" status --porcelain --untracked-files=no 2>/dev/null || printf 'unknown')" ]]; then
		_jsr_record_prepare "$state_dir" blocked dirty-worktree
		return 1
	fi
	_jsr_install_argv || {
		_jsr_record_prepare "$state_dir" blocked unsupported-package-manager
		return 1
	}
	if ! _jsr_manager_bin "${JSR_ARGV[0]}" >/dev/null; then
		_jsr_record_prepare "$state_dir" blocked package-manager-missing "$(_jsr_install_command "$wt")"
		return 1
	fi
	return 0
}

# Run the approved install. Any Git-visible change rolls back node_modules
# and tracked files (the tree was tracked-clean before) and fails closed.
_jsr_prepare_install() {
	local wt="$1"
	local state_dir="$2"
	local display="" before="" after="" rc=0
	local -a argv=()
	display=$(_jsr_install_command "$wt")
	argv=("$(_jsr_manager_bin "${JSR_ARGV[0]}")" "${JSR_ARGV[@]:1}")
	before=$(git -C "$wt" status --porcelain 2>/dev/null) || return 0
	_jsr_write_atomic "${state_dir}/js-install-partial" "$display" || return 0
	printf 'JS_DEPENDENCY_PREPARE=installing (%s)\n' "$display"
	(cd "$wt" && timeout_sec "$AIDEVOPS_JS_POLICY_INSTALL_TIMEOUT_S" env -u NODE_OPTIONS \
		npm_config_ignore_scripts=true YARN_ENABLE_SCRIPTS=false "${argv[@]}") </dev/null 1>&2 || rc=$?
	after=$(git -C "$wt" status --porcelain 2>/dev/null || printf 'unknown')
	if [[ "$after" != "$before" || "$rc" -ne 0 ]]; then
		rm -rf -- "${wt}/node_modules"
		rm -f -- "${state_dir}/js-install-partial"
	fi
	if [[ "$after" != "$before" ]]; then
		git -C "$wt" checkout -q -- . 2>/dev/null || true
		_jsr_record_prepare "$state_dir" blocked install-mutated-tree "$display"
	elif [[ "$rc" -eq 124 ]]; then
		_jsr_record_prepare "$state_dir" blocked install-timeout "$display"
	elif [[ "$rc" -ne 0 ]]; then
		_jsr_record_prepare "$state_dir" blocked install-failed "$display"
	else
		rm -f -- "${state_dir}/js-install-partial"
		_jsr_record_prepare "$state_dir" installed "" "$display"
		printf 'JS_DEPENDENCY_PREPARE=installed (%s)\n' "$display"
	fi
	return 0
}

_jsr_prepare_hint() {
	local wt="$1"
	local command=""
	command=$(jq -r '.command // empty' "$(_jsr_state_dir "$wt" 2>/dev/null || printf '/nonexistent')/js-prepare.json" 2>/dev/null || true)
	case "$JSR_STATE" in
	blocked:policy-stale)
		printf 'the recorded js_dependency_policy no longer matches this lockfile, package manager or Node major, so nothing was installed; review the change, then re-approve interactively with worktree-js-readiness-helper.sh approve %s' "$wt"
		;;
	blocked:install-failed | blocked:install-timeout)
		printf 'the approved install (%s) did not finish; partial node_modules was removed and the next worktree admission retries it' "$command"
		;;
	blocked:install-mutated-tree)
		printf 'the approved install (%s) changed Git-visible files; node_modules was removed and tracked files restored' "$command"
		;;
	blocked:unsupported-package-manager)
		printf 'policy installs need exactly one npm, pnpm, yarn or bun lockfile that matches package.json packageManager'
		;;
	blocked:package-manager-missing)
		printf 'install the project package manager so the approved install (%s) can run' "$command"
		;;
	blocked:existing-node-modules | blocked:node-modules-not-ignored | blocked:dirty-worktree)
		printf 'the approved install only runs into an absent, Git-ignored node_modules of a tracked-clean worktree'
		;;
	*) return 1 ;;
	esac
	return 0
}

# Human/agent-facing lines. Silent for not-applicable.
_jsr_print_report() {
	local wt="$1"
	local hint=""
	local install_hint=""
	install_hint="provision worktree-local dependencies with the project lockfile ($(_jsr_install_command "$wt"); downloads need approval) without changing source, config or lockfile, or record a durable owner approval once (interactive only): worktree-js-readiness-helper.sh approve ${wt}"
	case "$JSR_STATE" in
	not-applicable:*) return 0 ;;
	"$JSR_STATE_READY")
		printf 'JS_TOOL_READINESS=ready (%s)\n' "$JSR_TOOLS"
		return 0
		;;
	preparing:*)
		hint="a concurrent dependency restore held the lock, so this worktree was not prepared and nothing retries it automatically yet; ${install_hint}"
		;;
	blocked:node-missing)
		hint="select the project Node runtime (.nvmrc/.node-version/engines) so the declared tools can start"
		;;
	blocked:probe-*)
		hint="the readiness probe itself could not finish; tool readiness is unknown, not ready"
		;;
	*) hint=$(_jsr_prepare_hint "$wt") || hint="$install_hint" ;;
	esac
	printf 'JS_TOOL_READINESS=%s (%s)\n' "$JSR_STATE" "$JSR_TOOLS"
	printf 'JS_TOOL_READINESS_HINT=declared verification tools cannot start yet and the pre-push gate will block until they do: %s. See %s.\n' "$hint" "$JSR_DOC_REF"
	return 0
}

cmd_probe() {
	local wt="" json=0 use_cache=1 arg=""
	for arg in "$@"; do
		case "$arg" in
		--json) json=1 ;;
		--no-cache) use_cache=0 ;;
		-*)
			printf 'worktree-js-readiness: unknown option: %s\n' "$arg" >&2
			return 1
			;;
		*) [[ -z "$wt" ]] && wt="$arg" ;;
		esac
	done
	wt=$(_jsr_resolve_worktree "$wt") || return 1
	_jsr_probe "$wt" "$use_cache"
	if [[ "$json" -eq 1 ]]; then
		jq -cn --argjson schema "$JSR_SCHEMA" --arg state "$JSR_STATE" --arg tools "$JSR_TOOLS" \
			--argjson cached "$([[ "$JSR_CACHED" -eq 1 ]] && printf 'true' || printf 'false')" \
			'{schema:$schema,state:$state,tools:($tools | split(" ") | map(select(length > 0))),cached:$cached}'
	else
		printf '%s\n' "$JSR_STATE"
	fi
	return 0
}

cmd_report() {
	local wt="${1:-}"
	wt=$(_jsr_resolve_worktree "$wt") || return 1
	_jsr_probe "$wt" 1
	_jsr_print_report "$wt"
	return 0
}

# Report once per session entry into a worktree; later calls in the same
# session print nothing and do no probing.
cmd_entry() {
	local wt="${1:-}"
	local session="${2:-}"
	local state_dir="" marker=""
	wt=$(_jsr_resolve_worktree "$wt") || return 1
	state_dir=$(_jsr_state_dir "$wt") || return 0
	marker="${state_dir}/js-readiness-entry"
	[[ -n "$session" ]] || session="unknown"
	if [[ -f "$marker" && "$(cat "$marker" 2>/dev/null)" == "$session" ]]; then
		return 0
	fi
	_jsr_probe "$wt" 1
	_jsr_write_atomic "$marker" "$session" || true
	_jsr_print_report "$wt"
	return 0
}

cmd_record_restore() {
	local wt="${1:-}"
	local outcome="${2:-}"
	local reason="${3:-}"
	local state_dir="" content=""
	case "$outcome" in
	contention | rejected | provisioned) ;;
	*)
		printf 'worktree-js-readiness: unknown restore outcome: %s\n' "$outcome" >&2
		return 1
		;;
	esac
	[[ "$reason" =~ ^[a-z0-9-]{1,64}$ ]] || reason=""
	wt=$(_jsr_resolve_worktree "$wt") || return 1
	state_dir=$(_jsr_state_dir "$wt") || return 0
	content=$(jq -cn --arg outcome "$outcome" --arg reason "$reason" --argjson at "$(date +%s)" \
		'{schema:1,outcome:$outcome,reason:$reason,at:$at}')
	_jsr_write_atomic "${state_dir}/js-restore.json" "$content"
	return $?
}

# Policy-gated install into a worktree's own node_modules (GH#34200).
# Without --lock-held it only evaluates: blocked outcomes are recorded for
# the readiness report, and an install that is due exits JSR_PREPARE_NEEDS_LOCK
# so the caller can take the restore lock and re-run with --lock-held.
cmd_prepare() {
	local wt="" lock_held=0 arg="" state_dir=""
	local canon=""
	local policy=""
	for arg in "$@"; do
		case "$arg" in
		--lock-held) lock_held=1 ;;
		-*)
			printf 'worktree-js-readiness: unknown option: %s\n' "$arg" >&2
			return 1
			;;
		*) [[ -z "$wt" ]] && wt="$arg" ;;
		esac
	done
	wt=$(_jsr_resolve_worktree "$wt") || return 1
	state_dir=$(_jsr_state_dir "$wt") || return 0
	# Each admission re-evaluates from scratch, so a re-approval is picked up.
	rm -f -- "${state_dir}/js-prepare.json"
	_jsr_probe "$wt" 0
	_jsr_install_eligible || return 0
	canon=$(_jsr_canonical_root "$wt") || return 0
	policy=$(_jsr_policy_get "$canon")
	_jsr_policy_evaluate "$wt" "$policy"
	case "$JSR_POLICY_STATUS" in
	none) return 0 ;;
	current) ;;
	unsupported-package-manager)
		_jsr_record_prepare "$state_dir" blocked unsupported-package-manager
		return 0
		;;
	*)
		_jsr_record_prepare "$state_dir" blocked policy-stale "$JSR_POLICY_STATUS"
		return 0
		;;
	esac
	_jsr_prepare_preflight "$wt" "$state_dir" || return 0
	[[ "$lock_held" -eq 1 ]] || return "$JSR_PREPARE_NEEDS_LOCK"
	_jsr_prepare_install "$wt" "$state_dir"
	return 0
}

_jsr_policy_target() {
	local dir="${1:-}"
	local canon=""
	dir=$(_jsr_resolve_worktree "$dir") || return 1
	canon=$(_jsr_canonical_root "$dir") || {
		printf 'worktree-js-readiness: not inside a Git repository: %s\n' "$dir" >&2
		return 1
	}
	printf '%s\n%s\n' "$dir" "$canon"
	return 0
}

cmd_approve() {
	local target="" dir="" node_major="" rc=0
	local canon=""
	local policy=""
	if _jsr_is_headless; then
		printf 'worktree-js-readiness: approve is an owner decision and is refused in headless/worker sessions\n' >&2
		return 1
	fi
	target=$(_jsr_policy_target "${1:-}") || return 1
	dir="${target%%$'\n'*}"
	canon="${target#*$'\n'}"
	if ! _jsr_lock_identity "$dir"; then
		printf 'worktree-js-readiness: approve needs exactly one npm, pnpm, yarn or bun lockfile matching package.json packageManager\n' >&2
		return 1
	fi
	node_major=$(_jsr_node_major)
	policy=$(jq -cn --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg sha "$JSR_LOCK_SHA" --arg pm "$JSR_PM" \
		--arg node "$node_major" --arg scope "$JSR_POLICY_SCOPE" \
		'{approved_at:$at,lockfile_sha256:$sha,package_manager:$pm,node_major:$node,scope:$scope}')
	_jsr_policy_write "$canon" "$policy" || rc=$?
	if [[ "$rc" -eq 2 ]]; then
		printf 'worktree-js-readiness: repository is not registered in repos.json; run aidevops init in it first\n' >&2
		return 1
	elif [[ "$rc" -ne 0 ]]; then
		printf 'worktree-js-readiness: could not update repos.json\n' >&2
		return 1
	fi
	printf 'JS_DEPENDENCY_POLICY=approved (%s, node %s, lockfile sha256 %s)\n' "$JSR_PM" "$node_major" "${JSR_LOCK_SHA:0:12}"
	printf 'Linked worktrees now get %s into their own node_modules while lockfile, package manager and Node major stay unchanged.\n' "$(_jsr_install_command "$dir")"
	return 0
}

cmd_revoke() {
	local target="" rc=0
	local canon=""
	if _jsr_is_headless; then
		printf 'worktree-js-readiness: revoke is an owner decision and is refused in headless/worker sessions\n' >&2
		return 1
	fi
	target=$(_jsr_policy_target "${1:-}") || return 1
	canon="${target#*$'\n'}"
	_jsr_policy_write "$canon" null || rc=$?
	if [[ "$rc" -eq 2 ]]; then
		printf 'worktree-js-readiness: repository is not registered in repos.json\n' >&2
		return 1
	elif [[ "$rc" -ne 0 ]]; then
		printf 'worktree-js-readiness: could not update repos.json\n' >&2
		return 1
	fi
	printf 'JS_DEPENDENCY_POLICY=revoked\n'
	return 0
}

cmd_status() {
	local target="" dir=""
	local canon=""
	local policy=""
	target=$(_jsr_policy_target "${1:-}") || return 1
	dir="${target%%$'\n'*}"
	canon="${target#*$'\n'}"
	policy=$(_jsr_policy_get "$canon")
	_jsr_policy_evaluate "$dir" "$policy"
	printf 'JS_DEPENDENCY_POLICY=%s\n' "$JSR_POLICY_STATUS"
	[[ -z "$policy" ]] || printf 'JS_DEPENDENCY_POLICY_RECORD=%s\n' "$policy"
	_jsr_lock_identity "$dir" || true
	jq -cn --arg pm "$JSR_PM" --arg sha "$JSR_LOCK_SHA" --arg node "$(_jsr_node_major)" \
		'{package_manager:$pm,lockfile_sha256:$sha,node_major:$node}' |
		sed 's/^/JS_DEPENDENCY_CURRENT=/'
	return 0
}

main() {
	local command="${1:-help}"
	[[ $# -gt 0 ]] && shift
	command -v jq >/dev/null 2>&1 || {
		printf 'worktree-js-readiness: jq is required\n' >&2
		return 1
	}
	case "$command" in
	probe) cmd_probe "$@" ;;
	report) cmd_report "$@" ;;
	entry) cmd_entry "$@" ;;
	record-restore) cmd_record_restore "$@" ;;
	prepare) cmd_prepare "$@" ;;
	approve) cmd_approve "$@" ;;
	revoke) cmd_revoke "$@" ;;
	status) cmd_status "$@" ;;
	help | -h | --help) _jsr_usage ;;
	*)
		_jsr_usage >&2
		return 1
		;;
	esac
	return $?
}

main "$@"
