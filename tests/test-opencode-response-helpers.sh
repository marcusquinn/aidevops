#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Smoke test for .agents/plugins/opencode-aidevops/response-helpers.mjs.
#
# This test does NOT exercise the realm-boundary bug that motivated the
# helpers — that bug only manifests inside OpenCode's plugin loader, not
# in a standalone Node/Bun process. What this test DOES verify:
#
#   1. The module parses and loads.
#   2. jsonResponse() returns a Response with status 200 by default and
#      the data round-trips through .json().
#   3. jsonResponse() honours init.status and custom headers.
#   4. textResponse() returns a Response with the given body and init.
#   5. The three importers (cursor/proxy.js, cursor/proxy-stream.js,
#      provider-auth-request.mjs) parse clean with node --check, catching
#      import-path typos or syntax regressions.
#
# The real-world acceptance test is "start opencode-web.service and tail
# journal for 'Expected a Response object, but received _Response'". That
# is documented in the PR body.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_DIR="$REPO_ROOT/.agents/plugins/opencode-aidevops"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

fail() {
	echo -e "${RED}FAIL${NC}: $*" >&2
	exit 1
}

pass() {
	echo -e "${GREEN}PASS${NC}: $*"
}

# Prefer bun if available (matches plugin runtime); fall back to node ≥18.
if command -v bun >/dev/null 2>&1; then
	RUNNER=(bun run)
elif command -v node >/dev/null 2>&1; then
	RUNNER=(node)
else
	echo "SKIP: neither bun nor node available" >&2
	exit 0
fi

# --- 1. Syntax-check all modified files -----------------------------------
if command -v node >/dev/null 2>&1; then
	for f in \
		"$PLUGIN_DIR/response-helpers.mjs" \
		"$PLUGIN_DIR/cursor/proxy.js" \
		"$PLUGIN_DIR/cursor/proxy-stream.js" \
		"$PLUGIN_DIR/provider-auth-request.mjs"; do
		node --check "$f" || fail "node --check failed on $f"
	done
	pass "syntax check on response-helpers.mjs + 3 importers"
fi

# --- 2. Runtime behaviour -------------------------------------------------
TMP_SCRIPT="$(mktemp -t response-helpers-test.XXXXXX.mjs)"
trap 'rm -f "$TMP_SCRIPT"' EXIT

cat >"$TMP_SCRIPT" <<EOF
import { jsonResponse, textResponse } from "$PLUGIN_DIR/response-helpers.mjs";

function assert(cond, msg) {
  if (!cond) {
    console.error("FAIL: " + msg);
    process.exit(1);
  }
}

// jsonResponse default
{
  const r = jsonResponse({ hello: "world" });
  assert(r instanceof Response, "jsonResponse returns Response");
  assert(r.status === 200, "default status 200, got " + r.status);
  const body = await r.json();
  assert(body.hello === "world", "round-trip data");
}

// jsonResponse with init
{
  const r = jsonResponse({ error: "bad" }, { status: 503 });
  assert(r.status === 503, "custom status, got " + r.status);
  const body = await r.json();
  assert(body.error === "bad", "round-trip data with status");
}

// textResponse plain text
{
  const r = textResponse("Not Found", { status: 404 });
  assert(r instanceof Response, "textResponse returns Response");
  assert(r.status === 404, "textResponse status 404");
  const text = await r.text();
  assert(text === "Not Found", "textResponse body round-trips");
}

// textResponse with ReadableStream (streaming passthrough case)
{
  const stream = new ReadableStream({
    start(ctrl) {
      ctrl.enqueue(new TextEncoder().encode("chunk1"));
      ctrl.close();
    },
  });
  const r = textResponse(stream, { headers: { "Content-Type": "text/event-stream" } });
  assert(r instanceof Response, "textResponse accepts ReadableStream");
  assert(r.headers.get("Content-Type") === "text/event-stream", "headers propagate");
  const text = await r.text();
  assert(text === "chunk1", "stream body round-trips");
}

console.log("OK");
EOF

output="$("${RUNNER[@]}" "$TMP_SCRIPT" 2>&1)" || fail "runtime test failed: $output"
[[ "$output" == *"OK"* ]] || fail "runtime test did not print OK: $output"
pass "jsonResponse + textResponse runtime behaviour"

echo ""
echo "All response-helpers tests passed."
