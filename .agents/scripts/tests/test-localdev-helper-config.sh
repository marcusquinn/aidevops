#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression coverage for generated localdev proxy and certificate configuration.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
INIT_LIB="$REPO_ROOT/.agents/scripts/localdev-helper-init.sh"
PORTS_LIB="$REPO_ROOT/.agents/scripts/localdev-helper-ports.sh"
ROUTES_LIB="$REPO_ROOT/.agents/scripts/localdev-helper-routes.sh"
TEST_TMP_BASE="${AIDEVOPS_TEMP_DIR:-${TMPDIR:-/tmp}}"
mkdir -p "$TEST_TMP_BASE"
TEST_ROOT="$(mktemp -d "$TEST_TMP_BASE/localdev-helper-config.XXXXXX")"
PASS=0
FAIL=0

record_pass() {
	local description="$1"
	printf 'PASS: %s\n' "$description"
	PASS=$((PASS + 1))
	return 0
}

record_fail() {
	local description="$1"
	printf 'FAIL: %s\n' "$description" >&2
	FAIL=$((FAIL + 1))
	return 0
}

assert_file_contains() {
	local description="$1"
	local file="$2"
	local text="$3"
	if grep -Fq -- "$text" "$file"; then
		record_pass "$description"
	else
		record_fail "$description"
	fi
	return 0
}

assert_file_excludes() {
	local description="$1"
	local file="$2"
	local text="$3"
	if grep -Fq -- "$text" "$file"; then
		record_fail "$description"
	else
		record_pass "$description"
	fi
	return 0
}

assert_file_exists() {
	local description="$1"
	local file="$2"
	if [[ -f "$file" ]]; then
		record_pass "$description"
	else
		record_fail "$description"
	fi
	return 0
}

cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}

print_error() {
	printf 'ERROR: %s\n' "$*" >&2
	return 0
}

print_info() {
	printf 'INFO: %s\n' "$*"
	return 0
}

print_success() {
	printf 'SUCCESS: %s\n' "$*"
	return 0
}

print_warning() {
	printf 'WARNING: %s\n' "$*" >&2
	return 0
}

detect_brew_prefix() {
	return 0
}

trap cleanup EXIT
export LOCALDEV_DIR="$TEST_ROOT/localdev"
export CONFD_DIR="$LOCALDEV_DIR/conf.d"
export CERTS_DIR="$TEST_ROOT/certs"
export TRAEFIK_STATIC="$LOCALDEV_DIR/traefik.yml"
export DOCKER_COMPOSE="$LOCALDEV_DIR/docker-compose.yml"
export BACKUP_DIR="$LOCALDEV_DIR/backup"
mkdir -p "$CONFD_DIR" "$CERTS_DIR" "$BACKUP_DIR" "$TEST_ROOT/bin"

# shellcheck source=/dev/null
source "$INIT_LIB"
# shellcheck source=/dev/null
source "$PORTS_LIB"
# shellcheck source=/dev/null
source "$ROUTES_LIB"

create_traefik_route sample 3210 >/dev/null
route_file="$CONFD_DIR/sample.yml"
assert_file_contains "base route uses an exact host" "$route_file" "rule: \"Host(\`sample.local\`)\""
assert_file_excludes "base route omits invalid wildcard Host matcher" "$route_file" '*.sample.local'

write_traefik_static
assert_file_contains "static config enables the file provider" "$TRAEFIK_STATIC" '  file:'
assert_file_excludes "static config omits the Docker provider" "$TRAEFIK_STATIC" '  docker:'
assert_file_excludes "static config omits exposedByDefault" "$TRAEFIK_STATIC" 'exposedByDefault'

write_docker_compose
assert_file_contains "Compose mounts file-provider routes" "$DOCKER_COMPOSE" './conf.d:/etc/traefik/conf.d:ro'
assert_file_excludes "Compose does not mount the Docker socket" "$DOCKER_COMPOSE" '/var/run/docker.sock'

mkcert_log="$TEST_ROOT/mkcert.log"
cat >"$TEST_ROOT/bin/mkcert" <<'MKCERT'
#!/usr/bin/env bash
printf '%s|%s|%s\n' "${XDG_DATA_HOME:-}" "${CAROOT:-}" "$*" >>"$MKCERT_LOG"
case "${1:-}" in
-*) ;;
*)
	touch "${1}+1.pem" "${1}+1-key.pem"
	;;
esac
exit 0
MKCERT
chmod +x "$TEST_ROOT/bin/mkcert"
export MKCERT_LOG="$mkcert_log"
export PATH="$TEST_ROOT/bin:$PATH"
hash -r

export XDG_DATA_HOME="$TEST_ROOT/session-data"
unset CAROOT
run_stable_mkcert -CAROOT
assert_file_contains "mkcert ignores session-scoped XDG data" "$mkcert_log" '||-CAROOT'

export CAROOT="$TEST_ROOT/explicit-ca"
run_stable_mkcert -CAROOT
assert_file_contains "mkcert preserves an explicit CAROOT" "$mkcert_log" "|$CAROOT|-CAROOT"

unset CAROOT
ensure_mkcert >/dev/null
assert_file_contains "init reconciles trust when mkcert already exists" "$mkcert_log" '||-install'

generate_cert sample >/dev/null
assert_file_exists "stable mkcert creates the certificate" "$CERTS_DIR/sample.local+1.pem"
assert_file_exists "stable mkcert creates the private key" "$CERTS_DIR/sample.local+1-key.pem"
assert_file_contains "certificate generation ignores session XDG data" "$mkcert_log" '||sample.local *.sample.local'

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
