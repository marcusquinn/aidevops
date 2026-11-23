<?php
/**
 * Write one secret constant into wp-config.php over WP-CLI (GH#39922).
 *
 * SPDX-License-Identifier: MIT
 * SPDX-FileCopyrightText: 2026 Marcus Quinn
 *
 * Run from the WordPress root (upload wp-config-file.php alongside):
 *   wp eval-file wp-config-secret.php set constant=NAME [dry_run=1] < value.json
 *   wp eval-file wp-config-secret.php status constant=NAME
 *   wp eval-file wp-config-secret.php backups
 *   wp eval-file wp-config-secret.php undo backup=DIR
 *
 * set reads {"value": "..."} JSON on STDIN, never argv, so the value is not in
 * the remote process list or helper output. It backs up wp-config.php (0600,
 * outside the webroot), writes a single-line define in a marked block, and
 * replaces the file atomically with its mode kept. The value is never printed:
 * output carries only presence, length and file modes.
 *
 * Prints JSON. Exit codes: 0 done, 1 refused or not confirmed, 2 usage error.
 * Workflow: .agents/tools/wordpress/wp-dev.md "Secrets in wp-config.php".
 *
 * @package aidevops
 */

if ( false === defined( 'ABSPATH' ) || false === class_exists( 'WP_CLI' ) ) {
	fwrite( STDERR, "Run through WP-CLI: wp eval-file wp-config-secret.php ACTION [key=value ...]\n" );
	exit( 2 );
}

require_once __DIR__ . '/wp-config-file.php';

