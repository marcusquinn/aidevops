#!/usr/bin/env bash
# shellcheck disable=SC1091
set -euo pipefail

# Test suite for entity-extraction.py (t1051.6)
# Validates regex extraction, frontmatter update, YAML output, and CLI behaviour.
#
# Usage: bash tests/test-entity-extraction.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)" || exit
EXTRACTOR="${REPO_DIR}/.agents/scripts/entity-extraction.py"
TEST_DIR="${SCRIPT_DIR}/entity-extraction-test-fixtures"
WORK_DIR=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0

setup() {
	WORK_DIR=$(mktemp -d)
	return 0
}

teardown() {
	if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
		rm -rf "$WORK_DIR"
	fi
	return 0
}

assert_json_has_key() {
	local json_output="$1"
	local key="$2"
	local description="$3"

	if echo "$json_output" | python3 -c "import sys,json; d=json.load(sys.stdin); assert '$key' in d" 2>/dev/null; then
		echo -e "  ${GREEN}PASS${NC}: $description"
		PASS=$((PASS + 1))
	else
		echo -e "  ${RED}FAIL${NC}: $description (key '$key' not found in JSON)"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

assert_json_key_contains() {
	local json_output="$1"
	local key="$2"
	local value="$3"
	local description="$4"

	if echo "$json_output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
items = d.get('$key', [])
assert any('$value' in item for item in items), f'$value not in {items}'
" 2>/dev/null; then
		echo -e "  ${GREEN}PASS${NC}: $description"
		PASS=$((PASS + 1))
	else
		echo -e "  ${RED}FAIL${NC}: $description ('$value' not found in '$key')"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

assert_json_empty() {
	local json_output="$1"
	local description="$2"

	if echo "$json_output" | python3 -c "import sys,json; d=json.load(sys.stdin); assert len(d) == 0" 2>/dev/null; then
		echo -e "  ${GREEN}PASS${NC}: $description"
		PASS=$((PASS + 1))
	else
		echo -e "  ${RED}FAIL${NC}: $description (expected empty JSON object)"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

assert_file_contains() {
	local file="$1"
	local pattern="$2"
	local description="$3"

	if grep -q "$pattern" "$file" 2>/dev/null; then
		echo -e "  ${GREEN}PASS${NC}: $description"
		PASS=$((PASS + 1))
	else
		echo -e "  ${RED}FAIL${NC}: $description (pattern '$pattern' not found in $file)"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

assert_file_not_contains() {
	local file="$1"
	local pattern="$2"
	local description="$3"

	if ! grep -q "$pattern" "$file" 2>/dev/null; then
		echo -e "  ${GREEN}PASS${NC}: $description"
		PASS=$((PASS + 1))
	else
		echo -e "  ${RED}FAIL${NC}: $description (pattern '$pattern' unexpectedly found in $file)"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

assert_exit_code() {
	local expected="$1"
	local actual="$2"
	local description="$3"

	if [[ "$actual" -eq "$expected" ]]; then
		echo -e "  ${GREEN}PASS${NC}: $description"
		PASS=$((PASS + 1))
	else
		echo -e "  ${RED}FAIL${NC}: $description (expected exit $expected, got $actual)"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test: CLI help
# ---------------------------------------------------------------------------
test_cli_help() {
	echo -e "\n${YELLOW}Test: CLI help output${NC}"

	local output
	output=$(python3 "$EXTRACTOR" --help 2>&1) || true
	assert_file_contains <(echo "$output") "method" "Help shows --method option"
	assert_file_contains <(echo "$output") "update-frontmatter" "Help shows --update-frontmatter option"
	assert_file_contains <(echo "$output") "json" "Help shows --json option"
	return 0
}

# ---------------------------------------------------------------------------
# Test: Regex date extraction
# ---------------------------------------------------------------------------
test_regex_date_extraction() {
	echo -e "\n${YELLOW}Test: Regex date extraction from date-formats fixture${NC}"

	local output
	output=$(python3 "$EXTRACTOR" "${TEST_DIR}/date-formats.md" --method regex 2>/dev/null)

	assert_json_has_key "$output" "dates" "Dates key present in output"
	assert_json_key_contains "$output" "dates" "15/01/2026" "Extracts DD/MM/YYYY format"
	assert_json_key_contains "$output" "dates" "2026-03-15" "Extracts YYYY-MM-DD format"
	assert_json_key_contains "$output" "dates" "28 Feb 2026" "Extracts DD Mon YYYY format"
	assert_json_key_contains "$output" "dates" "March 30, 2026" "Extracts Month DD, YYYY format"
	return 0
}

# ---------------------------------------------------------------------------
# Test: Regex people extraction from Name <email> patterns in body
# ---------------------------------------------------------------------------
test_regex_people_extraction() {
	echo -e "\n${YELLOW}Test: Regex people extraction from Name <email> patterns in body${NC}"

	# The regex extractor only finds Name <email> patterns in the body text.
	# The with-entities-frontmatter fixture has "Anna Williams <anna.williams@testcorp.com>" in body.
	local output
	output=$(python3 "$EXTRACTOR" "${TEST_DIR}/with-entities-frontmatter.md" --method regex 2>/dev/null)

	assert_json_has_key "$output" "people" "People key present in output"
	assert_json_key_contains "$output" "people" "Anna Williams" "Extracts 'Anna Williams' from body Name <email> pattern"
	return 0
}

# ---------------------------------------------------------------------------
# Test: Regex extraction from business email (dates)
# ---------------------------------------------------------------------------
test_regex_business_dates() {
	echo -e "\n${YELLOW}Test: Regex date extraction from business email${NC}"

	local output
	output=$(python3 "$EXTRACTOR" "${TEST_DIR}/business-email.md" --method regex 2>/dev/null)

	assert_json_has_key "$output" "dates" "Dates key present in business email"
	assert_json_key_contains "$output" "dates" "15 January 2026" "Extracts '15 January 2026'"
	assert_json_key_contains "$output" "dates" "10/01/2026" "Extracts '10/01/2026'"
	return 0
}

# ---------------------------------------------------------------------------
# Test: Empty body returns empty entities
# ---------------------------------------------------------------------------
test_empty_body() {
	echo -e "\n${YELLOW}Test: Empty body returns empty entities${NC}"

	local output
	# Capture only stdout (warnings go to stderr)
	output=$(python3 "$EXTRACTOR" "${TEST_DIR}/empty-body.md" --method regex 2>/dev/null)

	assert_json_empty "$output" "Empty body produces empty JSON"
	return 0
}

# ---------------------------------------------------------------------------
# Test: Minimal email with no extractable entities
# ---------------------------------------------------------------------------
test_minimal_email() {
	echo -e "\n${YELLOW}Test: Minimal email with few entities${NC}"

	local output
	output=$(python3 "$EXTRACTOR" "${TEST_DIR}/minimal-email.md" --method regex 2>/dev/null)

	# Minimal email has no dates or Name <email> patterns in body
	assert_json_empty "$output" "Minimal email produces empty or minimal JSON"
	return 0
}

# ---------------------------------------------------------------------------
# Test: JSON output format
# ---------------------------------------------------------------------------
test_json_output_format() {
	echo -e "\n${YELLOW}Test: JSON output format validation${NC}"

	local output
	output=$(python3 "$EXTRACTOR" "${TEST_DIR}/business-email.md" --method regex --json 2>/dev/null)

	# Validate it's valid JSON
	if echo "$output" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
		echo -e "  ${GREEN}PASS${NC}: Output is valid JSON"
		PASS=$((PASS + 1))
	else
		echo -e "  ${RED}FAIL${NC}: Output is not valid JSON"
		FAIL=$((FAIL + 1))
	fi

	# Validate entity types are from the expected set
	local valid
	valid=$(echo "$output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
valid_types = {'people', 'organisations', 'properties', 'locations', 'dates'}
for key in d:
    if key not in valid_types:
        print(f'INVALID: {key}')
        sys.exit(1)
print('OK')
" 2>&1) || true

	if [[ "$valid" == "OK" ]]; then
		echo -e "  ${GREEN}PASS${NC}: All entity types are valid"
		PASS=$((PASS + 1))
	else
		echo -e "  ${RED}FAIL${NC}: Invalid entity type found: $valid"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test: Frontmatter update
# ---------------------------------------------------------------------------
test_frontmatter_update() {
	echo -e "\n${YELLOW}Test: Frontmatter update with entities${NC}"

	# Copy fixture to work dir
	local work_file="${WORK_DIR}/business-email.md"
	cp "${TEST_DIR}/business-email.md" "$work_file"

	python3 "$EXTRACTOR" "$work_file" --method regex --update-frontmatter 2>/dev/null

	assert_file_contains "$work_file" "entities:" "Frontmatter contains entities: key"
	# Regex only extracts dates and Name <email> patterns from body.
	# Business email body has dates but no Name <email> patterns.
	assert_file_contains "$work_file" "dates:" "Frontmatter contains dates: section"
	# Verify the body is still intact
	assert_file_contains "$work_file" "Dear Jane" "Body text preserved after frontmatter update"
	assert_file_contains "$work_file" "Baker Street" "Body content preserved"
	return 0
}

# ---------------------------------------------------------------------------
# Test: Frontmatter update replaces existing entities
# ---------------------------------------------------------------------------
test_frontmatter_replace_existing() {
	echo -e "\n${YELLOW}Test: Frontmatter update replaces existing entities${NC}"

	local work_file="${WORK_DIR}/with-entities.md"
	cp "${TEST_DIR}/with-entities-frontmatter.md" "$work_file"

	python3 "$EXTRACTOR" "$work_file" --method regex --update-frontmatter 2>/dev/null

	# Old entities should be replaced
	assert_file_not_contains "$work_file" "Old Person" "Old person entity removed"
	assert_file_not_contains "$work_file" "Old Location" "Old location entity removed"
	# New entities should be present
	assert_file_contains "$work_file" "entities:" "New entities: key present"
	assert_file_contains "$work_file" "Anna Williams" "New person entity added"
	return 0
}

# ---------------------------------------------------------------------------
# Test: No frontmatter file
# ---------------------------------------------------------------------------
test_no_frontmatter_file() {
	echo -e "\n${YELLOW}Test: File without frontmatter (update-frontmatter should warn)${NC}"

	local work_file="${WORK_DIR}/no-frontmatter.md"
	cp "${TEST_DIR}/no-frontmatter.md" "$work_file"

	local exit_code=0
	python3 "$EXTRACTOR" "$work_file" --method regex --update-frontmatter 2>/dev/null || exit_code=$?

	assert_exit_code 1 "$exit_code" "Exit code 1 for file without frontmatter"
	return 0
}

# ---------------------------------------------------------------------------
# Test: Nonexistent file
# ---------------------------------------------------------------------------
test_nonexistent_file() {
	echo -e "\n${YELLOW}Test: Nonexistent file returns error${NC}"

	local exit_code=0
	python3 "$EXTRACTOR" "/nonexistent/file.md" --method regex 2>/dev/null || exit_code=$?

	assert_exit_code 1 "$exit_code" "Exit code 1 for nonexistent file"
	return 0
}

# ---------------------------------------------------------------------------
# Test: Auto method falls back to regex when spaCy/Ollama unavailable
# ---------------------------------------------------------------------------
test_auto_fallback() {
	echo -e "\n${YELLOW}Test: Auto method falls back gracefully${NC}"

	local output
	output=$(python3 "$EXTRACTOR" "${TEST_DIR}/business-email.md" --method auto 2>/dev/null)

	# Should still produce output (via regex fallback)
	if echo "$output" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
		echo -e "  ${GREEN}PASS${NC}: Auto method produces valid JSON (fell back to regex)"
		PASS=$((PASS + 1))
	else
		echo -e "  ${RED}FAIL${NC}: Auto method did not produce valid JSON"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test: YAML escape handles special characters
# ---------------------------------------------------------------------------
test_yaml_escape() {
	echo -e "\n${YELLOW}Test: YAML escape handles special characters${NC}"

	local output
	output=$(python3 -c "
import sys
sys.path.insert(0, '${REPO_DIR}/.agents/scripts')
import importlib.util
spec = importlib.util.spec_from_file_location('ee', '${EXTRACTOR}')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

# Test various special characters
tests = [
    ('simple', 'simple'),
    ('has: colon', '\"has: colon\"'),
    ('has # hash', '\"has # hash\"'),
    ('', '\"\"'),
]
for input_val, expected in tests:
    result = mod._yaml_escape_value(input_val)
    if result == expected:
        print(f'OK: {input_val!r} -> {result}')
    else:
        print(f'FAIL: {input_val!r} -> {result} (expected {expected})')
        sys.exit(1)
print('ALL_PASS')
" 2>&1)

	if echo "$output" | grep -q "ALL_PASS"; then
		echo -e "  ${GREEN}PASS${NC}: YAML escape handles special characters correctly"
		PASS=$((PASS + 1))
	else
		echo -e "  ${RED}FAIL${NC}: YAML escape failed: $output"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test: entities_to_yaml output format
# ---------------------------------------------------------------------------
test_entities_to_yaml() {
	echo -e "\n${YELLOW}Test: entities_to_yaml output format${NC}"

	local output
	output=$(python3 -c "
import sys
sys.path.insert(0, '${REPO_DIR}/.agents/scripts')
import importlib.util
spec = importlib.util.spec_from_file_location('ee', '${EXTRACTOR}')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

entities = {
    'people': ['John Smith', 'Jane Doe'],
    'organisations': ['Acme Corp'],
    'locations': ['London'],
    'dates': ['15 January 2026'],
}
yaml_out = mod.entities_to_yaml(entities)
print(yaml_out)
" 2>&1)

	assert_file_contains <(echo "$output") "entities:" "YAML output starts with entities:"
	assert_file_contains <(echo "$output") "people:" "YAML contains people section"
	assert_file_contains <(echo "$output") "John Smith" "YAML contains John Smith"
	assert_file_contains <(echo "$output") "organisations:" "YAML contains organisations section"
	assert_file_contains <(echo "$output") "Acme Corp" "YAML contains Acme Corp"
	assert_file_contains <(echo "$output") "locations:" "YAML contains locations section"
	assert_file_contains <(echo "$output") "dates:" "YAML contains dates section"
	return 0
}

# ---------------------------------------------------------------------------
# Test: Empty entities produces empty YAML
# ---------------------------------------------------------------------------
test_empty_entities_yaml() {
	echo -e "\n${YELLOW}Test: Empty entities produces empty YAML${NC}"

	local output
	output=$(python3 -c "
import sys
sys.path.insert(0, '${REPO_DIR}/.agents/scripts')
import importlib.util
spec = importlib.util.spec_from_file_location('ee', '${EXTRACTOR}')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

yaml_out = mod.entities_to_yaml({})
print(yaml_out)
" 2>&1)

	assert_file_contains <(echo "$output") "entities: {}" "Empty entities produces 'entities: {}'"
	return 0
}

# ---------------------------------------------------------------------------
# Test: Entity cleaning removes false positives
# ---------------------------------------------------------------------------
test_entity_cleaning() {
	echo -e "\n${YELLOW}Test: Entity cleaning removes false positives${NC}"

	local output
	output=$(python3 -c "
import sys
sys.path.insert(0, '${REPO_DIR}/.agents/scripts')
import importlib.util
spec = importlib.util.spec_from_file_location('ee', '${EXTRACTOR}')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

# Test false positive filtering
tests = [
    ('Re', 'people', ''),       # Common email prefix
    ('Fwd', 'people', ''),      # Forward prefix
    ('regards', 'people', ''),  # Salutation
    ('http', 'organisations', ''),  # URL fragment
    ('John Smith', 'people', 'John Smith'),  # Valid name
    ('x', 'people', ''),        # Too short
    ('**bold**', 'people', 'bold'),  # Markdown stripped
]
all_pass = True
for text, etype, expected in tests:
    result = mod._clean_entity(text, etype)
    if result == expected:
        print(f'OK: clean({text!r}, {etype}) -> {result!r}')
    else:
        print(f'FAIL: clean({text!r}, {etype}) -> {result!r} (expected {expected!r})')
        all_pass = False
if all_pass:
    print('ALL_PASS')
" 2>&1)

	if echo "$output" | grep -q "ALL_PASS"; then
		echo -e "  ${GREEN}PASS${NC}: Entity cleaning correctly filters false positives"
		PASS=$((PASS + 1))
	else
		echo -e "  ${RED}FAIL${NC}: Entity cleaning failed: $output"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test: extract_body strips frontmatter correctly
# ---------------------------------------------------------------------------
test_extract_body() {
	echo -e "\n${YELLOW}Test: extract_body strips frontmatter correctly${NC}"

	local output
	output=$(python3 -c "
import sys
sys.path.insert(0, '${REPO_DIR}/.agents/scripts')
import importlib.util
spec = importlib.util.spec_from_file_location('ee', '${EXTRACTOR}')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

# Test with frontmatter
content = '''---
title: Test
from: test@example.com
---

Hello world, this is the body.'''

body = mod.extract_body(content)
assert 'title' not in body, f'Frontmatter leaked into body: {body}'
assert 'Hello world' in body, f'Body text missing: {body}'
print('PASS_FM')

# Test without frontmatter
content2 = 'Just plain text, no frontmatter.'
body2 = mod.extract_body(content2)
assert body2 == content2, f'Plain text modified: {body2}'
print('PASS_PLAIN')

print('ALL_PASS')
" 2>&1)

	if echo "$output" | grep -q "ALL_PASS"; then
		echo -e "  ${GREEN}PASS${NC}: extract_body correctly strips frontmatter"
		PASS=$((PASS + 1))
	else
		echo -e "  ${RED}FAIL${NC}: extract_body failed: $output"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test: extract_frontmatter splits correctly
# ---------------------------------------------------------------------------
test_extract_frontmatter() {
	echo -e "\n${YELLOW}Test: extract_frontmatter splits content correctly${NC}"

	local output
	output=$(python3 -c "
import sys
sys.path.insert(0, '${REPO_DIR}/.agents/scripts')
import importlib.util
spec = importlib.util.spec_from_file_location('ee', '${EXTRACTOR}')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

content = '''---
title: Test
from: test@example.com
---

Body text here.'''

opener, fm, body = mod.extract_frontmatter(content)
assert opener == '---\n', f'Opener wrong: {opener!r}'
assert 'title: Test' in fm, f'Frontmatter missing title: {fm}'
assert 'Body text here.' in body, f'Body missing: {body}'
print('PASS_SPLIT')

# No frontmatter
opener2, fm2, body2 = mod.extract_frontmatter('No frontmatter here')
assert opener2 == '', f'Opener should be empty: {opener2!r}'
assert fm2 == '', f'FM should be empty: {fm2!r}'
assert body2 == 'No frontmatter here', f'Body wrong: {body2!r}'
print('PASS_NO_FM')

print('ALL_PASS')
" 2>&1)

	if echo "$output" | grep -q "ALL_PASS"; then
		echo -e "  ${GREEN}PASS${NC}: extract_frontmatter splits content correctly"
		PASS=$((PASS + 1))
	else
		echo -e "  ${RED}FAIL${NC}: extract_frontmatter failed: $output"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test: LLM response parsing handles edge cases
# ---------------------------------------------------------------------------
test_llm_response_parsing() {
	echo -e "\n${YELLOW}Test: LLM response parsing handles edge cases${NC}"

	local output
	output=$(python3 -c "
import sys
sys.path.insert(0, '${REPO_DIR}/.agents/scripts')
import importlib.util
spec = importlib.util.spec_from_file_location('ee', '${EXTRACTOR}')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

# Test: clean JSON
r1 = mod._parse_llm_response('{\"people\": [\"John\"], \"dates\": [\"2026-01-01\"]}')
assert r1.get('people') == ['John'], f'Clean JSON failed: {r1}'
print('OK: clean JSON')

# Test: JSON in markdown code block
r2 = mod._parse_llm_response('\`\`\`json\n{\"people\": [\"Jane\"]}\n\`\`\`')
assert r2.get('people') == ['Jane'], f'Code block JSON failed: {r2}'
print('OK: code block JSON')

# Test: JSON with preamble text
r3 = mod._parse_llm_response('Here are the entities:\n{\"locations\": [\"London\"]}')
assert r3.get('locations') == ['London'], f'Preamble JSON failed: {r3}'
print('OK: preamble JSON')

# Test: invalid JSON returns empty
r4 = mod._parse_llm_response('This is not JSON at all')
assert r4 == {}, f'Invalid JSON should return empty: {r4}'
print('OK: invalid JSON')

# Test: empty categories omitted
r5 = mod._parse_llm_response('{\"people\": [], \"dates\": [\"2026-01-01\"]}')
assert 'people' not in r5, f'Empty people should be omitted: {r5}'
assert r5.get('dates') == ['2026-01-01'], f'Dates missing: {r5}'
print('OK: empty categories omitted')

print('ALL_PASS')
" 2>&1)

	if echo "$output" | grep -q "ALL_PASS"; then
		echo -e "  ${GREEN}PASS${NC}: LLM response parsing handles edge cases"
		PASS=$((PASS + 1))
	else
		echo -e "  ${RED}FAIL${NC}: LLM response parsing failed: $output"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test: Integration — full pipeline regex extraction + frontmatter update
# ---------------------------------------------------------------------------
test_full_pipeline() {
	echo -e "\n${YELLOW}Test: Full pipeline — regex extraction + frontmatter update${NC}"

	local work_file="${WORK_DIR}/pipeline-test.md"
	cp "${TEST_DIR}/business-email.md" "$work_file"

	# Run extraction with frontmatter update
	local output
	output=$(python3 "$EXTRACTOR" "$work_file" --method regex --update-frontmatter 2>/dev/null)

	# Verify frontmatter was updated
	assert_file_contains "$work_file" "entities:" "Pipeline: entities key in frontmatter"

	# Verify the file is still valid markdown with frontmatter
	local fm_count
	fm_count=$(grep -c "^---$" "$work_file" || true)
	if [[ "$fm_count" -ge 2 ]]; then
		echo -e "  ${GREEN}PASS${NC}: Pipeline: file has valid frontmatter delimiters"
		PASS=$((PASS + 1))
	else
		echo -e "  ${RED}FAIL${NC}: Pipeline: file missing frontmatter delimiters (found $fm_count)"
		FAIL=$((FAIL + 1))
	fi

	# Verify body is preserved
	assert_file_contains "$work_file" "Dear Jane" "Pipeline: body text preserved"
	assert_file_contains "$work_file" "Best regards" "Pipeline: signature preserved"
	return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
	echo "============================================"
	echo "Entity Extraction Test Suite (t1051.6)"
	echo "============================================"

	# Check Python is available
	if ! command -v python3 &>/dev/null; then
		echo -e "${RED}ERROR${NC}: python3 not found"
		exit 1
	fi

	# Check extractor script exists
	if [[ ! -f "$EXTRACTOR" ]]; then
		echo -e "${RED}ERROR${NC}: entity-extraction.py not found at $EXTRACTOR"
		exit 1
	fi

	setup

	# Run tests
	test_cli_help
	test_regex_date_extraction
	test_regex_people_extraction
	test_regex_business_dates
	test_empty_body
	test_minimal_email
	test_json_output_format
	test_frontmatter_update
	test_frontmatter_replace_existing
	test_no_frontmatter_file
	test_nonexistent_file
	test_auto_fallback
	test_yaml_escape
	test_entities_to_yaml
	test_empty_entities_yaml
	test_entity_cleaning
	test_extract_body
	test_extract_frontmatter
	test_llm_response_parsing
	test_full_pipeline

	teardown

	# Summary
	echo ""
	echo "============================================"
	echo -e "Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}, ${YELLOW}${SKIP} skipped${NC}"
	echo "============================================"

	if [[ "$FAIL" -gt 0 ]]; then
		exit 1
	fi
	return 0
}

main "$@"
