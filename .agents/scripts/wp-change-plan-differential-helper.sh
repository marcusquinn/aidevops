#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Opt-in LocalWP fixture verification. Never use against a client/live site.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
source "$SCRIPT_DIR/shared-constants.sh"

usage() {
	cat <<'HELP'
Usage:
  wp-change-plan-differential-helper.sh create SITE --fixture --user ID [runtime flags]
  wp-change-plan-differential-helper.sh compare SITE ARTIFACTS --fixture --user ID [--base REF] [runtime flags]
  wp-change-plan-differential-helper.sh round SITE ARTIFACTS PLANNER_DIR --fixture --user ID [runtime flags]
  wp-change-plan-differential-helper.sh cleanup SITE ARTIFACTS --fixture --user ID [runtime flags]

SITE must have type=localwp and verification_fixture=true in wordpress-sites.json.
ARTIFACTS is the directory printed by create; retained on success AND failure.
Runtime: use wp on PATH from Local's site shell, or supply ALL four flags:
  --php PATH --php-ini PATH --wp-cli PATH --mysql-bin DIRECTORY
The latter runs Local's PHP/ini/wp-cli.phar with its MySQL clients on PATH.
compare defaults to origin/main; round runs one planner's dry/apply/restore cycle.
cleanup removes ONLY the created fixture after verifying its restored values.
HELP
	return 0
}

wp_run() {
	if [[ -n "$PHP_BIN" ]]; then
		PATH="$MYSQL_BIN:$PATH" "$PHP_BIN" -c "$PHP_INI" "$WP_CLI" --path="$SITE_PATH" --user="$WP_USER" --no-color "$@"
	else
		wp --path="$SITE_PATH" --user="$WP_USER" --no-color "$@"
	fi
	return $?
}

fixture() {
	local action="$1"
	wp_run eval-file "$ARTIFACTS/fixture.php" "$action" "$ARTIFACTS"
	return $?
}

