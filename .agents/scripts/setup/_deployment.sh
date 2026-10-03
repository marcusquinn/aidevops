#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Agent source sync for setup.sh; deployment and plugin functions live in modules/.

# Sync agents from private repositories into custom/
sync_agent_sources() {
	local helper_script="${HOME}/.aidevops/agents/scripts/agent-sources-helper.sh"
	if [[ -f "${helper_script}" ]]; then
		echo "Syncing agent sources from private repositories..."
		bash "${helper_script}" sync
	else
		# Helper not deployed yet — will be available after first full setup
		:
	fi
	return 0
}
