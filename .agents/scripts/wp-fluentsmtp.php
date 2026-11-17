<?php
/**
 * FluentSMTP Amazon SES connections over WP-CLI: list, migrate, test, undo (GH#38865).
 *
 * SPDX-License-Identifier: MIT
 * SPDX-FileCopyrightText: 2026 Marcus Quinn
 *
 * Run from the WordPress root (add --url=<blog> on multisite):
 *   wp eval-file wp-fluentsmtp.php list
 *   wp eval-file wp-fluentsmtp.php migrate domain=NEW region=R [from_domain=OLD] [dry_run=1] < keys.json
 *   wp eval-file wp-fluentsmtp.php test to=ADDR [from=ADDR] [lift_http_block=1]
 *   wp eval-file wp-fluentsmtp.php backups
 *   wp eval-file wp-fluentsmtp.php undo backup=DIR
 *
 * migrate reads {"access_key": ..., "secret_key": ...} JSON on STDIN, never argv
 * (wp-fluentsmtp-migrate.php, with -config.php and -remap.php); backups and undo
 * live in wp-fluentsmtp-backup.php.
 * Key values are never printed. Upload this file with its siblings.
 *
 * Prints JSON. Exit codes: 0 done, 1 refused or not confirmed, 2 usage error
 * or FluentSMTP unavailable. Workflow: .agents/services/email/ses.md "FluentSMTP".
 *
 * @package aidevops
 */

if ( ! defined( 'ABSPATH' ) || ! class_exists( 'WP_CLI' ) ) {
	fwrite( STDERR, "Run through WP-CLI: wp eval-file wp-fluentsmtp.php ACTION [key=value ...]\n" );
	exit( 2 );
}

require_once __DIR__ . '/wp-fluentsmtp-store.php';
require_once __DIR__ . '/wp-fluentsmtp-config.php';
require_once __DIR__ . '/wp-fluentsmtp-remap.php';
require_once __DIR__ . '/wp-fluentsmtp-migrate.php';
require_once __DIR__ . '/wp-fluentsmtp-backup.php';

