#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
ADD_HELPER="${TEST_DIR}/../worktree-helper-add.sh"
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT

print_info() { return 0; }
print_success() { return 0; }
print_warning() {
	local message="$1"
	printf '%s\n' "$message" >&2
	return 0
}

SCRIPT_DIR="$(cd "$(dirname "$ADD_HELPER")" && pwd)" || exit 1
# shellcheck source=../worktree-helper-add.sh
source "$ADD_HELPER"

FAKE_BIN="${ROOT}/bin"
WORKTREE="${ROOT}/aidevops-worktree"
HOME_WORKTREE="${ROOT}/aidevops-home-bun-worktree"
ORDINARY="${ROOT}/ordinary-worktree"
FAKE_HOME="${ROOT}/home"
mkdir -p "$FAKE_BIN" "$WORKTREE/.agents/scripts" "$HOME_WORKTREE/.agents/scripts" \
	"$ORDINARY/.agents/scripts" "$FAKE_HOME/.bun/bin"
cat >"${FAKE_BIN}/bun" <<'BUN'
#!/usr/bin/env bash
mkdir -p node_modules/.bin
printf '#!/usr/bin/env bash\nexit 0\n' >node_modules/.bin/tsc
chmod +x node_modules/.bin/tsc
printf '%s\n' "$*" >"${BUN_ARGS_LOG}"
BUN
chmod +x "${FAKE_BIN}/bun"
export PATH="${FAKE_BIN}:${PATH}"
export BUN_ARGS_LOG="${ROOT}/bun-args.log"

printf '{ "name": "aidevops", "devDependencies": { "typescript": "^5.0.0" } }\n' >"${WORKTREE}/package.json"
printf '{}\n' >"${WORKTREE}/bun.lock"
printf '#!/usr/bin/env bash\n' >"${WORKTREE}/aidevops.sh"

_bootstrap_aidevops_worktree_js_deps "$WORKTREE"
[[ -x "${WORKTREE}/node_modules/.bin/tsc" ]] || {
	printf 'FAIL aidevops worktree bootstrap did not install tsc\n'
	exit 1
}
[[ "$(cat "$BUN_ARGS_LOG")" == "install --frozen-lockfile --ignore-scripts" ]] || {
	printf 'FAIL aidevops worktree bootstrap used unexpected bun arguments\n'
	exit 1
}
printf 'PASS aidevops worktree bootstraps locked dependencies without lifecycle scripts\n'

cp "${FAKE_BIN}/bun" "$FAKE_HOME/.bun/bin/bun"
printf '{ "name": "aidevops", "devDependencies": { "typescript": "^5.0.0" } }\n' >"${HOME_WORKTREE}/package.json"
printf '{}\n' >"${HOME_WORKTREE}/bun.lock"
printf '#!/usr/bin/env bash\n' >"${HOME_WORKTREE}/aidevops.sh"
rm -f "$BUN_ARGS_LOG"
HOME="$FAKE_HOME" PATH="/usr/bin:/bin" _bootstrap_aidevops_worktree_js_deps "$HOME_WORKTREE"
[[ -x "${HOME_WORKTREE}/node_modules/.bin/tsc" ]] || {
	printf 'FAIL fixed HOME Bun path did not bootstrap tsc when bun was absent from PATH\n'
	exit 1
}
[[ "$(cat "$BUN_ARGS_LOG")" == "install --frozen-lockfile --ignore-scripts" ]] || {
	printf 'FAIL fixed HOME Bun path used unexpected arguments\n'
	exit 1
}
printf 'PASS executable HOME Bun bootstraps dependencies when absent from PATH\n'

rm -f "$BUN_ARGS_LOG"
printf '{ "name": "ordinary-project", "devDependencies": { "typescript": "^5.0.0" } }\n' >"${ORDINARY}/package.json"
printf '{}\n' >"${ORDINARY}/bun.lock"
printf '#!/usr/bin/env bash\n' >"${ORDINARY}/aidevops.sh"
_bootstrap_aidevops_worktree_js_deps "$ORDINARY"
[[ ! -e "$BUN_ARGS_LOG" && ! -e "${ORDINARY}/node_modules/.bin/tsc" ]] || {
	printf 'FAIL ordinary project triggered aidevops dependency bootstrap\n'
	exit 1
}
printf 'PASS ordinary projects do not run implicit bun install\n'

