#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Durable release reconciliation regression tests.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
REPO_ROOT="${SCRIPT_DIR}/../.."
_FULL_LOOP_SHA40_REGEX='^[0-9a-f]{40}$'
_FULL_LOOP_PHASE_FAILED="failed"
_FULL_LOOP_RELEASE_PUBLISHED="published"
_FULL_LOOP_RELEASE_SUPERSEDED="superseded"
_FULL_LOOP_RELEASE_NOT_REQUESTED="not-requested"
_FULL_LOOP_RELEASE_RECONCILE_PUBLISHED="published-reconcile"
_FULL_LOOP_RELEASE_RECONCILE_AUTHORIZED="authorized-published-reconcile"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "${TEST_ROOT}/bin" "${TEST_ROOT}/receipts"

# shellcheck source=../full-loop-release-reconcile.sh
source "${SCRIPT_DIR}/full-loop-release-reconcile.sh"
# shellcheck source=../release-authorization-manifest-helper.sh
source "${SCRIPT_DIR}/release-authorization-manifest-helper.sh"

# shellcheck source=test-full-loop-release-reconcile-proof.sh
source "${SCRIPT_DIR}/tests/test-full-loop-release-reconcile-proof.sh"
# shellcheck source=test-full-loop-release-reconcile-discovery.sh
source "${SCRIPT_DIR}/tests/test-full-loop-release-reconcile-discovery.sh"
# shellcheck source=test-full-loop-release-reconcile-runtime.sh
source "${SCRIPT_DIR}/tests/test-full-loop-release-reconcile-runtime.sh"
# shellcheck source=test-full-loop-release-reconcile-channels.sh
source "${SCRIPT_DIR}/tests/test-full-loop-release-reconcile-channels.sh"
# shellcheck source=test-full-loop-release-reconcile-supersession.sh
source "${SCRIPT_DIR}/tests/test-full-loop-release-reconcile-supersession.sh"
# shellcheck source=test-full-loop-release-reconcile-command.sh
source "${SCRIPT_DIR}/tests/test-full-loop-release-reconcile-command.sh"

exit 0
