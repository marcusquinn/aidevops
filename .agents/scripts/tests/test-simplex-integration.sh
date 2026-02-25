#!/usr/bin/env bash
# shellcheck disable=SC2034

# =============================================================================
# Integration Test Script for SimpleX Chat Components (t1327 series)
# =============================================================================
# Tests the SimpleX integration without requiring SimpleX CLI or a running bot.
# Focuses on: file existence, argument parsing, help output, subagent index,
# AGENTS.md references, markdown structure, and bot framework scaffold.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
readonly SCRIPT_DIR
AGENTS_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)" || exit
readonly AGENTS_DIR
HELPER="${SCRIPT_DIR}/../simplex-helper.sh"
readonly HELPER

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly RESET='\033[0m'

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

#######################################
# Print test result
# Arguments:
#   $1 - Test name
#   $2 - Result (0=pass, 1=fail, 2=skip)
#   $3 - Optional message
# Returns:
#   0 always
#######################################
print_result() {
	local test_name="$1"
	local result="$2"
	local message="${3:-}"

	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$result" -eq 0 ]]; then
		echo -e "${GREEN}PASS${RESET} $test_name"
		TESTS_PASSED=$((TESTS_PASSED + 1))
	elif [[ "$result" -eq 2 ]]; then
		echo -e "${YELLOW}SKIP${RESET} $test_name"
		TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
	else
		echo -e "${RED}FAIL${RESET} $test_name"
		if [[ -n "$message" ]]; then
			echo "       $message"
		fi
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

# =============================================================================
# Section 1: File Existence Tests
# =============================================================================

section_file_existence() {
	echo ""
	echo -e "${CYAN}=== File Existence Tests ===${RESET}"

	# simplex.md subagent doc
	if [[ -f "${AGENTS_DIR}/services/communications/simplex.md" ]]; then
		print_result "simplex.md exists" 0
	else
		print_result "simplex.md exists" 1 "Missing: .agents/services/communications/simplex.md"
	fi

	# opsec.md subagent doc
	if [[ -f "${AGENTS_DIR}/tools/security/opsec.md" ]]; then
		print_result "opsec.md exists" 0
	else
		print_result "opsec.md exists" 1 "Missing: .agents/tools/security/opsec.md"
	fi

	# simplex-helper.sh
	if [[ -f "${AGENTS_DIR}/scripts/simplex-helper.sh" ]]; then
		print_result "simplex-helper.sh exists" 0
	else
		print_result "simplex-helper.sh exists" 1 "Missing: .agents/scripts/simplex-helper.sh"
	fi

	# Bot framework scaffold
	if [[ -f "${AGENTS_DIR}/scripts/simplex-bot/package.json" ]]; then
		print_result "simplex-bot/package.json exists" 0
	else
		print_result "simplex-bot/package.json exists" 1 "Missing: .agents/scripts/simplex-bot/package.json"
	fi

	if [[ -f "${AGENTS_DIR}/scripts/simplex-bot/src/index.ts" ]]; then
		print_result "simplex-bot/src/index.ts exists" 0
	else
		print_result "simplex-bot/src/index.ts exists" 1 "Missing: .agents/scripts/simplex-bot/src/index.ts"
	fi

	if [[ -f "${AGENTS_DIR}/scripts/simplex-bot/src/types.ts" ]]; then
		print_result "simplex-bot/src/types.ts exists" 0
	else
		print_result "simplex-bot/src/types.ts exists" 1 "Missing: .agents/scripts/simplex-bot/src/types.ts"
	fi

	if [[ -f "${AGENTS_DIR}/scripts/simplex-bot/src/commands.ts" ]]; then
		print_result "simplex-bot/src/commands.ts exists" 0
	else
		print_result "simplex-bot/src/commands.ts exists" 1 "Missing: .agents/scripts/simplex-bot/src/commands.ts"
	fi

	# Matterbridge configs
	if [[ -f "${AGENTS_DIR}/configs/matterbridge-simplex-compose.yml" ]]; then
		print_result "matterbridge-simplex-compose.yml exists" 0
	else
		print_result "matterbridge-simplex-compose.yml exists" 1 "Missing: .agents/configs/matterbridge-simplex-compose.yml"
	fi

	if [[ -f "${AGENTS_DIR}/configs/matterbridge-simplex.toml.example" ]]; then
		print_result "matterbridge-simplex.toml.example exists" 0
	else
		print_result "matterbridge-simplex.toml.example exists" 1 "Missing: .agents/configs/matterbridge-simplex.toml.example"
	fi

	return 0
}

# =============================================================================
# Section 2: simplex-helper.sh Tests
# =============================================================================

section_helper_script() {
	echo ""
	echo -e "${CYAN}=== simplex-helper.sh Tests ===${RESET}"

	if [[ ! -f "$HELPER" ]]; then
		print_result "helper script available" 1 "simplex-helper.sh not found"
		return 0
	fi

	# Executable check
	if [[ -x "$HELPER" ]] || bash -n "$HELPER" 2>/dev/null; then
		print_result "helper script is valid bash" 0
	else
		print_result "helper script is valid bash" 1 "Syntax error in simplex-helper.sh"
	fi

	# Help output
	local help_output
	help_output="$(bash "$HELPER" help 2>&1)" || true

	if echo "$help_output" | grep -q "simplex-helper.sh"; then
		print_result "help: shows script name" 0
	else
		print_result "help: shows script name" 1 "Expected 'simplex-helper.sh' in help output"
	fi

	if echo "$help_output" | grep -q "install"; then
		print_result "help: mentions install command" 0
	else
		print_result "help: mentions install command" 1 "Expected 'install' in help output"
	fi

	if echo "$help_output" | grep -q "bot-start"; then
		print_result "help: mentions bot-start command" 0
	else
		print_result "help: mentions bot-start command" 1 "Expected 'bot-start' in help output"
	fi

	if echo "$help_output" | grep -q "bot-stop"; then
		print_result "help: mentions bot-stop command" 0
	else
		print_result "help: mentions bot-stop command" 1 "Expected 'bot-stop' in help output"
	fi

	if echo "$help_output" | grep -q "send"; then
		print_result "help: mentions send command" 0
	else
		print_result "help: mentions send command" 1 "Expected 'send' in help output"
	fi

	if echo "$help_output" | grep -q "connect"; then
		print_result "help: mentions connect command" 0
	else
		print_result "help: mentions connect command" 1 "Expected 'connect' in help output"
	fi

	if echo "$help_output" | grep -q "group"; then
		print_result "help: mentions group command" 0
	else
		print_result "help: mentions group command" 1 "Expected 'group' in help output"
	fi

	if echo "$help_output" | grep -q "status"; then
		print_result "help: mentions status command" 0
	else
		print_result "help: mentions status command" 1 "Expected 'status' in help output"
	fi

	if echo "$help_output" | grep -q "server"; then
		print_result "help: mentions server command" 0
	else
		print_result "help: mentions server command" 1 "Expected 'server' in help output"
	fi

	# Unknown command handling
	local unknown_output
	unknown_output="$(bash "$HELPER" nonexistent-command 2>&1)" || true

	if echo "$unknown_output" | grep -qi "unknown\|error"; then
		print_result "unknown command: returns error" 0
	else
		print_result "unknown command: returns error" 1 "Expected error for unknown command"
	fi

	# Status command (should work without simplex-chat installed)
	local status_output
	status_output="$(bash "$HELPER" status --no-color 2>&1)" || true

	if echo "$status_output" | grep -q "SimpleX Chat Status"; then
		print_result "status: shows status header" 0
	else
		print_result "status: shows status header" 1 "Expected 'SimpleX Chat Status' in output"
	fi

	if echo "$status_output" | grep -q "Binary:"; then
		print_result "status: shows binary status" 0
	else
		print_result "status: shows binary status" 1 "Expected 'Binary:' in status output"
	fi

	# Count subcommands (should have at least 8)
	local cmd_count
	cmd_count="$(grep -c 'cmd_' "$HELPER" 2>/dev/null || echo 0)"
	if [[ "$cmd_count" -ge 8 ]]; then
		print_result "helper has >= 8 cmd_ functions (found: ${cmd_count})" 0
	else
		print_result "helper has >= 8 cmd_ functions (found: ${cmd_count})" 1 "Expected at least 8 cmd_ functions"
	fi

	return 0
}

# =============================================================================
# Section 3: Subagent Index Tests
# =============================================================================

section_subagent_index() {
	echo ""
	echo -e "${CYAN}=== Subagent Index Tests ===${RESET}"

	local index_file="${AGENTS_DIR}/subagent-index.toon"

	if [[ ! -f "$index_file" ]]; then
		print_result "subagent-index.toon exists" 1 "File not found"
		return 0
	fi

	# Check simplex in communications subagent
	if grep -q "simplex" "$index_file"; then
		print_result "index: contains simplex reference" 0
	else
		print_result "index: contains simplex reference" 1 "Expected 'simplex' in subagent-index.toon"
	fi

	# Check opsec in security subagent
	if grep -q "opsec" "$index_file"; then
		print_result "index: contains opsec reference" 0
	else
		print_result "index: contains opsec reference" 1 "Expected 'opsec' in subagent-index.toon"
	fi

	# Check simplex-helper.sh in scripts section
	if grep -q "simplex-helper.sh" "$index_file"; then
		print_result "index: contains simplex-helper.sh" 0
	else
		print_result "index: contains simplex-helper.sh" 1 "Expected 'simplex-helper.sh' in scripts section"
	fi

	return 0
}

# =============================================================================
# Section 4: AGENTS.md Tests
# =============================================================================

section_agents_md() {
	echo ""
	echo -e "${CYAN}=== AGENTS.md Tests ===${RESET}"

	local agents_file="${AGENTS_DIR}/AGENTS.md"

	if [[ ! -f "$agents_file" ]]; then
		print_result "AGENTS.md exists" 1 "File not found"
		return 0
	fi

	# Check simplex in domain index
	if grep -q "simplex.md" "$agents_file"; then
		print_result "AGENTS.md: references simplex.md" 0
	else
		print_result "AGENTS.md: references simplex.md" 1 "Expected 'simplex.md' in domain index"
	fi

	# Check opsec in domain index
	if grep -q "opsec.md" "$agents_file"; then
		print_result "AGENTS.md: references opsec.md" 0
	else
		print_result "AGENTS.md: references opsec.md" 1 "Expected 'opsec.md' in domain index"
	fi

	# Check Communications row
	if grep -q "Communications" "$agents_file"; then
		print_result "AGENTS.md: has Communications domain" 0
	else
		print_result "AGENTS.md: has Communications domain" 1 "Expected 'Communications' in domain index"
	fi

	return 0
}

# =============================================================================
# Section 5: Markdown Structure Tests
# =============================================================================

section_markdown_structure() {
	echo ""
	echo -e "${CYAN}=== Markdown Structure Tests ===${RESET}"

	local simplex_md="${AGENTS_DIR}/services/communications/simplex.md"

	if [[ ! -f "$simplex_md" ]]; then
		print_result "simplex.md available for structure tests" 1 "File not found"
		return 0
	fi

	# Check YAML frontmatter
	if head -1 "$simplex_md" | grep -q "^---"; then
		print_result "simplex.md: has YAML frontmatter" 0
	else
		print_result "simplex.md: has YAML frontmatter" 1 "Expected YAML frontmatter"
	fi

	# Check AI-CONTEXT markers
	if grep -q "AI-CONTEXT-START" "$simplex_md"; then
		print_result "simplex.md: has AI-CONTEXT-START" 0
	else
		print_result "simplex.md: has AI-CONTEXT-START" 1 "Expected AI-CONTEXT-START marker"
	fi

	if grep -q "AI-CONTEXT-END" "$simplex_md"; then
		print_result "simplex.md: has AI-CONTEXT-END" 0
	else
		print_result "simplex.md: has AI-CONTEXT-END" 1 "Expected AI-CONTEXT-END marker"
	fi

	# Check key sections exist
	local sections=("Installation" "Bot API" "Business Addresses" "Protocol" "Limitations" "Cross-Device" "Self-Hosted" "Upstream Contributions" "Security")
	for section in "${sections[@]}"; do
		if grep -q "$section" "$simplex_md"; then
			print_result "simplex.md: has '${section}' section" 0
		else
			print_result "simplex.md: has '${section}' section" 1 "Expected '${section}' section"
		fi
	done

	# Check slash command coexistence documentation
	if grep -q "Slash Command" "$simplex_md"; then
		print_result "simplex.md: documents slash command coexistence" 0
	else
		print_result "simplex.md: documents slash command coexistence" 1 "Expected slash command documentation"
	fi

	# Check opsec.md structure
	local opsec_md="${AGENTS_DIR}/tools/security/opsec.md"
	if [[ -f "$opsec_md" ]]; then
		if grep -q "Threat Model" "$opsec_md"; then
			print_result "opsec.md: has threat modeling section" 0
		else
			print_result "opsec.md: has threat modeling section" 1 "Expected threat modeling section"
		fi

		if grep -q "Platform Trust Matrix" "$opsec_md"; then
			print_result "opsec.md: has platform trust matrix" 0
		else
			print_result "opsec.md: has platform trust matrix" 1 "Expected platform trust matrix"
		fi
	else
		print_result "opsec.md available for structure tests" 1 "File not found"
	fi

	return 0
}

# =============================================================================
# Section 6: Bot Framework Scaffold Tests
# =============================================================================

section_bot_framework() {
	echo ""
	echo -e "${CYAN}=== Bot Framework Scaffold Tests ===${RESET}"

	local bot_dir="${AGENTS_DIR}/scripts/simplex-bot"

	if [[ ! -d "$bot_dir" ]]; then
		print_result "simplex-bot directory exists" 1 "Directory not found"
		return 0
	fi

	# package.json checks
	local pkg="${bot_dir}/package.json"
	if [[ -f "$pkg" ]]; then
		if grep -q "simplex-chat" "$pkg"; then
			print_result "package.json: has simplex-chat dependency" 0
		else
			print_result "package.json: has simplex-chat dependency" 1 "Expected simplex-chat in dependencies"
		fi

		if grep -q "bun" "$pkg"; then
			print_result "package.json: references bun" 0
		else
			print_result "package.json: references bun" 1 "Expected bun reference"
		fi
	fi

	# TypeScript source checks
	local index_ts="${bot_dir}/src/index.ts"
	if [[ -f "$index_ts" ]]; then
		if grep -q "WebSocket" "$index_ts"; then
			print_result "index.ts: uses WebSocket connection" 0
		else
			print_result "index.ts: uses WebSocket connection" 1 "Expected WebSocket usage"
		fi

		if grep -q "CommandRouter" "$index_ts"; then
			print_result "index.ts: has command router" 0
		else
			print_result "index.ts: has command router" 1 "Expected CommandRouter class"
		fi

		if grep -q "SimplexAdapter" "$index_ts"; then
			print_result "index.ts: has SimplexAdapter" 0
		else
			print_result "index.ts: has SimplexAdapter" 1 "Expected SimplexAdapter class"
		fi
	fi

	# Types checks
	local types_ts="${bot_dir}/src/types.ts"
	if [[ -f "$types_ts" ]]; then
		if grep -q "NewChatItems" "$types_ts"; then
			print_result "types.ts: defines NewChatItems event" 0
		else
			print_result "types.ts: defines NewChatItems event" 1 "Expected NewChatItems type"
		fi

		if grep -q "APISendMessages\|SimplexCommand" "$types_ts"; then
			print_result "types.ts: defines API command types" 0
		else
			print_result "types.ts: defines API command types" 1 "Expected API command types"
		fi

		if grep -q "ChannelAdapter" "$types_ts"; then
			print_result "types.ts: defines ChannelAdapter interface" 0
		else
			print_result "types.ts: defines ChannelAdapter interface" 1 "Expected ChannelAdapter for gateway pattern"
		fi
	fi

	# Commands checks
	local commands_ts="${bot_dir}/src/commands.ts"
	if [[ -f "$commands_ts" ]]; then
		local cmd_count
		cmd_count="$(grep -c "name:" "$commands_ts" 2>/dev/null || echo 0)"
		if [[ "$cmd_count" -ge 5 ]]; then
			print_result "commands.ts: has >= 5 starter commands (found: ${cmd_count})" 0
		else
			print_result "commands.ts: has >= 5 starter commands (found: ${cmd_count})" 1 "Expected at least 5 commands"
		fi

		# Check for key commands
		for cmd in "help" "status" "ask" "ping"; do
			if grep -q "\"${cmd}\"" "$commands_ts"; then
				print_result "commands.ts: has /${cmd} command" 0
			else
				print_result "commands.ts: has /${cmd} command" 1 "Expected /${cmd} command"
			fi
		done
	fi

	return 0
}

# =============================================================================
# Section 7: ShellCheck Tests
# =============================================================================

section_shellcheck() {
	echo ""
	echo -e "${CYAN}=== ShellCheck Tests ===${RESET}"

	if ! command -v shellcheck &>/dev/null; then
		print_result "shellcheck available" 2 "shellcheck not installed"
		return 0
	fi

	if [[ -f "$HELPER" ]]; then
		local sc_output
		sc_output="$(shellcheck -S warning "$HELPER" 2>&1)" || true
		local sc_exit=$?

		if [[ -z "$sc_output" ]] || [[ "$sc_exit" -eq 0 ]]; then
			print_result "simplex-helper.sh: shellcheck clean" 0
		else
			local issue_count
			issue_count="$(echo "$sc_output" | grep -c "^In " 2>/dev/null || echo "?")"
			print_result "simplex-helper.sh: shellcheck clean" 1 "${issue_count} issues found"
			echo "$sc_output" | head -20
		fi
	fi

	# Check this test script too
	local this_script="${SCRIPT_DIR}/test-simplex-integration.sh"
	if [[ -f "$this_script" ]]; then
		local sc_output2
		sc_output2="$(shellcheck -S warning "$this_script" 2>&1)" || true
		local sc_exit2=$?

		if [[ -z "$sc_output2" ]] || [[ "$sc_exit2" -eq 0 ]]; then
			print_result "test-simplex-integration.sh: shellcheck clean" 0
		else
			local issue_count2
			issue_count2="$(echo "$sc_output2" | grep -c "^In " 2>/dev/null || echo "?")"
			print_result "test-simplex-integration.sh: shellcheck clean" 1 "${issue_count2} issues found"
			echo "$sc_output2" | head -20
		fi
	fi

	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	echo "============================================="
	echo "SimpleX Chat Integration Tests (t1327 series)"
	echo "============================================="

	section_file_existence
	section_helper_script
	section_subagent_index
	section_agents_md
	section_markdown_structure
	section_bot_framework
	section_shellcheck

	echo ""
	echo "============================================="
	echo -e "Results: ${GREEN}${TESTS_PASSED} passed${RESET}, ${RED}${TESTS_FAILED} failed${RESET}, ${YELLOW}${TESTS_SKIPPED} skipped${RESET} (${TESTS_RUN} total)"
	echo "============================================="

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