# --- GH#34199: JavaScript verification-tool readiness ------------------------
# shellcheck source=../portable-stat.sh
source "${SCRIPT_DIR}/portable-stat.sh"
READINESS="${SCRIPT_DIR}/worktree-js-readiness-helper.sh"
export AIDEVOPS_WORKSPACE_DIR="${ROOT}/workspace"
mkdir -p "${AIDEVOPS_WORKSPACE_DIR}/tmp"

fail() {
	local message="$1"
	printf 'FAIL %s\n' "$message"
	exit 1
}

# A lint-declaring npm project whose flat config imports packages, builtins
# and a relative module. Staged (not committed) files count as tracked.
_js_fixture() {
	local dir="$1"
	mkdir -p "$dir"
	git -C "$dir" init -q
	printf '{ "name": "fixture", "scripts": { "lint": "eslint ." } }\n' >"${dir}/package.json"
	printf '{ "lockfileVersion": 3 }\n' >"${dir}/package-lock.json"
	cat >"${dir}/eslint.config.js" <<'CFG'
import js from "@eslint/js";
import plugin from "eslint-plugin-fixture";
import path from "path";
import { fileURLToPath } from "node:url";
import local from "./local-rules.js";
const globals = require("globals");
export default [js.configs.recommended, plugin, local, globals, path, fileURLToPath];
CFG
	git -C "$dir" add package.json package-lock.json eslint.config.js
	return 0
}

_js_install_fixture_deps() {
	local dir="$1"
	local pkg=""
	mkdir -p "${dir}/node_modules/.bin"
	for pkg in eslint @eslint/js eslint-plugin-fixture globals; do
		mkdir -p "${dir}/node_modules/${pkg}"
		printf '{ "name": "%s" }\n' "$pkg" >"${dir}/node_modules/${pkg}/package.json"
	done
	printf '#!/usr/bin/env bash\nexit 0\n' >"${dir}/node_modules/.bin/eslint"
	chmod +x "${dir}/node_modules/.bin/eslint"
	return 0
}

_expect_state() {
	local dir="$1"
	local expected="$2"
	local label="$3"
	local actual=""
	actual=$("$READINESS" probe "$dir" --no-cache) || fail "${label}: probe exited non-zero"
	[[ "$actual" == "$expected" ]] || fail "${label}: expected ${expected}, got ${actual}"
	printf 'PASS %s\n' "$label"
	return 0
}

NOT_JS="${ROOT}/not-js"
mkdir -p "$NOT_JS"
git -C "$NOT_JS" init -q
_expect_state "$NOT_JS" "not-applicable:no-package-json" "repositories without package.json are not applicable"

# A global eslint on PATH must never satisfy readiness.
printf '#!/usr/bin/env bash\nexit 0\n' >"${FAKE_BIN}/eslint"
chmod +x "${FAKE_BIN}/eslint"
JS_WT="${ROOT}/js-worktree"
_js_fixture "$JS_WT"
_expect_state "$JS_WT" "preparation-needed:node-modules-missing" "global eslint on PATH without a local install is not ready"
_js_install_fixture_deps "$JS_WT"
rm -f "${JS_WT}/node_modules/.bin/eslint"
_expect_state "$JS_WT" "preparation-needed:tool-missing-eslint" "global eslint on PATH with node_modules but no local binary is not ready"

