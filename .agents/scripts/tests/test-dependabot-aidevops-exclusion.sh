#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for dependabot-aidevops-exclusion.py (GH#36723). Fixtures mirror the
# dependabot.yml layouts observed across managed repositories.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRANSFORM="$SCRIPT_DIR/../dependabot-aidevops-exclusion.py"

PASS=0
FAIL=0

_pass() {
	local description="$1"
	printf 'PASS %s\n' "$description"
	PASS=$((PASS + 1))
	return 0
}

_fail() {
	local description="$1"
	local detail="$2"
	printf 'FAIL %s: %s\n' "$description" "$detail" >&2
	FAIL=$((FAIL + 1))
	return 0
}

assert_eq() {
	local description="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$actual" == "$expected" ]]; then
		_pass "$description"
	else
		_fail "$description" "expected '${expected}', got '${actual}'"
	fi
	return 0
}

tmp_dir=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp_dir"' EXIT

_classify() {
	local fixture="$1"
	python3 "$TRANSFORM" classify <"$fixture"
	return 0
}

# Assert a patch succeeds, only inserts lines, converges, and (when Ruby is
# available) parses with the exclusion in every github-actions entry while
# every other entry is unchanged.
assert_patch() {
	local name="$1"
	local fixture="$tmp_dir/${name}.yml"
	local patched="$tmp_dir/${name}.patched.yml"
	local rc=0
	python3 "$TRANSFORM" patch <"$fixture" >"$patched" || rc=$?
	assert_eq "${name}: patch exit" "0" "$rc"
	# awk 1 normalises a missing final newline so only real removals count.
	local removed added
	removed=$(diff <(awk 1 "$fixture") <(awk 1 "$patched") | grep -c '^<' || true)
	added=$(diff <(awk 1 "$fixture") <(awk 1 "$patched") | grep -c '^>' || true)
	assert_eq "${name}: insert-only (no removed lines)" "0" "$removed"
	if [[ "$added" -gt 0 ]]; then
		_pass "${name}: lines inserted"
	else
		_fail "${name}: lines inserted" "patch inserted nothing"
	fi
	assert_eq "${name}: patched classifies EXCLUDED" "EXCLUDED" "$(_classify "$patched")"
	rc=0
	python3 "$TRANSFORM" patch <"$patched" >"$tmp_dir/${name}.again.yml" || rc=$?
	assert_eq "${name}: second patch is a no-op" "3" "$rc"
	if ! command -v ruby >/dev/null 2>&1; then
		printf 'SKIP %s: ruby unavailable for semantic YAML check\n' "$name"
		return 0
	fi
	if ruby -ryaml -e '
		before = YAML.load_file(ARGV[0])["updates"]
		after = YAML.load_file(ARGV[1])["updates"]
		exit 1 unless before.length == after.length
		before.zip(after).each do |b, a|
			if b["package-ecosystem"] == "github-actions"
				names = (a["ignore"] || []).map { |e| e["dependency-name"] }
				exit 1 unless names.include?("marcusquinn/aidevops*")
				exit 1 unless (b["ignore"] || []).all? { |e| a["ignore"].include?(e) }
				exit 1 unless b.reject { |k, _| k == "ignore" } == a.reject { |k, _| k == "ignore" }
			else
				exit 1 unless b == a
			end
		end
	' "$fixture" "$patched"; then
		_pass "${name}: YAML semantics"
	else
		_fail "${name}: YAML semantics" "patched YAML does not match expected structure"
	fi
	return 0
}

# 1. Quoted values, comments, actions first (turbostarter-plus layout).
cat >"$tmp_dir/quoted.yml" <<'EOF'
version: 2

updates:
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "weekly"
    # Dependabot does not support cooldown/delay keys; keep this schema-native.
    commit-message:
      prefix: "chore(deps):"
    labels:
      - "dependencies"

  - package-ecosystem: "npm"
    directory: "/"
    schedule:
      interval: "weekly"
    open-pull-requests-limit: 0
