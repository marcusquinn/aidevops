#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)" || exit 1

TESTS_RUN=0
TESTS_FAILED=0
TEST_TMP_DIR=""
OLD_HOME="${HOME:-}"

print_info() {
	return 0
}

print_success() {
	return 0
}

print_warning() {
	return 0
}

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$passed" -eq 0 ]]; then
		printf 'PASS %s\n' "$test_name"
		return 0
	fi

	printf 'FAIL %s\n' "$test_name"
	if [[ -n "$message" ]]; then
		printf '  %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

cleanup() {
	if [[ -n "$OLD_HOME" ]]; then
		HOME="$OLD_HOME"
		export HOME
	else
		unset HOME
	fi
	if [[ -n "$TEST_TMP_DIR" && -d "$TEST_TMP_DIR" ]]; then
		rm -rf "$TEST_TMP_DIR"
	fi
	return 0
}

setup_fixture() {
	TEST_TMP_DIR="$(mktemp -d)"
	HOME="$TEST_TMP_DIR/home"
	export HOME

	mkdir -p "$HOME/.aidevops/agents/configs" \
		"$HOME/.aidevops/agents/tools/video" \
		"$HOME/.config/opencode/skills/video-use" \
		"$HOME/.config/opencode/skills/custom-only"

	cat >"$HOME/.aidevops/agents/tools/video/video-use-skill.md" <<'EOF_SKILL'
---
name: video-use
description: Video editing skill
---

# Video Use
EOF_SKILL

	cat >"$HOME/.aidevops/agents/configs/skill-sources.json" <<'EOF_JSON'
{
  "skills": [
    {
      "name": "video-use",
      "local_path": ".agents/tools/video/video-use-skill.md"
    }
  ]
}
EOF_JSON

	ln -sf "$HOME/.aidevops/agents/tools/video/video-use-skill.md" \
		"$HOME/.config/opencode/skills/video-use/SKILL.md"
	printf 'user skill\n' >"$HOME/.config/opencode/skills/custom-only/SKILL.md"
	return 0
}

test_imported_skills_use_shared_claude_path_for_opencode() {
	local claude_skill="$HOME/.claude/skills/video-use/SKILL.md"
	local opencode_skill="$HOME/.config/opencode/skills/video-use/SKILL.md"
	local custom_opencode_skill="$HOME/.config/opencode/skills/custom-only/SKILL.md"

	create_skill_symlinks >/dev/null

	if [[ ! -L "$claude_skill" ]]; then
		print_result "imported skill is available through shared Claude skill path" 1 "missing $claude_skill"
		return 0
	fi
	if [[ -e "$opencode_skill" ]]; then
		print_result "duplicate OpenCode imported skill symlink is removed" 1 "unexpected $opencode_skill"
		return 0
	fi
	if [[ ! -f "$custom_opencode_skill" ]]; then
		print_result "non-aidevops OpenCode skills are preserved" 1 "missing $custom_opencode_skill"
		return 0
	fi

	print_result "OpenCode sees one authoritative copy per imported skill" 0
	return 0
}

main() {
	trap cleanup EXIT
	setup_fixture
	# shellcheck source=/dev/null
	source "$REPO_ROOT/.agents/scripts/setup/modules/plugins.sh"

	test_imported_skills_use_shared_claude_path_for_opencode

	printf '\nRan %s tests, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		exit 1
	fi
	return 0
}

main "$@"
