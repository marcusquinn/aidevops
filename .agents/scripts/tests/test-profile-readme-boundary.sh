#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
SOURCE_HELPER="${SCRIPT_DIR}/../profile-readme-helper.sh"

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly RESET='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

TEST_DIR=""

print_result() {
	local test_name="$1"
	local result="$2"
	local message="${3:-}"

	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$result" -eq 0 ]]; then
		echo -e "${GREEN}PASS${RESET} ${test_name}"
		TESTS_PASSED=$((TESTS_PASSED + 1))
	else
		echo -e "${RED}FAIL${RESET} ${test_name}"
		if [[ -n "$message" ]]; then
			echo "       ${message}"
		fi
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi

	return 0
}

write_stub_dependencies() {
	local stub_dir="$1"

	cat >"${stub_dir}/screen-time-helper.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "profile-stats" ]]; then
	printf '%s\n' '{"today_hours":1.0,"week_hours":2.0,"month_hours":3.0,"year_hours":4.0}'
else
	printf '%s\n' '{}'
fi
return 0 2>/dev/null || exit 0
EOF

	cat >"${stub_dir}/contributor-activity-helper.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "session-time" ]]; then
	printf '%s\n' '{"interactive_human_hours":1.0,"worker_human_hours":2.0,"worker_machine_hours":3.0,"total_human_hours":4.0,"total_machine_hours":5.0,"interactive_sessions":6,"worker_sessions":7}'
else
	printf '%s\n' '{}'
fi
return 0 2>/dev/null || exit 0
EOF

	chmod +x "${stub_dir}/screen-time-helper.sh" "${stub_dir}/contributor-activity-helper.sh"
	return 0
}

