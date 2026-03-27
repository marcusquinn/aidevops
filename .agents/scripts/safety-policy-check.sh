#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit

pattern_exists() {
	local pattern="$1"
	local file_path="$2"

	if command -v rg >/dev/null 2>&1; then
		rg -q --fixed-strings "$pattern" "$file_path"
		return $?
	fi

	grep -qF "$pattern" "$file_path"
	return $?
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

	# build.txt must reference transcript exposure policy (inline or via pointer)
	if ! pattern_exists "transcript exposure" "$build_prompt"; then
		echo "FAIL: transcript exposure policy missing from build prompt" >&2
		return 1
	fi

	# build.txt must contain the transcript-visible rule
	if ! pattern_exists "transcript-visible" "$build_prompt"; then
		echo "FAIL: transcript-visible rule missing from build prompt" >&2
		return 1
	fi

	# Detailed secret handling rules must exist (either inline in build.txt
	# or in the extracted reference file)
	if [[ -f "$secret_handling_ref" ]]; then
		if ! pattern_exists "Never paste secret values into AI chat" "$secret_handling_ref"; then
			echo "FAIL: mandatory warning guidance missing from secret-handling reference" >&2
			return 1
		fi
		if ! pattern_exists "Session Transcript Exposure" "$secret_handling_ref"; then
			echo "FAIL: transcript exposure section missing from secret-handling reference" >&2
			return 1
		fi
	else
		# Fallback: if reference file doesn't exist, check build.txt directly
		if ! pattern_exists "Never paste secret values into AI chat" "$build_prompt"; then
			echo "FAIL: mandatory warning guidance missing from build prompt" >&2
			return 1
		fi
	fi

	if ! pattern_exists "_sandbox_emit_redacted_output" "$sandbox_helper"; then
		echo "FAIL: sandbox output redaction function missing" >&2
		return 1
	fi

	if ! pattern_exists "_sandbox_is_secret_tainted_command" "$sandbox_helper"; then
		echo "FAIL: sandbox taint handling function missing" >&2
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
