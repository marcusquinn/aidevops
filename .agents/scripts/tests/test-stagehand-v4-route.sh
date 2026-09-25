#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../stagehand-v4-helper.sh"
SOURCE="${SCRIPT_DIR}/../../tools/browser/stagehand-v4-example.mjs"
TEMP_BASE="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
mkdir -p "$TEMP_BASE"
TEST_HOME="$(mktemp -d "${TEMP_BASE}/stagehand-v4-route.XXXXXX")"
trap 'rm -rf "$TEST_HOME"' EXIT

if HOME="$TEST_HOME" bash "$HELPER" status >/dev/null 2>&1; then
	printf 'Uninstalled Stagehand v4 must not report success\n' >&2
	exit 1
fi

INSTALL_DIR="${TEST_HOME}/.aidevops/stagehand-v4"
mkdir -p "${INSTALL_DIR}/node_modules/@browserbasehq/stagehand" "${INSTALL_DIR}/node_modules/zod"
printf '{"version":"4.1.0"}\n' >"${INSTALL_DIR}/node_modules/@browserbasehq/stagehand/package.json"
printf '{"version":"4.4.3"}\n' >"${INSTALL_DIR}/node_modules/zod/package.json"
HOME="$TEST_HOME" bash "$HELPER" status >/dev/null

cp "$SOURCE" "${INSTALL_DIR}/example.mjs"
if env -u OPENAI_API_KEY -u STAGEHAND_MODEL HOME="$TEST_HOME" bash "$HELPER" run-example >/dev/null 2>&1; then
	printf 'Model-backed example ran without explicit credentials and model\n' >&2
	exit 1
fi

printf '\n// unreviewed edit\n' >>"${INSTALL_DIR}/example.mjs"
if HOME="$TEST_HOME" OPENAI_API_KEY=placeholder STAGEHAND_MODEL=openai/placeholder bash "$HELPER" run-example >/dev/null 2>&1; then
	printf 'Modified example must not run through the reviewed route\n' >&2
	exit 1
fi

printf '{"version":"3.7.3"}\n' >"${INSTALL_DIR}/node_modules/@browserbasehq/stagehand/package.json"
if HOME="$TEST_HOME" bash "$HELPER" status >/dev/null 2>&1; then
	printf 'Stagehand v3 must not satisfy the v4 version pin\n' >&2
	exit 1
fi
printf 'Stagehand v4 bounded route: PASS\n'
