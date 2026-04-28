#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Shared test-harness helpers (t2431)
# =============================================================================
# Centralises the "copy shared-constants.sh to a tmpdir and source it" pattern
# so every test is picked up when shared-constants.sh grows new sub-library
# dependencies.
#
# Background
# ----------
# `shared-constants.sh` is progressively split into sub-libraries to stay under
# the 2000-line soft cap (examples: `shared-gh-wrappers.sh` via PR #20037 /
# GH#20018, `shared-feature-toggles.sh` via PR #20066 / t2427). Each sub-library
# is pulled in via a bare `source "${_SC_SELF%/*}/<filename>.sh"` directive at
# file scope.
#
# Two tests in this repo (`test-gh-wrapper-auto-sig.sh` and
# `test-comment-wrapper-marker-dedup.sh`) copy `shared-constants.sh` into a
# temporary directory and source it from there so a stub `gh-signature-helper.sh`
# can be resolved via `BASH_SOURCE` sibling-lookup. Before t2431 these tests
# copied only `shared-constants.sh`, so sourcing the copy printed
# "shared-gh-wrappers.sh: No such file or directory" and continued with
# `set -euo pipefail` OFF (tests ran with the default shell options until that
# point), leaving every subsequent assertion silently skipped. The tests
# exited 0 with zero "PASS:" lines. This file removes that class of regression.
#
# Contract
# --------
# - `_test_discover_shared_deps <dir>` — echoes one filename per line for every
#   bare `source "${_SC_SELF%/*}/<file>.sh"` directive in
#   `<dir>/shared-constants.sh`. Conditional sources (guarded by `[[ -r ... ]]`
#   or equivalent) are intentionally ignored — they are benign when the file
#   is absent and do not break sourcing.
# - `_test_copy_shared_deps <src_dir> <dest_dir>` — copies `shared-constants.sh`
#   plus every sibling it discovers into `<dest_dir>`. Returns non-zero with a
#   clear "FAIL:" message if any dep is missing in the source tree. Callers
#   should `|| exit 1` after invoking it, or rely on `set -euo pipefail`.
#
# Invariants
# ----------
# - Any test that copies `shared-constants.sh` into a tmpdir MUST use this
#   helper. Bare `cp ... shared-constants.sh` calls outside this helper are
#   banned by `.agents/scripts/shared-constants-deps-check.sh` (t2431 Layer 3)
#   and enforced by `.github/workflows/test-harness-deps.yml`.
# - The discovery function is the single source of truth for the dependency
#   graph; it never falls back to a hard-coded list. If parsing finds zero
#   siblings it means shared-constants.sh has no sub-library sources (a real
#   state), not that the parser is broken — the contract is stable because
#   the source directive is always a simple one-line pattern at file scope.
#
# Usage example
# -------------
#
#     # From a test at .agents/scripts/tests/test-foo.sh:
#     SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
#     PARENT_DIR="${SCRIPT_DIR}/.."
#     # shellcheck source=./lib/test-helpers.sh
#     source "${SCRIPT_DIR}/lib/test-helpers.sh"
#
#     TMPDIR_TEST=$(mktemp -d)
#     trap 'rm -rf "$TMPDIR_TEST"' EXIT
#
#     _test_copy_shared_deps "$PARENT_DIR" "$TMPDIR_TEST" || exit 1
#     unset _SHARED_CONSTANTS_LOADED
#     export AIDEVOPS_BASH_REEXECED=1
#     # shellcheck source=/dev/null
#     source "${TMPDIR_TEST}/shared-constants.sh"
# =============================================================================

# Include guard so the helper can be sourced multiple times without error.
if [[ -n "${_TEST_HELPERS_LOADED:-}" ]]; then
	return 0 2>/dev/null || exit 0
fi
_TEST_HELPERS_LOADED=1

