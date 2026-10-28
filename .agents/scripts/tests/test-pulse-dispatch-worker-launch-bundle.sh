#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# GH#35810: the extracted routing library must work without the orchestrator.
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
unset SCRIPT_DIR _PULSE_DISPATCH_WORKER_LAUNCH_BUNDLE_LOADED
# shellcheck source=../pulse-dispatch-worker-launch-bundle.sh
source "${SCRIPTS_DIR}/pulse-dispatch-worker-launch-bundle.sh"

assert_equal() {
	local expected="$1"
	local actual="$2"
	local description="$3"
	if [[ "$actual" != "$expected" ]]; then
		printf 'FAIL: %s (expected %s, got %s)\n' "$description" "$expected" "$actual" >&2
		return 1
	fi
	return 0
}

assert_equal "$SCRIPTS_DIR" "$SCRIPT_DIR" "standalone script directory fallback"
assert_equal "1" "$_PULSE_DISPATCH_WORKER_LAUNCH_BUNDLE_LOADED" "include guard initialization"

# A second source must return before touching the caller's directory or functions.
SCRIPT_DIR="caller-owned-directory"
before_definition="$(declare -f _dlw_bundle_workload_type)"
# shellcheck source=../pulse-dispatch-worker-launch-bundle.sh
source "${SCRIPTS_DIR}/pulse-dispatch-worker-launch-bundle.sh"
assert_equal "caller-owned-directory" "$SCRIPT_DIR" "repeated source preserves caller directory"
assert_equal "$before_definition" "$(declare -f _dlw_bundle_workload_type)" "repeated source preserves functions"

assert_equal "documentation" "$(_dlw_bundle_workload_type 'DOCS: update guide' '')" "case-insensitive title prefix"
assert_equal "implementation" "$(_dlw_bundle_workload_type 'fix: review routing' 'docs: generic prompt')" "title overrides prompt"
assert_equal "verification" "$(_dlw_bundle_workload_type '' 'verify: worker result')" "empty title prompt fallback"

assert_equal "seo" "$(_dlw_bundle_routing_domain 'fix: sitemap' '')" "SEO routing"
assert_equal "content" "$(_dlw_bundle_routing_domain 'fix: newsletter' '')" "content routing"
assert_equal "accessibility" "$(_dlw_bundle_routing_domain 'fix: WCAG' '')" "accessibility routing"
assert_equal "infrastructure" "$(_dlw_bundle_routing_domain 'fix: worker' 'Docker deployment')" "prompt domain routing"
assert_equal "documentation" "$(_dlw_bundle_routing_domain 'fix: README' '')" "documentation routing"
assert_equal "code" "$(_dlw_bundle_routing_domain 'fix: worker locking' '')" "default code routing"
assert_equal "" "$(_dlw_bundle_agent_name '' 'fix: worker' '')" "missing repository has no preferred agent"

printf 'PASS: extracted worker launch bundle loading and routing\n'
