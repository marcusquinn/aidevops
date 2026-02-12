#!/usr/bin/env bash
# Migration functions for setup.sh

# Remove deprecated agent paths that have been moved
# This ensures clean upgrades when agents are reorganized
cleanup_deprecated_paths() {
	# TODO: Extract from setup.sh lines 305-390
	:
}

# Migrate .agent -> .agents in user projects and local config
migrate_agent_to_agents_folder() {
	# TODO: Extract from setup.sh lines 400-520
	:
}

# Remove deprecated MCP entries from opencode.json
cleanup_deprecated_mcps() {
	# TODO: Extract from setup.sh lines 524-652
	:
}

# Disable MCPs globally that should only be enabled on-demand via subagents
disable_ondemand_mcps() {
	# TODO: Extract from setup.sh lines 661-737
	:
}

# Validate and repair OpenCode config schema
validate_opencode_config() {
	# TODO: Extract from setup.sh lines 744-834
	:
}

# Migrate mcp-env.sh to credentials.sh (v2.105.0)
migrate_mcp_env_to_credentials() {
	# TODO: Extract from setup.sh lines 838-895
	:
}

# Migrate old config-backups to new per-type backup structure
migrate_old_backups() {
	# TODO: Extract from setup.sh lines 899-951
	:
}

# Migrate loop state from .claude/ to .agents/loop-state/ in user projects
migrate_loop_state_directories() {
	# TODO: Extract from setup.sh lines 956-1046
	:
}