# -----------------------------------------------------------------------------
# _test_discover_shared_deps <dir>
# -----------------------------------------------------------------------------
# Parses <dir>/shared-constants.sh and echoes every sibling file it sources
# via the `source "${_SC_SELF%/*}/<filename>.sh"` pattern, one per line.
#
# Matches only UNCONDITIONAL, file-scope directives. Conditional sources
# (e.g., `if [[ -r "$path" ]]; then source "$path"; fi` blocks inside
# sub-libraries) are ignored: they tolerate missing siblings already.
#
# Arguments:
#   $1 — absolute or relative path to a directory containing shared-constants.sh
#
# Outputs:
#   One filename (basename only, e.g. `shared-gh-wrappers.sh`) per line.
#   Empty output means `shared-constants.sh` has no sub-library sources.
#
# Returns:
#   0 on success (including zero-match), 1 if the shared-constants.sh file
#   is missing.
# -----------------------------------------------------------------------------
_test_discover_shared_deps() {
	local src_dir="$1"
	local shared_constants="${src_dir}/shared-constants.sh"

	if [[ ! -f "$shared_constants" ]]; then
		printf 'FAIL: shared-constants.sh not found at %s\n' "$shared_constants" >&2
		return 1
	fi

	# Match lines that begin with `source "${_SC_SELF%/*}/<filename>.sh"`
	# (no leading whitespace — file-scope only). Extract the basename.
	awk '
		/^source[[:space:]]/ && /_SC_SELF/ {
			line = $0
			# Strip everything up to and including the last slash
			sub(/.*\//, "", line)
			# Strip trailing quote and anything after it
			sub(/".*/, "", line)
			if (line != "") print line
		}
	' "$shared_constants"
	return 0
}

# -----------------------------------------------------------------------------
# _test_copy_shared_deps <src_dir> <dest_dir>
# -----------------------------------------------------------------------------
# Copies shared-constants.sh and every sibling it sources from <src_dir> into
# <dest_dir>. The destination must already exist.
#
# Errors out (returns 1) if shared-constants.sh cites a sibling that does not
# exist in <src_dir> — that state is a framework bug and should halt the test
# rather than let it run with a silently broken orchestrator.
#
# Arguments:
#   $1 — source directory (typically `.agents/scripts/`)
#   $2 — destination directory (typically a `mktemp -d` tmpdir)
#
# Returns:
#   0 on success, 1 on failure (with FAIL: message on stderr).
# -----------------------------------------------------------------------------
_test_copy_shared_deps() {
	local src_dir="$1"
	local dest_dir="$2"

	if [[ ! -d "$src_dir" ]]; then
		printf 'FAIL: source directory not found: %s\n' "$src_dir" >&2
		return 1
	fi
	if [[ ! -d "$dest_dir" ]]; then
		printf 'FAIL: destination directory not found: %s\n' "$dest_dir" >&2
		return 1
	fi

	# Copy the orchestrator first.
	if ! cp "${src_dir}/shared-constants.sh" "${dest_dir}/shared-constants.sh"; then
		printf 'FAIL: could not copy shared-constants.sh from %s\n' "$src_dir" >&2
		return 1
	fi

	# Discover siblings from the on-disk orchestrator and copy each one.
	local sibling
	local deps
	deps=$(_test_discover_shared_deps "$src_dir") || return 1

	# Iterate over discovered deps. Empty `deps` is fine — means no siblings.
	while IFS= read -r sibling; do
		[[ -z "$sibling" ]] && continue
		if [[ ! -f "${src_dir}/${sibling}" ]]; then
			printf 'FAIL: shared-constants.sh sources %s but file missing in %s\n' \
				"$sibling" "$src_dir" >&2
			return 1
		fi
		if ! cp "${src_dir}/${sibling}" "${dest_dir}/${sibling}"; then
			printf 'FAIL: could not copy %s to %s\n' "$sibling" "$dest_dir" >&2
			return 1
		fi
	done <<<"$deps"

	# Second pass: discover sub-library deps from each first-level dep.
	# Sub-libraries (e.g. shared-gh-wrappers-session.sh) are sourced from
	# their parent via `source "$_SHARED_GH_WRAPPERS_DIR/<filename>.sh"` or
	# similar runtime-resolved patterns. Match unconditional source lines
	# that reference a shared-gh-wrappers-*.sh basename.
	local sub_deps=""
	while IFS= read -r sibling; do
		[[ -z "$sibling" ]] && continue
		local _sub_dep_list
		_sub_dep_list=$(awk '
			/source.*shared-gh-wrappers-[a-z]/ {
				line = $0
				sub(/.*\//, "", line)
				sub(/".*/, "", line)
				if (line != "" && line ~ /^shared-gh-wrappers-/) print line
			}
		' "${dest_dir}/${sibling}" 2>/dev/null || true)
		[[ -n "$_sub_dep_list" ]] && sub_deps="${sub_deps}${sub_deps:+
}${_sub_dep_list}"
	done <<<"$deps"

	# Copy sub-library deps (skip already-copied files).
	while IFS= read -r sibling; do
		[[ -z "$sibling" ]] && continue
		[[ -f "${dest_dir}/${sibling}" ]] && continue
		if [[ -f "${src_dir}/${sibling}" ]]; then
			if ! cp "${src_dir}/${sibling}" "${dest_dir}/${sibling}"; then
				printf 'FAIL: could not copy sub-dep %s to %s\n' "$sibling" "$dest_dir" >&2
				return 1
			fi
		fi
	done <<<"$sub_deps"

	return 0
}

# -----------------------------------------------------------------------------
# _test_source_shared_deps <dest_dir>
# -----------------------------------------------------------------------------
# Convenience: source shared-constants.sh from <dest_dir> with error-checking.
# Caller is responsible for having already called `_test_copy_shared_deps`.
#
# Clears the include guard so a re-source picks up a fresh state (tests often
# source the helper once at the top and then source the orchestrator from a
# tmpdir later). Exports AIDEVOPS_BASH_REEXECED=1 to skip the re-exec guard
# when running under bash 3.2 on macOS.
#
# Arguments:
#   $1 — destination directory (the same <dest_dir> used with _test_copy_shared_deps)
#
# Returns:
#   0 on success, 1 on failure.
# -----------------------------------------------------------------------------
_test_source_shared_deps() {
	local dest_dir="$1"
	if [[ ! -f "${dest_dir}/shared-constants.sh" ]]; then
		printf 'FAIL: %s/shared-constants.sh missing — did you call _test_copy_shared_deps?\n' \
			"$dest_dir" >&2
		return 1
	fi

	unset _SHARED_CONSTANTS_LOADED
	export AIDEVOPS_BASH_REEXECED=1
	# shellcheck source=/dev/null
	if ! source "${dest_dir}/shared-constants.sh"; then
		printf 'FAIL: sourcing %s/shared-constants.sh failed\n' "$dest_dir" >&2
		return 1
	fi
	return 0
}
