#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression coverage for tracked env-template classification (GH#33339):
# safe .env templates must not be critical by filename alone, while templates
# carrying secrets and real env/key files remain critical and redacted.

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1

TESTS_RUN=0
TESTS_FAILED=0
SEVERITY_CRITICAL="critical"
SEVERITY_PASS="pass"
CAT_REPO_SECURITY="repo_security"

# shellcheck source=../security-posture-helper-repo.sh
source "${SCRIPTS_DIR}/security-posture-helper-repo.sh"

# Stubs replace the orchestrator's printers after sourcing.
CAPTURED_OUTPUT=""
CAPTURED_SEVERITY=""
print_crit() {
	local msg="$1"
	CAPTURED_OUTPUT="${CAPTURED_OUTPUT}${msg}"$'\n'
	return 0
}
print_pass() {
	local msg="$1"
	CAPTURED_OUTPUT="${CAPTURED_OUTPUT}${msg}"$'\n'
	return 0
}
print_info() {
	local msg="$1"
	CAPTURED_OUTPUT="${CAPTURED_OUTPUT}${msg}"$'\n'
	return 0
}
add_finding() {
	local severity="$1"
	local message="$3"
	CAPTURED_SEVERITY="$severity"
	CAPTURED_OUTPUT="${CAPTURED_OUTPUT}${message}"$'\n'
	return 0
}

pass() {
	local message="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf 'PASS: %s\n' "$message"
	return 0
}

fail() {
	local message="$1"
	local detail="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf 'FAIL: %s — %s\n' "$message" "$detail" >&2
	return 0
}

WORK_DIR=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK_DIR"' EXIT

# Build fake secrets from parts so this file never contains a literal token.
FAKE_GH_TOKEN="ghp""_$(printf 'a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5P6q7R8')"
FAKE_SECRET_VALUE="s3cr3tV4lu3-$(printf 'q9w8e7r6t5')"
# Well-known local default credential, assembled at runtime so secretlint's
# PostgreSQLConnection rule does not flag the fixture source (GH#33364).
LOCAL_DEFAULT_PG_USER="postgres"
FAKE_PEM_HEADER="-----BEGIN RSA ""PRIVATE KEY-----"

# Usage: run_case <description> <expected severity> <file name> <content> [reason]
run_case() {
	local description="$1"
	local expected="$2"
	local file_name="$3"
	local content="$4"
	local reason="${5:-}"
	local repo
	repo=$(mktemp -d "${WORK_DIR}/repo.XXXXXX") || return 1
	git -C "$repo" init -q
	mkdir -p "$(dirname "${repo}/${file_name}")"
	printf '%s\n' "$content" >"${repo}/${file_name}"
	git -C "$repo" add -- "$file_name"

	CAPTURED_OUTPUT=""
	CAPTURED_SEVERITY=""
	_check_tracked_secret_files "$repo"

	if [[ "$CAPTURED_SEVERITY" != "$expected" ]]; then
		fail "$description" "expected $expected, got ${CAPTURED_SEVERITY:-none}"
		return 0
	fi
	if [[ "$CAPTURED_OUTPUT" == *"$FAKE_GH_TOKEN"* || "$CAPTURED_OUTPUT" == *"$FAKE_SECRET_VALUE"* ]]; then
		fail "$description" "diagnostics leaked a secret value"
		return 0
	fi
	if [[ -n "$reason" && "$CAPTURED_OUTPUT" != *"(${reason}, line "* ]]; then
		fail "$description" "expected reason ${reason}; output: ${CAPTURED_OUTPUT}"
		return 0
	fi
	if [[ "$expected" == critical && "$CAPTURED_OUTPUT" != *"aidevops secret set <NAME>"* ]]; then
		fail "$description" "encrypted-secret remediation missing"
		return 0
	fi
	pass "$description"
	return 0
}

run_case "comments-only template is not critical" pass ".env.example" \
	"# Copy to .env and fill in values
# DATABASE_URL is required"

run_case "bare-variable template is not critical" pass ".env.example" \
	"API_KEY
DATABASE_URL
SECRET_TOKEN"

run_case "placeholder assignments are not critical" pass ".env.example" \
	"API_KEY=
STRIPE_SECRET_KEY=your-stripe-secret-key
GITHUB_TOKEN=<github-token>
DB_PASSWORD=\${DB_PASSWORD}
JWT_SECRET=changeme
DATABASE_URL=postgres://user:\${DB_PASSWORD}@db.example.internal/app
LOCAL_DB_URL=postgres://${LOCAL_DEFAULT_PG_USER}:${LOCAL_DEFAULT_PG_USER}@localhost:5432/app
PORT=3000
TOKEN_TTL=3600
AUTH_ENABLED=true"

run_case "nested production sample template is classified by content" pass ".env.production.sample" \
	"SESSION_SECRET="

run_case "named .template.env with empty values is not critical" pass "configs/meta.template.env" \
	"META_APP_SECRET=\"\"
META_ACCESS_TOKEN=\"\""

run_case "named .example.env carrying a secret stays critical" critical "app.example.env" \
	"API_TOKEN='${FAKE_SECRET_VALUE}'" secret-assignment

run_case "secret-named assignment with real value stays critical" critical ".env.example" \
	"APP_NAME=demo
API_SECRET=${FAKE_SECRET_VALUE}" secret-assignment

run_case "known token signature stays critical" critical ".env.example" \
	"# token: ${FAKE_GH_TOKEN}" token-signature

run_case "live-key prefix under a non-secret name stays critical" critical ".env.example" \
	"STRIPE=sk""_live_$(printf 'Z9y8X7w6V5u4T3s2')" token-signature

run_case "private key header stays critical" critical ".env.template" \
	"SIGNING_KEY=\"${FAKE_PEM_HEADER}\"" private-key

run_case "credential-bearing remote URL stays critical" critical ".env.example" \
	"DATABASE_URL=postgres://app:${FAKE_SECRET_VALUE}@db.prod.internal/app" credential-url

run_case "real .env remains critical by filename" critical ".env" \
	"PORT=3000"

run_case "real .env.local remains critical by filename" critical ".env.local" \
	"PORT=3000"

run_case "nested real .env.local is critical by filename" critical "app/.env.local" \
	"PORT=3000"

run_case "nested real .env.production is critical by filename" critical "app/.env.production" \
	"PORT=3000"

run_case "nested safe template is classified by content" pass "services/api/.env.example" \
	"API_KEY=
PORT=3000"

run_case "nested secret-bearing template is critical and redacted" critical "services/api/.env.example" \
	"DATABASE_URL=postgres://app:${FAKE_SECRET_VALUE}@db.prod.internal/app" credential-url

run_case "private key file remains critical by filename" critical "deploy.pem" \
	"placeholder"

if [[ "$CAPTURED_OUTPUT" == *"deploy.pem"* ]]; then
	pass "critical finding names the tracked path"
else
	fail "critical finding names the tracked path" "path missing from output"
fi

printf '\nTests: %d, failures: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi

exit 0
