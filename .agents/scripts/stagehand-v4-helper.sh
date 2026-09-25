#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Opt-in, isolated Stagehand v4 SDK route. Never connects to a user browser.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

readonly STAGEHAND_V4_VERSION="4.1.0"
readonly STAGEHAND_V4_ZOD_VERSION="4.4.3"
readonly STAGEHAND_V4_DIR="${HOME}/.aidevops/stagehand-v4"
readonly STAGEHAND_V4_EXAMPLE="${STAGEHAND_V4_DIR}/example.mjs"
readonly STAGEHAND_V4_SOURCE="${SCRIPT_DIR}/../tools/browser/stagehand-v4-example.mjs"

stagehand_v4_installed() {
	[[ -f "${STAGEHAND_V4_DIR}/node_modules/@browserbasehq/stagehand/package.json" ]] || return 1
	[[ -f "${STAGEHAND_V4_DIR}/node_modules/zod/package.json" ]] || return 1
	node -e '
		const fs = require("node:fs");
		const path = require("node:path");
		const root = process.argv[1];
		const version = (name) => JSON.parse(fs.readFileSync(path.join(root, "node_modules", name, "package.json"), "utf8")).version;
		process.exit(version("@browserbasehq/stagehand") === "4.1.0" && version("zod") === "4.4.3" ? 0 : 1);
	' "$STAGEHAND_V4_DIR" >/dev/null 2>&1
}

stagehand_v4_install() {
	command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1 || {
		print_error "Node.js and npm are required"
		return 1
	}
	if stagehand_v4_installed; then
		print_info "Stagehand v${STAGEHAND_V4_VERSION} is already installed"
		return 0
	fi
	mkdir -p "$STAGEHAND_V4_DIR" || return 1
	# Separate project: existing Stagehand v3 installs and browser profiles are untouched.
	npm install --prefix "$STAGEHAND_V4_DIR" --ignore-scripts --save-exact \
		"@browserbasehq/stagehand@${STAGEHAND_V4_VERSION}" \
		"zod@${STAGEHAND_V4_ZOD_VERSION}" || return 1
	stagehand_v4_installed || {
		print_error "Stagehand v4 dependency versions did not match the reviewed pins"
		return 1
	}
	print_success "Installed isolated Stagehand v${STAGEHAND_V4_VERSION}"
}

stagehand_v4_example() {
	stagehand_v4_installed || {
		print_error "Install the reviewed Stagehand v4 dependencies first"
		return 1
	}
	[[ -f "$STAGEHAND_V4_SOURCE" ]] || return 1
	# Never overwrite a user-edited example.
	if [[ ! -e "$STAGEHAND_V4_EXAMPLE" ]]; then
		cp "$STAGEHAND_V4_SOURCE" "$STAGEHAND_V4_EXAMPLE" || return 1
	fi
	print_info "Example: $STAGEHAND_V4_EXAMPLE"
}

stagehand_v4_run() {
	stagehand_v4_installed || return 1
	[[ -f "$STAGEHAND_V4_EXAMPLE" ]] || {
		print_error "Run setup to create the local example first"
		return 1
	}
	cmp -s "$STAGEHAND_V4_SOURCE" "$STAGEHAND_V4_EXAMPLE" || {
		print_error "Example differs from the reviewed source; inspect it and run custom scripts explicitly"
		return 1
	}
	[[ -n "${OPENAI_API_KEY:-}" && -n "${STAGEHAND_MODEL:-}" ]] || {
		print_error "Set OPENAI_API_KEY and STAGEHAND_MODEL explicitly before model-backed execution"
		return 1
	}
	# Fixed example and owned isolated browser only: no arbitrary script/CDP/profile input.
	node "$STAGEHAND_V4_EXAMPLE"
}

case "${1:-help}" in
install) stagehand_v4_install ;;
setup) stagehand_v4_install && stagehand_v4_example ;;
status)
	stagehand_v4_installed || {
		print_error "Reviewed Stagehand v${STAGEHAND_V4_VERSION} is not installed"
		exit 1
	}
	print_success "Stagehand v${STAGEHAND_V4_VERSION} is installed in the isolated project"
	;;
run-example) stagehand_v4_run ;;
help | --help)
	printf 'Usage: %s {install|setup|status|run-example}\n' "$0"
	printf 'Opt-in isolated Stagehand v4.1.0; run-example requires OPENAI_API_KEY and STAGEHAND_MODEL.\n'
	;;
*)
	print_error "Unknown Stagehand v4 command"
	exit 1
	;;
esac