if ( ! class_exists( 'WPFS_Cli' ) ) {

	/**
	 * Parses arguments and runs one action.
	 */
	final class WPFS_Cli {

		const DOMAIN   = '/^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/';
		const REQUIRED = array(
			'list'    => array(),
			'migrate' => array( 'domain', 'region' ),
			'test'    => array( 'to' ),
			'backups' => array(),
			'undo'    => array( 'backup' ),
		);
		const HANDLERS = array(
			'list'    => array( 'WPFS_Cli', 'action_list' ),
			'migrate' => array( 'WPFS_Migrate', 'run' ),
			'test'    => array( 'WPFS_Cli', 'action_test' ),
			'backups' => array( 'WPFS_Backup', 'all' ),
			'undo'    => array( 'WPFS_Backup', 'undo' ),
		);
		const PATTERNS = array(
			'domain'      => self::DOMAIN,
			'from_domain' => self::DOMAIN,
			'region'      => '/^[a-z]{2}(-[a-z]+)+-\d$/',
		);

		/**
		 * Entry point for `wp eval-file`.
		 *
		 * @param array $args Positional arguments after the script path.
		 * @return int Exit code.
		 */
		public static function main( array $args ) {
			try {
				$action  = (string) array_shift( $args );
				$options = self::parse_options( $action, $args );
				if ( ! function_exists( 'fluentMailGetSettings' ) || ! function_exists( 'fluentMailSetSettings' ) ) {
					throw new WPFS_Error( 'FluentSMTP is not active here; on multisite pass --url for the blog that runs it', 2 );
				}
				self::emit( call_user_func( self::HANDLERS[ $action ], $options ) );
				return 0;
			} catch ( WPFS_Error $error ) {
				fwrite( STDERR, 'ERROR: ' . $error->getMessage() . "\n" );
				return (int) $error->getCode();
			} catch ( Throwable $error ) {
				fwrite( STDERR, 'ERROR: FluentSMTP operation failed: ' . $error->getMessage() . "\n" );
				return 1;
			}
		}

		/**
		 * Parse key=value options, require the action's keys and validate values.
		 *
		 * @param string $action Action name.
		 * @param array  $args   Remaining arguments.
		 * @return array Options.
		 * @throws WPFS_Error On usage errors.
		 */
		private static function parse_options( $action, array $args ) {
			if ( ! isset( self::REQUIRED[ $action ] ) ) {
				throw new WPFS_Error( 'Unknown action: ' . ( '' === $action ? '<none>' : $action ) . ' (list|migrate|test|backups|undo)', 2 );
			}
			$options = array();
			foreach ( $args as $arg ) {
				$pair = explode( '=', (string) $arg, 2 );
				if ( 2 !== count( $pair ) || '' === $pair[1] ) {
					throw new WPFS_Error( 'Expected key=value, got: ' . $arg, 2 );
				}
				$options[ $pair[0] ] = $pair[1];
			}
			$missing = array_diff( self::REQUIRED[ $action ], array_keys( $options ) );
			if ( $missing ) {
				throw new WPFS_Error( $action . ' needs ' . reset( $missing ) . '=...', 2 );
			}
			self::validate( $options );
			return $options;
		}

		/**
		 * Reject malformed domains, regions and addresses.
		 *
		 * @param array $options Parsed options.
		 * @throws WPFS_Error On an invalid value.
		 */
		private static function validate( array $options ) {
			foreach ( self::PATTERNS as $key => $pattern ) {
				if ( isset( $options[ $key ] ) && ! preg_match( $pattern, $options[ $key ] ) ) {
					throw new WPFS_Error( $key . ' is not valid: ' . $options[ $key ], 2 );
				}
			}
			foreach ( array( 'to', 'from' ) as $key ) {
				if ( isset( $options[ $key ] ) && ! is_email( $options[ $key ] ) ) {
					throw new WPFS_Error( $key . ' must be one email address', 2 );
				}
			}
		}

		/**
		 * Connections with their key state, never their keys.
		 *
		 * @return array
		 */
		public static function action_list() {
			$settings = WPFS_Store::settings();
			$mappings = WPFS_Store::section( $settings, 'mappings' );
			$misc     = WPFS_Store::section( $settings, 'misc' );
			$refs     = array(
				'mappings' => $mappings,
				'default'  => WPFS_Store::field( $misc, 'default_connection' ),
				'fallback' => WPFS_Store::field( $misc, 'fallback_connection' ),
			);
			$rows     = array();
			foreach ( WPFS_Store::section( $settings, 'connections' ) as $key => $connection ) {
				$rows[] = self::list_row( (string) $key, WPFS_Store::provider( $connection ), $refs );
			}
			return array(
				'connections' => $rows,
				'defaults'    => count( array_filter( wp_list_pluck( $rows, 'default' ) ) ),
				'option'      => false === WPFS_Store::raw_option() ? 'absent' : 'present',
			);
		}

		/**
		 * One connection's summary row.
		 *
		 * @param string $key      Connection key.
		 * @param array  $provider Provider settings.
		 * @param array  $refs     mappings (sender => key), default and fallback keys.
		 * @return array
		 */
		private static function list_row( $key, array $provider, array $refs ) {
			$sender   = WPFS_Store::field( $provider, 'sender_email' );
			$mappings = $refs['mappings'];
			return array(
				'key'          => $key,
				'provider'     => WPFS_Store::field( $provider, 'provider' ),
				'sender_email' => $sender,
				'region'       => WPFS_Store::field( $provider, 'region' ),
				'keys'         => self::key_state( $provider ),
				'key_matches'  => md5( $sender ) === $key,
				'mapped'       => WPFS_Store::field( $mappings, $sender ) === $key ? 'yes' : 'no',
				'senders'      => array_keys( $mappings, $key, true ),
				'default'      => $refs['default'] === $key,
				'fallback'     => $refs['fallback'] === $key,
			);
		}

		/**
		 * Where an SES connection's keys come from, and whether they are present.
		 *
		 * @param array $provider Provider settings.
		 * @return string n/a | wp_config | wp_config-missing | db | db-empty
		 */
		private static function key_state( array $provider ) {
			if ( 'ses' !== WPFS_Store::field( $provider, 'provider' ) ) {
				return 'n/a';
			}
			if ( 'wp_config' === WPFS_Store::field( $provider, 'key_store', 'db' ) ) {
				return defined( WPFS_Store::CONST_ACCESS ) && defined( WPFS_Store::CONST_SECRET ) ? 'wp_config' : 'wp_config-missing';
			}
			$has_keys = '' !== WPFS_Store::field( $provider, 'access_key' ) && '' !== WPFS_Store::field( $provider, 'secret_key' );
			return $has_keys ? 'db' : 'db-empty';
		}

		/**
		 * One proof send in this process.
		 *
		 * @param array $options Parsed options (to, from, lift_http_block).
		 * @return array
		 * @throws WPFS_Error When sending is unavailable or fails.
		 */
		public static function action_test( array $options ) {
			if ( ! function_exists( 'fluentMailSend' ) ) {
				throw new WPFS_Error( 'fluentMailSend() is not available in this FluentSMTP version', 2 );
			}
			// Staging isolation blocks outbound HTTP; lift it for this process only, on request.
			if ( ! empty( $options['lift_http_block'] ) ) {
				remove_all_filters( 'pre_http_request' );
			}
			$failure = '';
			add_action(
				'wp_mail_failed',
				function ( $error ) use ( &$failure ) {
					$failure = is_wp_error( $error ) ? $error->get_error_message() : 'unknown error';
				}
			);
			$subject = 'aidevops FluentSMTP test ' . gmdate( 'Y-m-d H:i:s' ) . ' ' . wp_generate_password( 6, false );
			$headers = isset( $options['from'] ) ? array( 'From: ' . $options['from'] ) : array();
			$body    = "Proof send from wp-helper.sh --fluentsmtp test.\nSite: " . get_option( 'siteurl' ) . "\n";
			if ( ! fluentMailSend( $options['to'], $subject, $body, $headers ) ) {
				throw new WPFS_Error( 'Send failed: ' . ( '' !== $failure ? $failure : 'fluentMailSend returned false' ), 1 );
			}
			return array(
				'sent'    => true,
				'to'      => $options['to'],
				'subject' => $subject,
				'next'    => 'Accepted by FluentSMTP is not delivery: check the received Authentication-Results.',
			);
		}

		/**
		 * Print a JSON document.
		 *
		 * @param mixed $data Result.
		 */
		private static function emit( $data ) {
			echo wp_json_encode( $data, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE ), "\n";
		}
	}
}

// phpcs:ignore WordPress.NamingConventions.PrefixAllGlobals -- $args is set by `wp eval-file`.
$wpfs_exit = WPFS_Cli::main( isset( $args ) && is_array( $args ) ? $args : array() );
if ( 0 !== $wpfs_exit ) {
	exit( $wpfs_exit );
}
