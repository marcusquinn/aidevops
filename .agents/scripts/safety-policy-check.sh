#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit

pattern_exists() {
	local pattern="$1"
	local file_path="$2"

	if command -v rg >/dev/null 2>&1; then
		rg -qi --fixed-strings "$pattern" "$file_path"
		return $?
	fi

	grep -qiF "$pattern" "$file_path"
	return $?
}

# Check if a pattern exists in a file on the merge base (origin/main).
# Returns 0 if the pattern exists on the base, 1 if not (or if git is unavailable).
# Used to distinguish regressions (marker removed by PR) from stale branches
# (marker never existed when the branch was created). GH#6902.
pattern_exists_on_base() {
	local pattern="$1"
	local file_path="$2"

	# Resolve the repo-relative path for git show
	local repo_root
	repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
	local rel_path
	rel_path=$(realpath --relative-to="$repo_root" "$file_path" 2>/dev/null) || return 1

	local merge_base
	merge_base=$(git merge-base HEAD origin/main 2>/dev/null) || return 1

	local base_content
	base_content=$(git show "${merge_base}:${rel_path}" 2>/dev/null) || return 1

	printf '%s\n' "$base_content" | grep -qiF "$pattern"
	return $?
}

# Require a pattern in a file. If missing, check whether it existed on the
# merge base to distinguish regressions from stale-branch false positives.
# Regressions (pattern was on base, removed by PR) hard-fail.
# Stale branches (pattern never on base) emit a warning and pass. GH#6902.
require_pattern() {
	local pattern="$1"
	local file_path="$2"
	local fail_message="$3"

	if pattern_exists "$pattern" "$file_path"; then
		return 0
	fi

	# Pattern missing — is this a regression or a stale branch?
	if pattern_exists_on_base "$pattern" "$file_path"; then
		# Pattern existed on base but was removed by this branch — regression
		echo "FAIL: ${fail_message}" >&2
		return 1
	fi

	# Pattern never existed on the merge base — stale branch, not a regression
	echo "WARN: ${fail_message} (not a regression — marker absent on merge base)" >&2
	return 0
}

check_generator_rules() {
	local generator_file="${SCRIPT_DIR}/generate-claude-agents.sh"
	if [[ ! -f "$generator_file" ]]; then
		echo "FAIL: generator file missing: $generator_file" >&2
		return 1
	fi

	python3 - "$generator_file" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8", errors="replace")

def extract_block(name: str) -> str:
    m = re.search(rf"{name}\s*=\s*\[(.*?)\]\n", text, re.S)
    return m.group(1) if m else ""

allow_block = extract_block("allow_rules")
deny_block = extract_block("deny_rules")

forbidden_in_allow = [
    "Bash(gopass show *)",
    "Bash(pass show *)",
    "Bash(op read *)",
    "Bash(cat ~/.config/aidevops/credentials.sh)",
    "Read(~/.config/aidevops/credentials.sh)",
]

required_in_deny = [
    "Bash(gopass show *)",
    "Bash(pass show *)",
    "Bash(op read *)",
    "Bash(cat ~/.config/aidevops/credentials.sh)",
    "Read(~/.config/aidevops/credentials.sh)",
]

errors = []
for rule in forbidden_in_allow:
    if rule in allow_block:
        errors.append(f"forbidden rule in allow_rules: {rule}")

for rule in required_in_deny:
    if rule not in deny_block:
        errors.append(f"required deny rule missing: {rule}")

if errors:
    for err in errors:
        print(f"FAIL: {err}", file=sys.stderr)
    sys.exit(1)

print("PASS: generator deny/allow secret rules")
PY

	return $?
}

check_policy_markers() {
	local build_prompt="${SCRIPT_DIR}/../prompts/build.txt"
	local sandbox_helper="${SCRIPT_DIR}/sandbox-exec-helper.sh"
	local secret_handling_ref="${SCRIPT_DIR}/../reference/secret-handling.md"

	# Explicit readability checks before marker checks — avoids misleading
	# "marker missing" errors when the file itself is absent or unreadable.
	if [[ ! -r "$build_prompt" ]]; then
		echo "FAIL: build prompt not readable: $build_prompt" >&2
		return 1
	fi

	if [[ ! -r "$sandbox_helper" ]]; then
		echo "FAIL: sandbox helper not readable: $sandbox_helper" >&2
		return 1
	fi

	# build.txt must reference transcript exposure policy (inline or via pointer)
	if ! require_pattern "transcript exposure" "$build_prompt" \
		"transcript exposure policy missing from build prompt"; then
		return 1
	fi

	# build.txt must contain the transcript-visible rule
	if ! require_pattern "transcript-visible" "$build_prompt" \
		"transcript-visible rule missing from build prompt"; then
		return 1
	fi

	# Detailed secret handling rules must exist (either inline in build.txt
	# or in the extracted reference file)
	if [[ -f "$secret_handling_ref" ]]; then
		if [[ ! -r "$secret_handling_ref" ]]; then
			echo "FAIL: secret-handling reference not readable: $secret_handling_ref" >&2
			return 1
		fi
		if ! require_pattern "Never paste secret values into AI chat" "$secret_handling_ref" \
			"mandatory warning guidance missing from secret-handling reference"; then
			return 1
		fi
		if ! require_pattern "Session Transcript Exposure" "$secret_handling_ref" \
			"transcript exposure section missing from secret-handling reference"; then
			return 1
		fi
	else
		# Fallback: if reference file doesn't exist, check build.txt directly
		if ! require_pattern "Never paste secret values into AI chat" "$build_prompt" \
			"mandatory warning guidance missing from build prompt"; then
			return 1
		fi
	fi

	if ! require_pattern "_sandbox_emit_redacted_output" "$sandbox_helper" \
		"sandbox output redaction function missing"; then
		return 1
	fi

	if ! require_pattern "_sandbox_is_secret_tainted_command" "$sandbox_helper" \
		"sandbox taint handling function missing"; then
		return 1
	fi

	echo "PASS: policy markers present"
	return 0
}

main() {
	check_generator_rules
	check_policy_markers
	return 0
}

main "$@"
