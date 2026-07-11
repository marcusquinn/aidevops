#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
AGENTS_DIR="$TEST_ROOT/agents"
agent_dir="$TEST_ROOT/opencode-agents"

cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

mkdir -p "$AGENTS_DIR/tools/code-review" "$agent_dir"

cat >"$AGENTS_DIR/tools/code-review/bounded-review.md" <<'EOF_AGENT'
---
description: Bounded review agent
mode: subagent
variant: high
steps: 12
tools:
  read: true
  bash: true
  task: false
---

# Bounded review
EOF_AGENT

cat >"$AGENTS_DIR/tools/code-review/sandboxed-review.md" <<'EOF_AGENT'
---
description: Sandboxed review agent
mode: subagent
model: thinking
tools:
  read: true
  bash: false
  task: false
---

# Sandboxed review
EOF_AGENT

# shellcheck source=../generate-runtime-config-agents.sh
set +e
source "$REPO_ROOT/.agents/scripts/generate-runtime-config-agents.sh"
source_status=$?
set -e
[[ "$source_status" -eq 0 ]]

if ! _write_subagent_stub "$AGENTS_DIR/tools/code-review/bounded-review.md" >/dev/null; then
	printf '%s\n' 'FAIL: could not generate bounded OpenCode subagent' >&2
	exit 1
fi

generated="$agent_dir/bounded-review.md"
[[ -f "$generated" ]]
grep -q '^variant: high$' "$generated"
grep -q '^steps: 12$' "$generated"
grep -q '^  task: false$' "$generated"

if ! _write_subagent_stub "$AGENTS_DIR/tools/code-review/sandboxed-review.md" >/dev/null; then
	printf '%s\n' 'FAIL: could not generate sandboxed OpenCode subagent' >&2
	exit 1
fi

sandboxed_generated="$agent_dir/sandboxed-review.md"
grep -q '^  bash: false$' "$sandboxed_generated"
if grep -q '^model: thinking$' "$sandboxed_generated"; then
	printf '%s\n' 'FAIL: workload tier leaked into OpenCode model field' >&2
	exit 1
fi

printf '%s\n' 'PASS: generated OpenCode subagents preserve guards without treating workload tiers as model IDs'
exit 0