EOF
assert_eq "quoted: classify" "MISSING" "$(_classify "$tmp_dir/quoted.yml")"
assert_patch quoted

# 2. Docker first, actions last at EOF without trailing newline.
printf '%s' 'version: 2
updates:
  - package-ecosystem: docker
    directory: /
    schedule:
      interval: weekly
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
    commit-message:
      prefix: "chore(deps):"' >"$tmp_dir/eof.yml"
assert_patch eof

# 3. Already excluded (wpallstars starter layout).
cat >"$tmp_dir/excluded.yml" <<'EOF'
version: 2
updates:
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
    groups:
      actions:
        patterns: ["*"]
    ignore:
      - dependency-name: "marcusquinn/aidevops*"
EOF
assert_eq "excluded: classify" "EXCLUDED" "$(_classify "$tmp_dir/excluded.yml")"
rc=0
python3 "$TRANSFORM" patch <"$tmp_dir/excluded.yml" >"$tmp_dir/excluded.out" || rc=$?
assert_eq "excluded: patch exit" "3" "$rc"
assert_eq "excluded: patch output unchanged" "" "$(diff "$tmp_dir/excluded.yml" "$tmp_dir/excluded.out")"

# 4. Existing ignore list with a version-restricted entry (aidevops layout):
#    the restricted entry is not an exclusion; append to the same list.
cat >"$tmp_dir/existing-ignore.yml" <<'EOF'
version: 2
updates:
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
    ignore:
      - dependency-name: "qltysh/qlty-action"
        versions:
          - "2.3.0"
    groups:
      actions:
        patterns:
          - "*"
    open-pull-requests-limit: 5
EOF
assert_eq "existing-ignore: classify" "MISSING" "$(_classify "$tmp_dir/existing-ignore.yml")"
assert_patch existing-ignore
assert_eq "existing-ignore: single ignore key" "1" "$(grep -c '^    ignore:' "$tmp_dir/existing-ignore.patched.yml")"

# 5. Ignore entries at key indent, items at column 0, two actions directories.
cat >"$tmp_dir/compact.yml" <<'EOF'
version: 2
updates:
- package-ecosystem: github-actions
  directory: /
  schedule:
    interval: weekly
  ignore:
  - dependency-name: "actions/checkout"
    update-types: ["version-update:semver-major"]
- package-ecosystem: github-actions
  directory: /sub
  schedule:
    interval: weekly
EOF
assert_patch compact
assert_eq "compact: both entries excluded" "2" "$(grep -c 'marcusquinn/aidevops\*' "$tmp_dir/compact.patched.yml")"

# 6. Wildcard covering everything already excludes aidevops.
cat >"$tmp_dir/wildcard.yml" <<'EOF'
version: 2
updates:
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
    ignore:
      - dependency-name: "*"
EOF
assert_eq "wildcard: classify" "EXCLUDED" "$(_classify "$tmp_dir/wildcard.yml")"

# 7. No github-actions ecosystem.
cat >"$tmp_dir/composer.yml" <<'EOF'
version: 2
updates:
  - package-ecosystem: composer
    directory: /
    schedule:
      interval: monthly
EOF
assert_eq "composer: classify" "NO-ACTIONS" "$(_classify "$tmp_dir/composer.yml")"
rc=0
python3 "$TRANSFORM" patch <"$tmp_dir/composer.yml" >/dev/null 2>&1 || rc=$?
assert_eq "composer: patch exit" "4" "$rc"

# 8. Flow-style ignore is reported, never guessed.
cat >"$tmp_dir/flow.yml" <<'EOF'
version: 2
updates:
  - package-ecosystem: github-actions
    directory: /
    schedule: {interval: weekly}
    ignore: [{dependency-name: "actions/cache"}]
EOF
assert_eq "flow: classify" "UNSUPPORTED:ignore-not-block-list" "$(_classify "$tmp_dir/flow.yml")"
rc=0
python3 "$TRANSFORM" patch <"$tmp_dir/flow.yml" >/dev/null 2>&1 || rc=$?
assert_eq "flow: patch exit" "5" "$rc"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