if command -v node >/dev/null 2>&1; then
	_js_install_fixture_deps "$JS_WT"
	_expect_state "$JS_WT" "ready" "local eslint plus every resolvable flat-config import is ready"
	rm -rf "${JS_WT}/node_modules/eslint-plugin-fixture"
	_expect_state "$JS_WT" "preparation-needed:config-import-unresolved-eslint-plugin-fixture" \
		"local eslint binary with an unresolvable flat-config plugin is never ready"
	_js_install_fixture_deps "$JS_WT"

	first=$("$READINESS" probe "$JS_WT" --json)
	second=$("$READINESS" probe "$JS_WT" --json)
	[[ "$(jq -r '.state' <<<"$first")" == "ready" && "$(jq -r '.cached' <<<"$second")" == "true" ]] ||
		fail "unchanged inputs did not reuse the cached readiness result"
	printf '{ "lockfileVersion": 3, "changed": true }\n' >"${JS_WT}/package-lock.json"
	git -C "$JS_WT" add package-lock.json
	third=$("$READINESS" probe "$JS_WT" --json)
	[[ "$(jq -r '.cached' <<<"$third")" == "false" ]] || fail "a lockfile change did not invalidate the readiness cache"
	printf 'PASS readiness is cached on unchanged inputs and rechecked when the lockfile changes\n'
else
	printf 'SKIP node unavailable: flat-config import resolution cases\n'
fi

entry_one=$("$READINESS" entry "$JS_WT" session-one)
entry_repeat=$("$READINESS" entry "$JS_WT" session-one)
entry_two=$("$READINESS" entry "$JS_WT" session-two)
[[ "$entry_one" == JS_TOOL_READINESS=* && -z "$entry_repeat" && "$entry_two" == JS_TOOL_READINESS=* ]] ||
	fail "session entry reporting is not once per session"
printf 'PASS readiness is reported once per session entry\n'

# Restore lock contention: one bounded re-attempt, then preparing, not success.
CONTENDED_WT="${ROOT}/contended-worktree"
SOURCE_REPO="${ROOT}/source-repo"
mkdir -p "${SOURCE_REPO}/node_modules"
_js_fixture "$CONTENDED_WT"
LOCK_DIR=$(_restore_worktree_node_modules_lock_dir)
mkdir -p "$LOCK_DIR"
restore_output=$(WORKTREE_NODE_MODULES_RESTORE_LOCK_TIMEOUT_S=0 \
	_restore_worktree_node_modules "$CONTENDED_WT" "$SOURCE_REPO" 2>&1) ||
	fail "lock contention changed the restore exit status"
[[ "$restore_output" == *"another restore is active"* ]] || fail "lock contention was not reported"
_expect_state "$CONTENDED_WT" "preparing:lock-contention" "restore lock contention reports preparing:lock-contention"
admission_output=$(_print_worktree_js_readiness "$CONTENDED_WT" 2>&1)
[[ "$admission_output" == *"JS_TOOL_READINESS=preparing:lock-contention"* ]] ||
	fail "worktree admission did not print the contention readiness state"
printf 'PASS worktree admission prints the readiness line\n'
AIDEVOPS_JS_READINESS_CONTENTION_WINDOW_S=-1 _expect_state "$CONTENDED_WT" \
	"preparation-needed:restore-skipped-lock-contention" "stale contention is not reported as still preparing"
rmdir "$LOCK_DIR"

# Validator rejection: the fixed reason code becomes blocked:snapshot-<reason>.
REJECTED_WT="${ROOT}/rejected-worktree"
_js_fixture "$REJECTED_WT"
(
	_provision_worktree_node_modules() {
		printf 'dependency-provision-rejected reason=byte-budget-exceeded\n' >&2
		return 1
	}
	_restore_worktree_node_modules "$REJECTED_WT" "$SOURCE_REPO" 2>/dev/null ||
		fail "validator rejection changed the restore exit status"
) || exit 1
_expect_state "$REJECTED_WT" "blocked:snapshot-byte-budget-exceeded" "validator rejection reports blocked:<reason>"

for dir in "$JS_WT" "$CONTENDED_WT" "$REJECTED_WT"; do
	git -C "$dir" diff --quiet || fail "readiness probing changed tracked files in ${dir}"
	[[ ! -e "${dir}/.aidevops" && ! -e "${dir}/js-readiness.json" ]] ||
		fail "readiness state leaked into the worktree tree in ${dir}"
done
printf 'PASS readiness state stays in the git dir and tracked files are unchanged\n'