write_fixture_tool() {
	cat >"$ARTIFACTS/fixture.php" <<'PHP'
<?php
// This generated tool touches only a uniquely named fixture, never existing content.
if ( is_multisite() || ! current_user_can( 'unfiltered_html' ) ) {
    WP_CLI::error( 'Requires a single-site fixture and a user with unfiltered_html.' );
}
list( $action, $dir ) = $args;
$file = $dir . '/fixture.json';
function checked( $value ) {
    if ( is_wp_error( $value ) || false === $value ) {
        WP_CLI::error( is_wp_error( $value ) ? $value->get_error_message() : 'Fixture operation failed' );
    }
    return $value;
}
function save_json( $path, $value ) {
    if ( false === file_put_contents( $path, wp_json_encode( $value, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES ) . "\n" ) ) {
        WP_CLI::error( 'Cannot save fixture artifact' );
    }
}
if ( 'create' === $action ) {
    if ( file_exists( $file ) ) { WP_CLI::error( 'Fixture already exists' ); }
    $token = 'wpcp-' . strtolower( wp_generate_password( 16, false, false ) );
    // Persist each created id immediately so a partial creation is recoverable.
    $data = array( 'token' => $token, 'post' => 0, 'slugs' => array(), 'complete' => false );
    save_json( $file, $data );
    foreach ( array( 'a', 'b', 'unused' ) as $suffix ) {
        $slug = $token . '-' . $suffix;
        $term = checked( wp_insert_term( $slug, 'category', array( 'slug' => $slug ) ) );
        $data['slugs'][] = $slug;
        save_json( $file, $data );
        checked( update_term_meta( $term['term_id'], 'wpcp_fixture', 'original' ) );
    }
    $data['post'] = checked( wp_insert_post( array( 'post_title' => 'Fixture original', 'post_name' => $token,
        'post_status' => 'draft', 'post_excerpt' => 'Original excerpt', 'post_content' => 'Original content' ), true ) );
    save_json( $file, $data );
    checked( wp_set_object_terms( $data['post'], array( $data['slugs'][0] ), 'category' ) );
    checked( update_post_meta( $data['post'], 'wpcp_fixture', 'original' ) );
    $data['complete'] = true;
    save_json( $file, $data );
}
$data = json_decode( file_get_contents( $file ), true );
if ( ! is_array( $data ) || ! preg_match( '/^wpcp-[a-z0-9]{16}$/D', $data['token'] ?? '' ) ) {
    WP_CLI::error( 'Invalid fixture manifest' );
}
$post = get_post( $data['post'] );
if ( $post && $post->post_name !== $data['token'] ) { WP_CLI::error( 'Fixture post identity differs; inspect artifacts' ); }
$terms = array();
foreach ( $data['slugs'] as $slug ) {
    if ( 0 !== strpos( $slug, $data['token'] . '-' ) ) { WP_CLI::error( 'Invalid fixture term identity' ); }
    $term = get_term_by( 'slug', $slug, 'category' );
    if ( ! $term && 'cleanup' === $action ) { continue; }
    if ( ! $term ) { WP_CLI::error( 'Fixture term missing; restore from retained backup before continuing' ); }
    $terms[] = $term;
}
if ( 'cleanup' === $action ) {
    // Normal cleanup must first pass the shell's snapshot check. Partial create
    // and interrupted cleanup can resume using the persisted identities only.
    if ( $data['complete'] && ! file_exists( $dir . '/cleanup.started' ) ) {
        WP_CLI::error( 'Complete fixtures require a verified starting snapshot before cleanup' );
    }
    foreach ( $terms as $term ) { checked( wp_delete_term( $term->term_id, 'category' ) ); }
    if ( $post ) { checked( wp_delete_post( $post->ID, true ) ); }
    return;
}
if ( ! $post ) { WP_CLI::error( 'Fixture post is missing; inspect artifacts' ); }
$snapshot = array( 'post' => array_intersect_key( (array) $post, array_flip( array(
    'post_title', 'post_name', 'post_status', 'post_excerpt', 'post_content', 'post_date', 'post_date_gmt' ) ) ),
    'meta' => get_post_meta( $post->ID, 'wpcp_fixture', false ),
    'categories' => checked( wp_get_object_terms( $post->ID, 'category', array( 'fields' => 'slugs', 'orderby' => 'slug' ) ) ),
    'terms' => array() );
foreach ( $terms as $term ) {
    $snapshot['terms'][] = array( 'slug' => $term->slug, 'name' => $term->name, 'description' => $term->description,
        'parent' => $term->parent, 'count' => $term->count, 'meta' => get_term_meta( $term->term_id, 'wpcp_fixture', false ) );
}
if ( 'create' === $action || 'snapshot' === $action ) { WP_CLI::line( wp_json_encode( $snapshot ) ); }
if ( 'plan' === $action ) {
    save_json( $dir . '/update.json', array( 'posts' => array( array( 'id' => $post->ID,
        'post' => array( 'post_title' => array( 'Fixture original', 'Fixture changed & checked' ),
            'post_excerpt' => array( 'Original excerpt', 'Changed excerpt' ) ),
        'meta' => array( 'wpcp_fixture' => array( 'original', 'changed' ) ),
        'terms' => array( 'category' => array( array( $data['slugs'][0] ), array( $data['slugs'][1] ) ) ) ) ),
        'terms' => array( array( 'taxonomy' => 'category', 'id' => $terms[1]->term_id,
            'term' => array( 'name' => array( $terms[1]->name, 'Changed & checked' ), 'description' => array( '', '<strong>Changed</strong>' ) ),
            'meta' => array( 'wpcp_fixture' => array( 'original', 'changed' ) ) ) ) ) );
    save_json( $dir . '/delete.json', array( 'delete_terms' => array( array(
        'taxonomy' => 'category', 'id' => $terms[2]->term_id, 'slug' => $terms[2]->slug ) ) ) );
}
PHP
	return 0
}

verify_snapshot() {
	local destination="$1"
	fixture snapshot >"$destination" || return 1
	diff -u "$ARTIFACTS/starting.json" "$destination"
	return $?
}

# Even a failed apply may have written values: always try its emitted backup.
run_plan() {
	local planner="$1"
	local plan="$2"
	local prefix="$3"
	local rc=0 backup=""
	wp_run eval-file "$planner/wp-change-plan.php" "$plan" >"$prefix.dry.log" 2>&1 || return 1
	wp_run eval-file "$planner/wp-change-plan.php" "$plan" apply >"$prefix.apply.log" 2>&1 || rc=1
	backup=$(sed -n 's/^BACKUP: //p' "$prefix.apply.log" | tail -n 1)
	if [[ -n "$backup" && -f "$backup" ]]; then
		wp_run eval-file "$planner/wp-change-plan.php" "$plan" restore "$backup" >"$prefix.restore.log" 2>&1 || rc=1
	else
		print_error "No readable backup; inspect $prefix.apply.log before continuing"
		rc=1
	fi
	return "$rc"
}

