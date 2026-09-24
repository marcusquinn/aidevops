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

# An explicitly pinned operator agent must never be cleaned or overwritten,
# even if a source of the same basename is later added to aidevops.
cat >"$agent_dir/operator-worker.md" <<'EOF_OPERATOR'
---
mode: subagent
model: example-provider/pinned-model
---

Operator-owned prompt
EOF_OPERATOR
cp "$agent_dir/operator-worker.md" "$TEST_ROOT/operator-original.md"
cat >"$AGENTS_DIR/tools/code-review/operator-worker.md" <<'EOF_COLLISION'
---
mode: subagent
---

Colliding aidevops source
EOF_COLLISION
cat >"$agent_dir/obsolete.md" <<'EOF_OBSOLETE'
---
mode: subagent
---
<!-- aidevops:generated-subagent -->

Stale generated prompt
EOF_OBSOLETE

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

cat >"$AGENTS_DIR/tools/code-review/research-only.md" <<'EOF_AGENT'
---
description: Research-only agent
mode: subagent
tools:
  "*": false
  read: true
  grep: true
  glob: true
  webfetch: true
  write: false
  edit: false
  apply_patch: false
  bash: false
  task: false
permission:
  "*": deny
  read: allow
  grep: allow
  glob: allow
  webfetch: allow
  write: deny
  edit: deny
  apply_patch: deny
  bash: deny
  task: deny
  external_directory: deny
---

# Research-only
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

for unsafe_worktree_base in "" "/" "///" "relative/worktrees" "~"; do
	if AIDEVOPS_WORKTREE_BASE_DIR="$unsafe_worktree_base" _validated_worktree_base >/dev/null 2>&1; then
		printf 'FAIL: accepted unsafe configured worktree base %q\n' "$unsafe_worktree_base" >&2
		exit 1
	fi
done

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
grep -q '^aidevops_model_tier: thinking$' "$sandboxed_generated"
if grep -q '^model:' "$sandboxed_generated"; then
	printf '%s\n' 'FAIL: generated tier intent pinned a concrete provider model' >&2
	exit 1
fi
if grep -q '^variant:' "$sandboxed_generated"; then
	printf '%s\n' 'FAIL: generated tier intent pinned a provider-specific variant' >&2
	exit 1
fi

if ! _write_subagent_stub "$AGENTS_DIR/tools/code-review/research-only.md" >/dev/null; then
	printf '%s\n' 'FAIL: could not generate research-only OpenCode subagent' >&2
	exit 1
fi

research_generated="$agent_dir/research-only.md"
grep -q '^  "\*": false$' "$research_generated"
grep -q '^  read: true$' "$research_generated"
grep -q '^  write: false$' "$research_generated"
grep -q '^  edit: false$' "$research_generated"
grep -q '^  apply_patch: false$' "$research_generated"
grep -q '^  bash: false$' "$research_generated"
grep -q '^  task: false$' "$research_generated"
grep -q '^  external_directory: deny$' "$research_generated"

print_info() {
	return 0
}

print_success() {
	return 0
}

# Exercise the production xargs child-shell boundary. Direct helper calls above
# cannot detect a missing export for a helper used only by restrictive sources.
if ! _generate_subagents_opencode "$agent_dir" >/dev/null; then
	printf '%s\n' 'FAIL: parallel OpenCode subagent generation failed' >&2
	exit 1
fi

cmp "$TEST_ROOT/operator-original.md" "$agent_dir/operator-worker.md"
[[ ! -e "$agent_dir/obsolete.md" ]]
grep -q '^<!-- aidevops:generated-subagent -->$' "$agent_dir/bounded-review.md"
grep -q '^<!-- aidevops:generated-subagent -->$' "$sandboxed_generated"
grep -q '^<!-- aidevops:generated-subagent -->$' "$research_generated"
_generate_subagents_opencode "$agent_dir" >/dev/null
cmp "$TEST_ROOT/operator-original.md" "$agent_dir/operator-worker.md"

[[ -f "$sandboxed_generated" ]]
grep -q '^  bash: false$' "$sandboxed_generated"
grep -q '^aidevops_model_tier: thinking$' "$sandboxed_generated"
if grep -q '^model:' "$sandboxed_generated"; then
	printf '%s\n' 'FAIL: parallel generation pinned tier intent to a model' >&2
	exit 1
fi

[[ -f "$research_generated" ]]
grep -q '^  "\*": false$' "$research_generated"
grep -q '^  bash: false$' "$research_generated"
grep -q '^  external_directory: deny$' "$research_generated"

printf '%s\n' 'PASS: generated OpenCode subagents preserve guards, operator files and routing intent'
exit 0
