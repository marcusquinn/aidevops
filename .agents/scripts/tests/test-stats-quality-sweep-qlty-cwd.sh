#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression test for GH#24842: `_sweep_qlty` must execute Qlty from the
# target repository path, not from the stats wrapper's current directory.
#
# Run:
#   bash .agents/scripts/tests/test-stats-quality-sweep-qlty-cwd.sh
#
# shellcheck disable=SC1090,SC1091

set -euo pipefail

TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${TEST_SCRIPT_DIR}/.." && pwd)" || exit 1

TMP_HOME=$(mktemp -d)
TMP_REPO=$(mktemp -d)
TMP_REL_PARENT=$(mktemp -d)
TMP_CDPATH_PARENT=$(mktemp -d)
FAKE_BIN=$(mktemp -d)
QLTY_PWD_FILE="${TMP_HOME}/qlty-pwd.txt"
export HOME="$TMP_HOME"
export LOGFILE="${TMP_HOME}/test.log"
export QUALITY_SWEEP_STATE_DIR="${TMP_HOME}/state"
export QLTY_PWD_FILE
PATH="${FAKE_BIN}:${PATH}"
export PATH

cleanup() {
	rm -rf "$TMP_HOME" "$TMP_REPO" "$TMP_REL_PARENT" "$TMP_CDPATH_PARENT" "$FAKE_BIN"
	return 0
}
trap cleanup EXIT

mkdir -p "${HOME}/.qlty/bin" "${TMP_REPO}/.qlty" "$QUALITY_SWEEP_STATE_DIR"
printf '%s\n' '[plugins]' >"${TMP_REPO}/.qlty/qlty.toml"

cat >"${HOME}/.qlty/bin/qlty" <<'QLTY'
#!/usr/bin/env bash
set -euo pipefail
pwd >"${QLTY_PWD_FILE:?}"
printf '%s\n' '{"runs":[{"results":[{"ruleId":"function-complexity","locations":[{"physicalLocation":{"artifactLocation":{"uri":"scripts/example.sh"}}}]}]}]}'
QLTY
chmod +x "${HOME}/.qlty/bin/qlty"

cat >"${FAKE_BIN}/curl" <<'CURL'
#!/usr/bin/env bash
exit 22
CURL
chmod +x "${FAKE_BIN}/curl"

# Source dependencies. stats-functions.sh expects shared-constants and
# worker-lifecycle-common to be sourced first.
source "${SCRIPTS_DIR}/shared-constants.sh"
source "${SCRIPTS_DIR}/worker-lifecycle-common.sh"
source "${SCRIPTS_DIR}/stats-functions.sh"

_create_simplification_issues() {
	return 0
}

result=$(_sweep_qlty "owner/repo" "$TMP_REPO")
qlty_section="${result%%|*}"
qlty_remainder="${result#*|}"
qlty_smell_count="${qlty_remainder%%|*}"

if [[ ! -f "$QLTY_PWD_FILE" ]]; then
	printf '%s\n' "FAIL qlty was not executed"
	exit 1
fi

actual_pwd=$(<"$QLTY_PWD_FILE")
if [[ "$actual_pwd" != "$TMP_REPO" ]]; then
	printf '%s\n' "FAIL qlty ran from wrong cwd: expected ${TMP_REPO}, got ${actual_pwd}"
	exit 1
fi

if [[ "$qlty_smell_count" != "1" ]]; then
	printf '%s\n' "FAIL qlty smell count: expected 1, got ${qlty_smell_count}"
	exit 1
fi

if [[ "$qlty_section" != *"scripts/example.sh"* ]]; then
	printf '%s\n' "FAIL qlty section omitted SARIF file path"
	exit 1
fi

mkdir -p "${TMP_REL_PARENT}/target-repo/.qlty" "${TMP_CDPATH_PARENT}/target-repo/.qlty"
printf '%s\n' '[plugins]' >"${TMP_REL_PARENT}/target-repo/.qlty/qlty.toml"
printf '%s\n' '[plugins]' >"${TMP_CDPATH_PARENT}/target-repo/.qlty/qlty.toml"

rm -f "$QLTY_PWD_FILE"
(
	cd "$TMP_REL_PARENT"
	CDPATH="$TMP_CDPATH_PARENT" _sweep_qlty "owner/repo" "target-repo" >/dev/null
)

actual_pwd=$(<"$QLTY_PWD_FILE")
if [[ "$actual_pwd" != "${TMP_REL_PARENT}/target-repo" ]]; then
	printf '%s\n' "FAIL qlty relative path was hijacked by CDPATH: expected ${TMP_REL_PARENT}/target-repo, got ${actual_pwd}"
	exit 1
fi

printf '%s\n' "PASS _sweep_qlty runs from repo_path"