run_round() {
	local planner="$1"
	local output="$2"
	local rc=0 plan
	verify_snapshot "$output.before.json" || return 1
	fixture plan || return 1
	for plan in update delete; do
		run_plan "$planner" "$ARTIFACTS/$plan.json" "$output.$plan" || rc=1
		verify_snapshot "$output.$plan.after.json" || rc=1
		[[ "$rc" -eq 0 ]] || break
	done
	return "$rc"
}

compare_versions() {
	local repo file relative comparison
	repo=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel) || return 1
	[[ "$BASE_REF" != -* ]] || return 1
	git -C "$repo" rev-parse --verify "${BASE_REF}^{commit}" >/dev/null || return 1
	comparison=$(mktemp -d "$ARTIFACTS/compare.XXXXXX") || return 1
	print_info "Comparison artifacts: $comparison"
	mkdir "$comparison/base" "$comparison/current" || return 1
	while IFS= read -r relative; do
		case "$relative" in
		.agents/scripts/wp-change-plan*.php)
			git -C "$repo" show "$BASE_REF:$relative" >"$comparison/base/${relative##*/}" || return 1
			;;
		esac
	done < <(git -C "$repo" ls-tree -r --name-only "$BASE_REF" -- .agents/scripts)
	for file in "$SCRIPT_DIR"/wp-change-plan*.php; do
		cp "$file" "$comparison/current/" || return 1
	done
	printf '%s\n' "$(git -C "$repo" rev-parse "$BASE_REF")" >"$comparison/base-ref.txt"
	run_round "$comparison/base" "$comparison/base-round" || return 1
	run_round "$comparison/current" "$comparison/current-round" || return 1
	# Normalise only volatile paths and term identity labels, never change counts,
	# field values or statuses. Snapshots independently check restored term values.
	python3 - "$comparison" <<'PY' || return 1
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
for version in ('base', 'current'):
    lines = []
    for plan in ('update', 'delete'):
        for phase in ('dry', 'apply', 'restore'):
            text = (root / f'{version}-round.{plan}.{phase}.log').read_text()
            text = text.replace(str(root / version / 'wp-change-plan.php'), '<PLANNER>')
            text = re.sub(r'(?m)^BACKUP: .*$', 'BACKUP: <BACKUP>', text)
            text = re.sub(r'\S*/before-[^\s]+\.json', '<BACKUP>', text)
            text = re.sub(r'(term category |as term |references to )\d+', r'\1<ID>', text)
            lines.append(f'== {plan} {phase} ==\n{text}')
    (root / f'{version}.normalised.log').write_text(''.join(lines))
PY
	diff -u "$comparison/base.normalised.log" "$comparison/current.normalised.log" || return 1
	print_success "No planner differences; fixture values restored. Artifacts: $comparison"
	return 0
}

