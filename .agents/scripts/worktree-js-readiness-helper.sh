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
# It never runs a linter, never installs or copies dependencies, never reads
# the canonical checkout, and never accepts a PATH/global binary as ready.
#
# Usage:
#   worktree-js-readiness-helper.sh probe <worktree> [--json] [--no-cache]
#   worktree-js-readiness-helper.sh report <worktree>
#   worktree-js-readiness-helper.sh entry <worktree> <session-key>
#   worktree-js-readiness-helper.sh record-restore <worktree> <outcome> [reason]
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
# (last restore outcome), aidevops/js-readiness-entry (last reported session).
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"
# shellcheck source=repo-verify-config-lib.sh
source "${SCRIPT_DIR}/repo-verify-config-lib.sh"

: "${AIDEVOPS_JS_READINESS_PROBE_TIMEOUT_S:=10}"
: "${AIDEVOPS_JS_READINESS_CONTENTION_WINDOW_S:=120}"
readonly JSR_SCHEMA=1
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

_jsr_usage() {
	cat <<'USAGE'
Usage:
  worktree-js-readiness-helper.sh probe <worktree> [--json] [--no-cache]
  worktree-js-readiness-helper.sh report <worktree>
  worktree-js-readiness-helper.sh entry <worktree> <session-key>
  worktree-js-readiness-helper.sh record-restore <worktree> contention|rejected|provisioned [reason]
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
	if [[ -f "${state_dir}/js-restore.json" ]]; then
		manifest+="restore $(_jsr_sha256 <"${state_dir}/js-restore.json")"$'\n'
	fi
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
			sort -u | head -n "$JSR_MAX_SPECIFIERS"
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
		return 0
	fi
	for tool in $JSR_TOOLS; do
		tool_state=$(_jsr_tool_state "$wt" "$tool")
		if [[ -n "$tool_state" ]]; then
			JSR_STATE="$tool_state"
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

_jsr_install_command() {
	local wt="$1"
	if [[ -f "${wt}/bun.lock" || -f "${wt}/bun.lockb" ]]; then
		printf 'bun install --frozen-lockfile'
	elif [[ -f "${wt}/pnpm-lock.yaml" ]]; then
		printf 'pnpm install --frozen-lockfile'
	elif [[ -f "${wt}/yarn.lock" ]]; then
		printf 'yarn install --frozen-lockfile'
	elif [[ -f "${wt}/package-lock.json" || -f "${wt}/npm-shrinkwrap.json" ]]; then
		printf 'npm ci'
	else
		printf 'npm install'
	fi
	return 0
}

# Human/agent-facing lines. Silent for not-applicable.
_jsr_print_report() {
	local wt="$1"
	local hint=""
	local install_hint=""
	install_hint="provision worktree-local dependencies with the project lockfile ($(_jsr_install_command "$wt"); downloads need approval) without changing source, config or lockfile"
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
	*) hint="$install_hint" ;;
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
	help | -h | --help) _jsr_usage ;;
	*)
		_jsr_usage >&2
		return 1
		;;
	esac
	return $?
}

main "$@"
