#!/usr/bin/env bash
# feature-toggle-helper.sh - Backward-compatible wrapper for aidevops config
#
# DEPRECATED: This script delegates to config-helper.sh (JSONC config system).
# Kept for backward compatibility with existing `aidevops config` invocations.
# Legacy flat keys (e.g. "auto_update") are automatically mapped to namespaced
# dotpaths (e.g. "updates.auto_update").
#
# New code should use config-helper.sh directly.
#
# Usage:
#   feature-toggle-helper.sh list              List all config with current values
#   feature-toggle-helper.sh get <key>         Get a config value
#   feature-toggle-helper.sh set <key> <value> Set a config value
#   feature-toggle-helper.sh reset [key]       Reset one or all config to defaults
#   feature-toggle-helper.sh path              Show config file paths
#   feature-toggle-helper.sh migrate           Migrate from legacy .conf to JSONC
#   feature-toggle-helper.sh help              Show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit

# Delegate to config-helper.sh if available
CONFIG_HELPER="${SCRIPT_DIR}/config-helper.sh"
if [[ -x "$CONFIG_HELPER" ]]; then
	exec bash "$CONFIG_HELPER" "$@"
fi

# Fallback: source shared-constants and run legacy mode
# This path is only hit if config-helper.sh is missing (shouldn't happen)
echo "[WARN] config-helper.sh not found, using legacy mode" >&2
source "${SCRIPT_DIR}/shared-constants.sh"

echo "[ERROR] Legacy feature-toggle-helper.sh is deprecated." >&2
echo "  Run 'aidevops update' to get the new JSONC config system." >&2
exit 1