main() {
	local command="${1:-help}"
	[[ "$command" != help && "$command" != --help ]] || {
		usage
		return 0
	}
	case "$command" in
	create | compare | round | cleanup) ;;
	*)
		usage
		return 1
		;;
	esac
	# Reject CI before reading configuration or invoking ANY WordPress command.
	if [[ -n "${CI:-}${GITHUB_ACTIONS:-}${GITLAB_CI:-}${JENKINS_URL:-}${BUILD_BUILDID:-}${CIRCLECI:-}" ]]; then
		print_error 'Differential verification is forbidden in CI'
		return 1
	fi
	shift
	local site="${1:-}" marked=0 runtime_flags=0
	[[ -n "$site" ]] || {
		usage
		return 1
	}
	shift
	ARTIFACTS=""
	PLANNER=""
	BASE_REF="origin/main"
	PHP_BIN=""
	PHP_INI=""
	WP_CLI=""
	MYSQL_BIN=""
	WP_USER=""
	if [[ "$command" != create ]]; then
		ARTIFACTS="${1:-}"
		[[ -n "$ARTIFACTS" ]] || {
			usage
			return 1
		}
		shift
	fi
	if [[ "$command" == round ]]; then
		PLANNER="${1:-}"
		[[ -d "$PLANNER" ]] || {
			usage
			return 1
		}
		PLANNER=$(cd "$PLANNER" && pwd)
		shift
	fi
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--fixture)
			marked=1
			shift
			continue
			;;
		--user | --base | --php | --php-ini | --wp-cli | --mysql-bin)
			local value="${2:-}"
			[[ $# -ge 2 && -n "$value" ]] || {
				print_error "Missing value: $arg"
				return 1
			}
			case "$arg" in
			--user) WP_USER="$value" ;;
			--base) BASE_REF="$value" ;;
			--php)
				PHP_BIN="$value"
				runtime_flags=$((runtime_flags + 1))
				;;
			--php-ini)
				PHP_INI="$value"
				runtime_flags=$((runtime_flags + 1))
				;;
			--wp-cli)
				WP_CLI="$value"
				runtime_flags=$((runtime_flags + 1))
				;;
			--mysql-bin)
				MYSQL_BIN="$value"
				runtime_flags=$((runtime_flags + 1))
				;;
			esac
			shift 2
			;;
		*)
			print_error "Unknown option: $arg"
			return 1
			;;
		esac
	done
	[[ "$marked" -eq 1 && -n "$WP_USER" ]] || {
		print_error 'Requires --fixture and --user'
		return 1
	}
	local config="$HOME/.config/aidevops/wordpress-sites.json"
	# Project only the selected site's allowed fields; never print registries.
	SITE_PATH=$(jq -er --arg site "$site" '.sites[$site] | select(.type == "localwp" and .verification_fixture == true) | .path | select(type == "string" and length > 0)' "$config") || {
		print_error 'Requires a configured localwp site marked verification_fixture=true'
		return 1
	}
	SITE_PATH="${SITE_PATH/#\~/$HOME}"
	[[ -d "$SITE_PATH" ]] || {
		print_error 'LocalWP site path is missing'
		return 1
	}
	SITE_PATH=$(cd "$SITE_PATH" && pwd)
	if [[ "$runtime_flags" -ne 0 ]]; then
		[[ "$runtime_flags" -eq 4 && -x "$PHP_BIN" && -f "$PHP_INI" && -f "$WP_CLI" && -d "$MYSQL_BIN" ]] || {
			print_error 'Supply all four valid Local runtime paths'
			return 1
		}
	else
		command -v wp >/dev/null || {
			print_error 'Run from a Local site shell or supply all four runtime flags'
			return 1
		}
	fi
	local root="${AIDEVOPS_TEMP_DIR:-$HOME/.aidevops/.agent-workspace/tmp}"
	mkdir -p "$root"
	root=$(cd "$root" && pwd)
	umask 077
	if [[ "$command" == create ]]; then
		ARTIFACTS=$(mktemp -d "$root/wp-change-plan-differential.XXXXXX")
		printf '%s\n' "$SITE_PATH" >"$ARTIFACTS/site-path.txt"
		write_fixture_tool
		fixture create >"$ARTIFACTS/starting.json" || {
			print_error "Partial fixture retained: $ARTIFACTS"
			return 1
		}
		printf 'ARTIFACTS: %s\n' "$ARTIFACTS"
		return 0
	fi
	[[ -d "$ARTIFACTS" ]] || {
		print_error 'Artifact directory is missing'
		return 1
	}
	ARTIFACTS=$(cd "$ARTIFACTS" && pwd)
	[[ "$ARTIFACTS" == "$root"/wp-change-plan-differential.* && -f "$ARTIFACTS/starting.json" && "$(<"$ARTIFACTS/site-path.txt")" == "$SITE_PATH" ]] || {
		print_error 'Artifact directory does not belong to this fixture site'
		return 1
	}
	case "$command" in
	compare)
		command -v python3 >/dev/null || return 1
		compare_versions
		;;
	round) run_round "$PLANNER" "$ARTIFACTS/round-$(date -u +%Y%m%dT%H%M%SZ)-$$" ;;
	cleanup)
		if [[ ! -f "$ARTIFACTS/cleanup.started" ]] && ! jq -e '.complete == false' "$ARTIFACTS/fixture.json" >/dev/null; then
			verify_snapshot "$ARTIFACTS/cleanup.before.json" || return 1
			printf 'Starting snapshot verified\n' >"$ARTIFACTS/cleanup.started"
		fi
		fixture cleanup
		;;
	*)
		usage
		return 1
		;;
	esac
	return $?
}

main "$@"