if ( false === class_exists( 'WPCS_Cli' ) ) {

	/**
	 * Parses arguments and runs one action.
	 */
	final class WPCS_Cli {

		const TOOL      = 'config-secret';
		const NAME      = '/^[A-Z][A-Z0-9_]{1,63}$/';
		const MAX_BYTES = 4096;
		// sprintf() format of the marker comment above one constant's block.
		const MARKER = '/* aidevops: %s (wp-helper.sh --config-secret) */';
		// Core, database and key constants: changing them breaks the site or
		// makes stored data unreadable, so they are never written by this tool.
		// Core's own defaults are refused anyway as "defined outside
		// wp-config.php"; this list also covers them when wp-config.php sets them.
		const RESERVED = array(
			'ABSPATH',
			'WP_HOME',
			'WP_SITEURL',
			'WP_CONTENT_DIR',
			'WP_CONTENT_URL',
			'WP_PLUGIN_DIR',
			'WP_PLUGIN_URL',
			'PLUGINDIR',
			'WPMU_PLUGIN_DIR',
			'WPMU_PLUGIN_URL',
			'UPLOADS',
			'WP_LANG_DIR',
			'WP_TEMP_DIR',
			'COOKIE_DOMAIN',
			'COOKIEHASH',
			'COOKIEPATH',
			'SITECOOKIEPATH',
			'ADMIN_COOKIE_PATH',
			'PLUGINS_COOKIE_PATH',
			'WP_ALLOW_MULTISITE',
			'MULTISITE',
			'SUBDOMAIN_INSTALL',
			'DOMAIN_CURRENT_SITE',
			'PATH_CURRENT_SITE',
			'SITE_ID_CURRENT_SITE',
			'BLOG_ID_CURRENT_SITE',
			'CUSTOM_USER_TABLE',
			'CUSTOM_USER_META_TABLE',
			'WP_CACHE',
			'WP_DEBUG',
			'WP_ENVIRONMENT_TYPE',
			'FORCE_SSL_ADMIN',
			'AUTH_KEY',
			'SECURE_AUTH_KEY',
			'LOGGED_IN_KEY',
			'NONCE_KEY',
			'AUTH_SALT',
			'SECURE_AUTH_SALT',
			'LOGGED_IN_SALT',
			'NONCE_SALT',
			'WP_SECRETS_KEY',
			'WP_SECRETS_KEY_PREVIOUS',
		);
		const REQUIRED = array(
			'set'     => array( 'constant' ),
			'status'  => array( 'constant' ),
			'backups' => array(),
			'undo'    => array( 'backup' ),
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
				self::emit( call_user_func( array( 'WPCS_Cli', 'action_' . $action ), $options ) );
				return 0;
			} catch ( WPAD_Config_Error $error ) {
				fwrite( STDERR, 'ERROR: ' . $error->getMessage() . "\n" );
				return (int) $error->getCode();
			} catch ( Throwable $error ) {
				fwrite( STDERR, 'ERROR: config-secret operation failed: ' . get_class( $error ) . "\n" );
				return 1;
			}
		}

		/**
		 * Parse key=value options, require the action's keys and validate the name.
		 *
		 * @param string $action Action name.
		 * @param array  $args   Remaining arguments.
		 * @return array Options.
		 * @throws WPAD_Config_Error On usage errors.
		 */
		private static function parse_options( $action, array $args ) {
			if ( ! isset( self::REQUIRED[ $action ] ) ) {
				throw new WPAD_Config_Error( 'Unknown action: ' . ( '' === $action ? '<none>' : $action ) . ' (set|status|backups|undo)', 2 );
			}
			$options = array();
			foreach ( $args as $arg ) {
				$pair = explode( '=', (string) $arg, 2 );
				if ( 2 !== count( $pair ) || '' === $pair[1] ) {
					throw new WPAD_Config_Error( 'Expected key=value, got: ' . $arg, 2 );
				}
				$options[ $pair[0] ] = $pair[1];
			}
			$missing = array_diff( self::REQUIRED[ $action ], array_keys( $options ) );
			if ( $missing ) {
				throw new WPAD_Config_Error( $action . ' needs ' . reset( $missing ) . '=...', 2 );
			}
			if ( isset( $options['constant'] ) ) {
				self::check_name( $options['constant'] );
			}
			return $options;
		}

		/**
		 * Refuse malformed and reserved constant names.
		 *
		 * @param string $name Constant name.
		 * @throws WPAD_Config_Error When the name is not allowed.
		 */
		private static function check_name( $name ) {
			if ( ! preg_match( self::NAME, $name ) ) {
				throw new WPAD_Config_Error( 'constant must be an upper-case PHP constant name (A-Z, 0-9, _), got: ' . $name, 2 );
			}
			if ( in_array( $name, self::RESERVED, true ) || 0 === strpos( $name, 'DB_' ) ) {
				throw new WPAD_Config_Error( $name . ' is a core, database or key constant; edit it by hand', 2 );
			}
		}

		/**
		 * Read and validate {"value": "..."} from STDIN.
		 *
		 * @return string
		 * @throws WPAD_Config_Error When the input is missing or malformed.
		 */
		private static function read_value() {
			$input = stream_get_contents( STDIN, self::MAX_BYTES * 2 + 64 );
			$data  = is_string( $input ) ? json_decode( $input, true ) : null;
			$value = is_array( $data ) && isset( $data['value'] ) && is_string( $data['value'] ) ? $data['value'] : '';
			if ( '' === $value ) {
				throw new WPAD_Config_Error( 'set needs {"value": "..."} JSON with a non-empty string on STDIN', 2 );
			}
			if ( strlen( $value ) > self::MAX_BYTES ) {
				throw new WPAD_Config_Error( 'The value is longer than ' . self::MAX_BYTES . ' bytes', 2 );
			}
			if ( preg_match( '/[\x00\r\n]/', $value ) ) {
				throw new WPAD_Config_Error( 'The value contains a NUL or line break', 2 );
			}
			return $value;
		}

		/**
		 * Back up and write the constant, or report what a write would do.
		 *
		 * @param array $options Parsed options (constant, dry_run).
		 * @return array
		 * @throws WPAD_Config_Error When the constant is defined outside wp-config.php.
		 */
		public static function action_set( array $options ) {
			$name  = $options['constant'];
			$value = self::read_value();

			list( $config_path, $current ) = self::wp_config();

			// Only code counts: a commented-out define must not hide one in an included file.
			$in_file = WPAD_Config_File::mentions( php_strip_whitespace( $config_path ), $name );
			if ( defined( $name ) && ! $in_file ) {
				// Another file defines it first; a define in wp-config.php would never take effect.
				throw new WPAD_Config_Error( $name . ' is already defined outside wp-config.php; change it where it is defined', 1 );
			}
			// Build the new file first so a refusal leaves nothing behind.
			$config = WPAD_Config_File::with_constants( $current, array( $name => $value ), sprintf( self::MARKER, $name ) );
			$mode   = fileperms( $config_path ) & 0777;
			$result = array(
				'constant'      => $name,
				'was_in_file'   => $in_file,
				'length'        => strlen( $value ),
				'wpconfig_path' => $config_path,
				'wpconfig_mode' => sprintf( '%04o', $mode ),
			);
			if ( ! empty( $options['dry_run'] ) ) {
				return array( 'dry_run' => true ) + $result;
			}
			$backup = WPAD_Config_File::backup( self::TOOL, $config_path, array( 'constant' => $name ) );
			fwrite( STDERR, 'BACKUP: ' . $backup . "\n" );
			WPAD_Config_File::replace_php_file( $config_path, $config, $mode );
			clearstatcache( true, $config_path );
			return $result + array(
				'written'             => true,
				'wpconfig_mode_after' => sprintf( '%04o', fileperms( $config_path ) & 0777 ),
				'backup'              => $backup,
				'note'                => 'The constant takes effect in the next PHP request; run status to confirm.',
			);
		}

		/**
		 * Whether the constant is defined in this request, and its length.
		 *
		 * @param array $options Parsed options (constant).
		 * @return array
		 */
		public static function action_status( array $options ) {
			$name    = $options['constant'];
			$defined = defined( $name );
			$value   = $defined ? constant( $name ) : null;
			$config  = self::wp_config();
			return array(
				'constant' => $name,
				'defined'  => $defined,
				'type'     => $defined ? gettype( $value ) : null,
				'length'   => is_string( $value ) ? strlen( $value ) : null,
				'marked'   => false !== strpos( $config[1], sprintf( self::MARKER, $name ) ),
			);
		}

		/**
		 * This site's config-secret backups, newest first.
		 *
		 * @return array
		 */
		public static function action_backups() {
			return array( 'backups' => WPAD_Config_File::backups( self::TOOL ) );
		}

		/**
		 * Restore wp-config.php from one of this site's backups and verify it.
		 *
		 * @param array $options Parsed options (backup).
		 * @return array
		 * @throws WPAD_Config_Error On a foreign, altered or unverified restore.
		 */
		public static function action_undo( array $options ) {
			$dir                    = WPAD_Config_File::own_backup_dir( self::TOOL, $options['backup'] );
			list( $meta, $config ) = WPAD_Config_File::load_backup( $dir );
			WPAD_Config_File::replace_php_file( $meta['wpconfig_path'], $config, (int) $meta['wpconfig_mode'] );
			return array(
				'restored'        => $dir,
				'wpconfig_sha256' => $meta['wpconfig_sha256'],
				'verified'        => true,
			);
		}

		/**
		 * This site's wp-config.php path and current contents.
		 *
		 * @return array { 0: path, 1: contents }
		 */
		private static function wp_config() {
			$path = WPAD_Config_File::wp_config_path();
			return array( $path, WPAD_Config_File::read( $path ) );
		}

		/**
		 * Print a JSON document.
		 *
		 * @param mixed $data Result.
		 */
		private static function emit( $data ) {
			echo wp_json_encode( $data, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES ), "\n";
		}
	}
}

// phpcs:ignore WordPress.NamingConventions.PrefixAllGlobals -- $args is set by `wp eval-file`.
$wpcs_exit = WPCS_Cli::main( isset( $args ) && is_array( $args ) ? $args : array() );
if ( 0 !== $wpcs_exit ) {
	exit( $wpcs_exit );
}
