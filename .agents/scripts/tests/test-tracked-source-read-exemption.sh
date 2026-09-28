#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# GH#32526: the read guards (OpenCode plugin + Claude Code hook) allow
# git-tracked code/doc files whose basename only carries loose secret hints,
# and keep untracked files, data/config formats, strong credential names,
# symlinks and hard links blocked.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PLUGIN_MODULE="$REPO_ROOT/.agents/plugins/opencode-aidevops/quality-hooks-secret-read.mjs"
HOOK_SCRIPT="$REPO_ROOT/.agents/hooks/secret_file_read_guard.py"

PASS=0
FAIL=0
WORK_DIR=""

cleanup() {
	[[ -n "$WORK_DIR" && -d "$WORK_DIR" ]] && rm -rf "$WORK_DIR"
	return 0
}
trap cleanup EXIT

pass() {
	local name="$1"
	PASS=$((PASS + 1))
	printf 'PASS %s\n' "$name"
	return 0
}

fail() {
	local name="$1"
	local detail="$2"
	FAIL=$((FAIL + 1))
	printf 'FAIL %s: %s\n' "$name" "$detail"
	return 0
}

plugin_reason() {
	local path="$1"
	node --input-type=module -e '
const mod = await import(process.argv[1]);
process.stdout.write(mod.secretReadBlockReason(process.argv[2]) + "|" + mod.secretPathBlockReason(process.argv[2]));
' "$PLUGIN_MODULE" "$path"
	return 0
}

hook_reason() {
	local path="$1"
	python3 - "$HOOK_SCRIPT" "$path" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("read_guard", sys.argv[1])
if spec is None or spec.loader is None:
    raise SystemExit("cannot load hook")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
sys.stdout.write(module.secret_read_block_reason(sys.argv[2]))
PY
	return 0
}

# expect <name> <path> <allowed|blocked>
expect() {
	local name="$1"
	local path="$2"
	local want="$3"
	local plugin="" hook="" read_reason="" strict_reason=""
	plugin=$(plugin_reason "$path")
	hook=$(hook_reason "$path")
	read_reason="${plugin%%|*}"
	strict_reason="${plugin#*|}"
	if [[ "$want" == "allowed" ]]; then
		if [[ -z "$read_reason" && -z "$hook" ]]; then pass "$name"; else fail "$name" "plugin='$read_reason' hook='$hook'"; fi
	else
		if [[ -n "$read_reason" && -n "$hook" ]]; then pass "$name"; else fail "$name" "plugin='$read_reason' hook='$hook'"; fi
	fi
	# The strict path check never consults git and keeps blocking loose names.
	if [[ "$want" == "allowed" && "${path##*/}" == *secret* && -z "$strict_reason" ]]; then
		fail "$name strict" "secretPathBlockReason allowed a loose secret basename"
	fi
	return 0
}

main() {
	WORK_DIR=$(mktemp -d)
	local repo="$WORK_DIR/repo"
	mkdir -p "$repo/api-secret-dir"
	git -C "$repo" init --quiet
	git -C "$repo" config user.email test@example.invalid
	git -C "$repo" config user.name test

	printf '#!/usr/bin/env bash\n' >"$repo/tracked-secret-helper.sh"
	printf 'export const x = 1;\n' >"$repo/secret-value-redaction.mjs"
	printf '# doc\n' >"$repo/password-rotation.md"
	printf 'key: value\n' >"$repo/secrets.yaml"
	printf 'plain\n' >"$repo/credential-secret-helper.sh"
	printf 'plain\n' >"$repo/api-secret-dir/readme.md"
	printf 'plain\n' >"$repo/hard-secret-link.sh"
	git -C "$repo" add tracked-secret-helper.sh secret-value-redaction.mjs password-rotation.md \
		secrets.yaml credential-secret-helper.sh api-secret-dir/readme.md hard-secret-link.sh
	git -C "$repo" commit --quiet -m fixture
	ln "$repo/hard-secret-link.sh" "$WORK_DIR/outside-hard-link"
	printf 'plain\n' >"$repo/untracked-secret.sh"
	printf 'plain\n' >"$WORK_DIR/outside-secret.sh"
	ln -s "$repo/tracked-secret-helper.sh" "$repo/link-secret.sh"
	git -C "$repo" add link-secret.sh
	git -C "$repo" commit --quiet -m link

	expect "tracked .sh with secret basename is readable" "$repo/tracked-secret-helper.sh" allowed
	expect "tracked .mjs with secret basename is readable" "$repo/secret-value-redaction.mjs" allowed
	expect "tracked .md with password basename is readable" "$repo/password-rotation.md" allowed
	expect "benign file under secret-named directory is readable" "$repo/api-secret-dir/readme.md" allowed
	expect "tracked data format stays blocked" "$repo/secrets.yaml" blocked
	expect "strong credential hint stays blocked" "$repo/credential-secret-helper.sh" blocked
	expect "untracked source stays blocked" "$repo/untracked-secret.sh" blocked
	expect "file outside any repository stays blocked" "$WORK_DIR/outside-secret.sh" blocked
	expect "tracked symlink stays blocked" "$repo/link-secret.sh" blocked
	expect "hard-linked tracked file stays blocked" "$repo/hard-secret-link.sh" blocked
	expect "untracked env file stays blocked" "$repo/.env" blocked

	local candidate=""
	for candidate in .agents/plugins/opencode-aidevops/secret-value-redaction.mjs .agents/scripts/example-credential-helper.py; do
		if git -C "$REPO_ROOT" check-ignore --no-index -q "$candidate"; then
			fail "$candidate is not gitignored" "ignored"
		else
			pass "$candidate is not gitignored"
		fi
	done
	if git -C "$REPO_ROOT" check-ignore --no-index -q .agents/configs/example-secret.json; then
		pass ".agents data files with secret names stay gitignored"
	else
		fail ".agents data files with secret names stay gitignored" "not ignored"
	fi

	printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
	[[ "$FAIL" -eq 0 ]] || return 1
	return 0
}

main "$@"