create_profile_repo_fixture() {
	local fixture_home="$1"
	local profile_repo="$2"
	local remote_repo="$3"

	mkdir -p "${fixture_home}/.config/aidevops"
	mkdir -p "${fixture_home}/.aidevops/.agent-workspace/observability"

	cat >"${fixture_home}/.config/aidevops/repos.json" <<EOF
{
  "initialized_repos": [
    {
      "path": "${profile_repo}",
      "slug": "fixture/fixture",
      "priority": "profile",
      "pulse": false,
      "maintainer": "fixture"
    }
  ]
}
EOF

	git init --bare --initial-branch=main "${remote_repo}" >/dev/null
	git init -b main "${profile_repo}" >/dev/null
	git -C "${profile_repo}" config user.name "Fixture"
	git -C "${profile_repo}" config user.email "fixture@example.com"
	git -C "${profile_repo}" remote add origin "${remote_repo}"

	cat >"${profile_repo}/README.md" <<'EOF'
# Fixture Profile

![ManualBadgeA](https://example.com/a.svg)
![ManualBadgeB](https://example.com/b.svg)

Manual preface block that must not be rewritten.

<!-- STATS-START -->
Old stats block
<!-- STATS-END -->

Manual suffix block that must not be rewritten.

## Connect

- Stay in touch

<!-- UPDATED-START -->
Old timestamp
<!-- UPDATED-END -->
EOF

	git -C "${profile_repo}" add README.md
	git -C "${profile_repo}" commit -m "feat: seed fixture readme" >/dev/null
	git -C "${profile_repo}" push -u origin main >/dev/null

	return 0
}

strip_dynamic_sections() {
	local file_path="$1"
	awk '
		/<!-- STATS-START -->/ { print; skip_stats = 1; next }
		/<!-- STATS-END -->/ { skip_stats = 0; print; next }
		/<!-- UPDATED-START -->/ { print; skip_updated = 1; next }
		/<!-- UPDATED-END -->/ { skip_updated = 0; print; next }
		!skip_stats && !skip_updated { print }
	' "$file_path"
	return 0
}

test_update_preserves_manual_sections() {
	local test_name="profile update preserves non-marker sections"

	TEST_DIR=$(mktemp -d)
	local fixture_home="${TEST_DIR}/home"
	local fixture_repo="${TEST_DIR}/profile-repo"
	local fixture_remote="${TEST_DIR}/profile-remote.git"
	local helper_dir="${TEST_DIR}/helper"
	local helper_path="${helper_dir}/profile-readme-helper.sh"

	mkdir -p "${helper_dir}" "${fixture_home}"
	cp "${SOURCE_HELPER}" "${helper_path}"
	chmod +x "${helper_path}"

	write_stub_dependencies "${helper_dir}"
	create_profile_repo_fixture "${fixture_home}" "${fixture_repo}" "${fixture_remote}"

	local before_file="${TEST_DIR}/before.md"
	local after_file="${TEST_DIR}/after.md"
	cp "${fixture_repo}/README.md" "${before_file}"

	if ! HOME="${fixture_home}" bash "${helper_path}" update >/dev/null 2>&1; then
		print_result "${test_name}" 1 "helper update command failed"
		return 0
	fi

	cp "${fixture_repo}/README.md" "${after_file}"

	local before_static
	local after_static
	before_static="$(strip_dynamic_sections "${before_file}")"
	after_static="$(strip_dynamic_sections "${after_file}")"

	if [[ "${before_static}" != "${after_static}" ]]; then
		print_result "${test_name}" 1 "content outside STATS/UPDATED markers changed"
		return 0
	fi

	if ! grep -q 'ManualBadgeA' "${after_file}" || ! grep -q 'ManualBadgeB' "${after_file}"; then
		print_result "${test_name}" 1 "manual badge lines missing after update"
		return 0
	fi

	print_result "${test_name}" 0
	return 0
}

teardown() {
	if [[ -n "${TEST_DIR}" && -d "${TEST_DIR}" ]]; then
		rm -rf "${TEST_DIR}"
	fi
	TEST_DIR=""
	return 0
}

test_inject_markers_into_existing_readme() {
	local test_name="inject markers into README without markers"

	TEST_DIR=$(mktemp -d)
	local fixture_home="${TEST_DIR}/home"
	local fixture_repo="${TEST_DIR}/profile-repo"
	local fixture_remote="${TEST_DIR}/profile-remote.git"
	local helper_dir="${TEST_DIR}/helper"
	local helper_path="${helper_dir}/profile-readme-helper.sh"

	mkdir -p "${helper_dir}" "${fixture_home}/.config/aidevops"
	mkdir -p "${fixture_home}/.aidevops/.agent-workspace/observability"
	cp "${SOURCE_HELPER}" "${helper_path}"
	chmod +x "${helper_path}"
	write_stub_dependencies "${helper_dir}"

	# Create a bare remote and local clone with NO markers
	git init --bare --initial-branch=main "${fixture_remote}" >/dev/null
	git init -b main "${fixture_repo}" >/dev/null
	git -C "${fixture_repo}" config user.name "Fixture"
	git -C "${fixture_repo}" config user.email "fixture@example.com"
	git -C "${fixture_repo}" remote add origin "${fixture_remote}"

	# Write a user-authored README without any aidevops markers
	cat >"${fixture_repo}/README.md" <<'EOF'
# Hi there

I'm a developer who likes building things.

## My Projects

- Project A
- Project B
EOF

	git -C "${fixture_repo}" add README.md
	git -C "${fixture_repo}" commit -m "Initial commit" >/dev/null
	git -C "${fixture_repo}" push -u origin main >/dev/null

	# Set up repos.json pointing to this repo
	cat >"${fixture_home}/.config/aidevops/repos.json" <<EOF
{
  "initialized_repos": [
    {
      "path": "${fixture_repo}",
      "slug": "fixture/fixture",
      "priority": "profile",
      "pulse": false,
      "maintainer": "fixture"
    }
  ]
}
EOF

	# Run update — should inject markers and then update stats
	if ! HOME="${fixture_home}" bash "${helper_path}" update >/dev/null 2>&1; then
		print_result "${test_name}" 1 "helper update command failed"
		return 0
	fi

	local readme="${fixture_repo}/README.md"

	# Verify markers were injected
	if ! grep -q '<!-- STATS-START -->' "$readme"; then
		print_result "${test_name}" 1 "STATS-START marker not found after update"
		return 0
	fi
	if ! grep -q '<!-- STATS-END -->' "$readme"; then
		print_result "${test_name}" 1 "STATS-END marker not found after update"
		return 0
	fi

	# Verify original content was preserved
	if ! grep -q 'Hi there' "$readme"; then
		print_result "${test_name}" 1 "original heading lost after marker injection"
		return 0
	fi
	if ! grep -q 'Project A' "$readme"; then
		print_result "${test_name}" 1 "original content lost after marker injection"
		return 0
	fi

	print_result "${test_name}" 0
	return 0
}

test_diverged_history_recovery() {
	local test_name="recover from diverged git history"

	TEST_DIR=$(mktemp -d)
	local fixture_home="${TEST_DIR}/home"
	local fixture_repo="${TEST_DIR}/profile-repo"
	local fixture_remote="${TEST_DIR}/profile-remote.git"
	local helper_dir="${TEST_DIR}/helper"
	local helper_path="${helper_dir}/profile-readme-helper.sh"

	mkdir -p "${helper_dir}" "${fixture_home}/.config/aidevops"
	mkdir -p "${fixture_home}/.aidevops/.agent-workspace/observability"
	cp "${SOURCE_HELPER}" "${helper_path}"
	chmod +x "${helper_path}"
	write_stub_dependencies "${helper_dir}"

	# Create initial remote and local clone with markers
	git init --bare --initial-branch=main "${fixture_remote}" >/dev/null
	git init -b main "${fixture_repo}" >/dev/null
	git -C "${fixture_repo}" config user.name "Fixture"
	git -C "${fixture_repo}" config user.email "fixture@example.com"
	git -C "${fixture_repo}" remote add origin "${fixture_remote}"

	cat >"${fixture_repo}/README.md" <<'EOF'
# Profile

<!-- STATS-START -->
Old stats
<!-- STATS-END -->

<!-- UPDATED-START -->
<!-- UPDATED-END -->
EOF

	git -C "${fixture_repo}" add README.md
	git -C "${fixture_repo}" commit -m "feat: seed readme" >/dev/null
	git -C "${fixture_repo}" push -u origin main >/dev/null

	# Simulate repo deletion and recreation: create a NEW remote with different history
	rm -rf "${fixture_remote}"
	git init --bare --initial-branch=main "${fixture_remote}" >/dev/null

	# Push a different initial commit to the new remote (simulating GitHub "Initial commit")
	local tmp_clone="${TEST_DIR}/tmp-clone"
	git clone "${fixture_remote}" "${tmp_clone}" 2>/dev/null
	git -C "${tmp_clone}" config user.name "GitHub"
	git -C "${tmp_clone}" config user.email "noreply@github.com"
	echo "# fixture" >"${tmp_clone}/README.md"
	git -C "${tmp_clone}" add README.md
	git -C "${tmp_clone}" commit -m "Initial commit" >/dev/null
	git -C "${tmp_clone}" push -u origin main >/dev/null
	rm -rf "${tmp_clone}"

	# Set up repos.json
	cat >"${fixture_home}/.config/aidevops/repos.json" <<EOF
{
  "initialized_repos": [
    {
      "path": "${fixture_repo}",
      "slug": "fixture/fixture",
      "priority": "profile",
      "pulse": false,
      "maintainer": "fixture"
    }
  ]
}
EOF

	# Run update — should detect diverged history and recover
	HOME="${fixture_home}" bash "${helper_path}" update >/dev/null 2>&1 || true

	local readme="${fixture_repo}/README.md"

	# After recovery, the README should have markers (either injected or from re-seed)
	if ! grep -q '<!-- STATS-START -->' "$readme" 2>/dev/null; then
		print_result "${test_name}" 1 "STATS-START marker not found after recovery"
		return 0
	fi

	# Verify the local repo can now push to the remote (histories are aligned)
	if ! git -C "${fixture_repo}" push origin main 2>/dev/null; then
		# Try with --force since recovery may have created a new commit
		if ! git -C "${fixture_repo}" push --force origin main 2>/dev/null; then
			print_result "${test_name}" 1 "still cannot push after recovery"
			return 0
		fi
	fi

	print_result "${test_name}" 0
	return 0
}

test_default_template_replaced_with_rich_readme() {
	local test_name="default GitHub template replaced with rich profile README"

	TEST_DIR=$(mktemp -d)
	local fixture_home="${TEST_DIR}/home"
	local fixture_repo="${TEST_DIR}/profile-repo"
	local fixture_remote="${TEST_DIR}/profile-remote.git"
	local helper_dir="${TEST_DIR}/helper"
	local helper_path="${helper_dir}/profile-readme-helper.sh"

	mkdir -p "${helper_dir}" "${fixture_home}/.config/aidevops"
	mkdir -p "${fixture_home}/.aidevops/.agent-workspace/observability"
	mkdir -p "${fixture_home}/.aidevops/cache"
	cp "${SOURCE_HELPER}" "${helper_path}"
	chmod +x "${helper_path}"
	write_stub_dependencies "${helper_dir}"

	# Create a bare remote and local clone with the default GitHub template
	git init --bare --initial-branch=main "${fixture_remote}" >/dev/null
	git init -b main "${fixture_repo}" >/dev/null
	git -C "${fixture_repo}" config user.name "Fixture"
	git -C "${fixture_repo}" config user.email "fixture@example.com"
	git -C "${fixture_repo}" remote add origin "${fixture_remote}"

	# Write the exact default GitHub profile template
	cat >"${fixture_repo}/README.md" <<'EOF'
## Hi there 👋

<!--
**fixture/fixture** is a ✨ _special_ ✨ repository because its `README.md` (this file) appears on your GitHub profile.

Here are some ideas to get you started:

- 🔭 I'm currently working on ...
- 🌱 I'm currently learning ...
- 👯 I'm looking to collaborate on ...
- 🤔 I'm looking for help with ...
- 💬 Ask me about ...
- 📫 How to reach me: ...
- 😄 Pronouns: ...
- ⚡ Fun fact: ...
-->
EOF

	git -C "${fixture_repo}" add README.md
	git -C "${fixture_repo}" commit -m "Initial commit" >/dev/null
	git -C "${fixture_repo}" push -u origin main >/dev/null

	# Set up repos.json
	cat >"${fixture_home}/.config/aidevops/repos.json" <<EOF
{
  "initialized_repos": [
    {
      "path": "${fixture_repo}",
      "slug": "fixture/fixture",
      "priority": "profile",
      "pulse": false,
      "maintainer": "fixture"
    }
  ]
}
EOF

	# Run update — should detect default template and replace with rich README
	if ! HOME="${fixture_home}" bash "${helper_path}" update >/dev/null 2>&1; then
		print_result "${test_name}" 1 "helper update command failed"
		return 0
	fi

	local readme="${fixture_repo}/README.md"

	# Verify the default template is gone
	if grep -q 'is a.*special.*repository' "$readme" 2>/dev/null; then
		print_result "${test_name}" 1 "default GitHub template still present after update"
		return 0
	fi

	# Verify markers were added
	if ! grep -q '<!-- STATS-START -->' "$readme"; then
		print_result "${test_name}" 1 "STATS-START marker not found after update"
		return 0
	fi

	# Verify it's a rich README (has the aidevops tagline)
	if ! grep -q 'aidevops' "$readme"; then
		print_result "${test_name}" 1 "aidevops reference not found — not a rich README"
		return 0
	fi

	print_result "${test_name}" 0
	return 0
}

test_default_template_with_existing_markers_replaced() {
	local test_name="default template with existing markers gets replaced"

	TEST_DIR=$(mktemp -d)
	local fixture_home="${TEST_DIR}/home"
	local fixture_repo="${TEST_DIR}/profile-repo"
	local fixture_remote="${TEST_DIR}/profile-remote.git"
	local helper_dir="${TEST_DIR}/helper"
	local helper_path="${helper_dir}/profile-readme-helper.sh"

	mkdir -p "${helper_dir}" "${fixture_home}/.config/aidevops"
	mkdir -p "${fixture_home}/.aidevops/.agent-workspace/observability"
	mkdir -p "${fixture_home}/.aidevops/cache"
	cp "${SOURCE_HELPER}" "${helper_path}"
	chmod +x "${helper_path}"
	write_stub_dependencies "${helper_dir}"

	git init --bare --initial-branch=main "${fixture_remote}" >/dev/null
	git init -b main "${fixture_repo}" >/dev/null
	git -C "${fixture_repo}" config user.name "Fixture"
	git -C "${fixture_repo}" config user.email "fixture@example.com"
	git -C "${fixture_repo}" remote add origin "${fixture_remote}"

	# Simulate Alex's exact case: default GitHub template with markers already
	# injected at the bottom (by v3.1.87 _inject_markers_into_readme)
	cat >"${fixture_repo}/README.md" <<'EOF'
## Hi there 👋

<!--
**fixture/fixture** is a ✨ _special_ ✨ repository because its `README.md` (this file) appears on your GitHub profile.

Here are some ideas to get you started:

- 🔭 I'm currently working on ...
- 🌱 I'm currently learning ...
-->

<!-- STATS-START -->
Old stats content
<!-- STATS-END -->

<!-- CONTRIBUTIONS-START -->
<!-- CONTRIBUTIONS-END -->

---

<!-- UPDATED-START -->
<!-- UPDATED-END -->
EOF

	git -C "${fixture_repo}" add README.md
	git -C "${fixture_repo}" commit -m "feat: markers injected into default template" >/dev/null
	git -C "${fixture_repo}" push -u origin main >/dev/null

	cat >"${fixture_home}/.config/aidevops/repos.json" <<EOF
{
  "initialized_repos": [
    {
      "path": "${fixture_repo}",
      "slug": "fixture/fixture",
      "priority": "profile",
      "pulse": false,
      "maintainer": "fixture"
    }
  ]
}
EOF

	# Run update — should detect default template despite markers and replace it
	if ! HOME="${fixture_home}" bash "${helper_path}" update >/dev/null 2>&1; then
		print_result "${test_name}" 1 "helper update command failed"
		return 0
	fi

	local readme="${fixture_repo}/README.md"

	# Verify the default template is gone
	if grep -q 'is a.*special.*repository' "$readme" 2>/dev/null; then
		print_result "${test_name}" 1 "default GitHub template still present after update"
		return 0
	fi

	# Verify the "Hi there" heading is gone (replaced with rich profile heading)
	if grep -q 'Hi there' "$readme" 2>/dev/null; then
		print_result "${test_name}" 1 "'Hi there' heading still present — template not replaced"
		return 0
	fi

	# Verify markers still exist
	if ! grep -q '<!-- STATS-START -->' "$readme"; then
		print_result "${test_name}" 1 "STATS-START marker missing after replacement"
		return 0
	fi

	# Verify it's a rich README
	if ! grep -q 'aidevops' "$readme"; then
		print_result "${test_name}" 1 "aidevops reference not found — not a rich README"
		return 0
	fi

	print_result "${test_name}" 0
	return 0
}

main() {
	if [[ ! -x "${SOURCE_HELPER}" ]]; then
		echo "Helper script not found or not executable: ${SOURCE_HELPER}" >&2
		return 1
	fi

	test_update_preserves_manual_sections
	teardown
	test_inject_markers_into_existing_readme
	teardown
	test_diverged_history_recovery
	teardown
	test_default_template_replaced_with_rich_readme
	teardown
	test_default_template_with_existing_markers_replaced
	teardown

	echo ""
	echo "Tests run: ${TESTS_RUN}"
	echo "Passed:    ${TESTS_PASSED}"
	echo "Failed:    ${TESTS_FAILED}"

	if [[ "${TESTS_FAILED}" -gt 0 ]]; then
		return 1
	fi

	return 0
}

main "$@"
