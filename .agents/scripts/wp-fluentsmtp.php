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
 * migrate reads {"access_key":"...","secret_key":"..."} on STDIN (never argv),
 * backs up the raw option and wp-config.php (0600, outside the webroot), moves
 * every matching SES connection to local@NEW with key md5(sender), rebuilds
 * mappings and default/fallback references, sets key_store=wp_config with
 * empty DB keys, and writes the FLUENTMAIL_AWS_* constants into wp-config.php
 * (parse-checked, then an atomic rename). Key values are never printed.
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

if ( ! class_exists( 'WPFS_Error' ) ) {
	/**
	 * A failure with its exit code (1 refused/unconfirmed, 2 usage/unavailable).
	 */
	class WPFS_Error extends Exception {
	}
}

if ( ! class_exists( 'WPFS_Ses' ) ) {

	/**
	 * Parses arguments and runs one action.
	 */
	final class WPFS_Ses {

		const OPTION        = 'fluentmail-settings';
		const CONST_ACCESS  = 'FLUENTMAIL_AWS_ACCESS_KEY_ID';
		const CONST_SECRET  = 'FLUENTMAIL_AWS_SECRET_ACCESS_KEY';
		const MARKER        = '/* aidevops: FluentSMTP SES keys (wp-helper.sh --fluentsmtp) */';
		const ACTIONS       = array(
			'list'    => array(),
			'migrate' => array( 'domain', 'region' ),
			'test'    => array( 'to' ),
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
				if ( ! function_exists( 'fluentMailGetSettings' ) || ! function_exists( 'fluentMailSetSettings' ) ) {
					throw new WPFS_Error( 'FluentSMTP is not active here; on multisite pass --url for the blog that runs it', 2 );
				}
				self::emit( call_user_func( array( __CLASS__, 'action_' . $action ), $options ) );
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
		 * Parse key=value options and require the action's keys.
		 *
		 * @param string $action Action name.
		 * @param array  $args   Remaining arguments.
		 * @return array Options.
		 * @throws WPFS_Error On usage errors.
		 */
		private static function parse_options( $action, array $args ) {
			if ( ! isset( self::ACTIONS[ $action ] ) ) {
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
			$missing = array_diff( self::ACTIONS[ $action ], array_keys( $options ) );
			if ( $missing ) {
				throw new WPFS_Error( $action . ' needs ' . reset( $missing ) . '=...', 2 );
			}
			foreach ( array( 'domain', 'from_domain' ) as $key ) {
				if ( isset( $options[ $key ] ) && ! preg_match( '/^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/', $options[ $key ] ) ) {
					throw new WPFS_Error( $key . ' must be a lowercase domain', 2 );
				}
			}
			if ( isset( $options['region'] ) && ! preg_match( '/^[a-z]{2}(-[a-z]+)+-\d$/', $options['region'] ) ) {
				throw new WPFS_Error( 'region must look like eu-west-2', 2 );
			}
			foreach ( array( 'to', 'from' ) as $key ) {
				if ( isset( $options[ $key ] ) && ! is_email( $options[ $key ] ) ) {
					throw new WPFS_Error( $key . ' must be one email address', 2 );
				}
			}
			return $options;
		}

		/**
		 * Raw stored option, exactly as the plugin saved it (secrets encrypted).
		 *
		 * @return mixed
		 */
		private static function raw_option() {
			wp_cache_delete( self::OPTION, 'options' );
			wp_cache_delete( 'alloptions', 'options' );
			return get_option( self::OPTION, false );
		}

		/**
		 * Decrypted settings through the plugin, bypassing its static cache.
		 *
		 * @return array
		 */
		private static function settings() {
			$settings = fluentMailGetSettings( array(), false );
			return is_array( $settings ) ? $settings : array();
		}

		/**
		 * Domain part of an address, lowercased.
		 *
		 * @param string $email Address.
		 * @return string
		 */
		private static function domain_of( $email ) {
			$at = strrpos( (string) $email, '@' );
			return false === $at ? '' : strtolower( substr( $email, $at + 1 ) );
		}

		/**
		 * Connections with their health, never their keys.
		 *
		 * @return array
		 */
		public static function action_list() {
			$settings    = self::settings();
			$connections = isset( $settings['connections'] ) && is_array( $settings['connections'] ) ? $settings['connections'] : array();
			$mappings    = isset( $settings['mappings'] ) && is_array( $settings['mappings'] ) ? $settings['mappings'] : array();
			$misc        = isset( $settings['misc'] ) && is_array( $settings['misc'] ) ? $settings['misc'] : array();
			$rows        = array();
			foreach ( $connections as $key => $connection ) {
				$provider = isset( $connection['provider_settings'] ) ? (array) $connection['provider_settings'] : array();
				$sender   = isset( $provider['sender_email'] ) ? (string) $provider['sender_email'] : '';
				$store    = isset( $provider['key_store'] ) ? (string) $provider['key_store'] : 'db';
				if ( 'ses' !== ( isset( $provider['provider'] ) ? $provider['provider'] : '' ) ) {
					$keys = 'n/a';
				} elseif ( 'wp_config' === $store ) {
					$keys = defined( self::CONST_ACCESS ) && defined( self::CONST_SECRET ) ? 'wp_config' : 'wp_config-missing';
				} else {
					$keys = ! empty( $provider['access_key'] ) && ! empty( $provider['secret_key'] ) ? 'db' : 'db-empty';
				}
				$senders = array_keys( array_filter( $mappings, function ( $mapped ) use ( $key ) {
					return $mapped === $key;
				} ) );
				$rows[]  = array(
					'key'          => (string) $key,
					'provider'     => isset( $provider['provider'] ) ? (string) $provider['provider'] : '',
					'sender_email' => $sender,
					'region'       => isset( $provider['region'] ) ? (string) $provider['region'] : '',
					'keys'         => $keys,
					'key_matches'  => md5( $sender ) === (string) $key,
					'mapped'       => isset( $mappings[ $sender ] ) && $mappings[ $sender ] === $key ? 'yes' : 'no',
					'senders'      => $senders,
					'default'      => isset( $misc['default_connection'] ) && $misc['default_connection'] === $key,
					'fallback'     => isset( $misc['fallback_connection'] ) && $misc['fallback_connection'] === $key,
				);
			}
			return array(
				'connections' => $rows,
				'defaults'    => count( array_filter( wp_list_pluck( $rows, 'default' ) ) ),
				'option'      => false === self::raw_option() ? 'absent' : 'present',
			);
		}

		/**
		 * Read and validate the two keys from STDIN.
		 *
		 * @return array access_key, secret_key.
		 * @throws WPFS_Error When the input is missing or malformed.
		 */
		private static function read_keys() {
			$input = stream_get_contents( STDIN, 8192 );
			$keys  = is_string( $input ) ? json_decode( $input, true ) : null;
			if ( ! is_array( $keys ) || empty( $keys['access_key'] ) || empty( $keys['secret_key'] ) ) {
				throw new WPFS_Error( 'migrate needs {"access_key","secret_key"} JSON on STDIN', 2 );
			}
			if ( ! preg_match( '/^(AKIA|ASIA)[A-Z0-9]{16}$/', $keys['access_key'] ) ) {
				throw new WPFS_Error( 'The access key ID does not look like an AWS key ID', 2 );
			}
			if ( ! preg_match( '#^[A-Za-z0-9/+]{40}$#', $keys['secret_key'] ) ) {
				throw new WPFS_Error( 'The secret access key does not look like an AWS secret key', 2 );
			}
			return array( (string) $keys['access_key'], (string) $keys['secret_key'] );
		}

		/**
		 * Build the migrated settings and the old => new key map.
		 *
		 * @param array $settings Current decrypted settings.
		 * @param array $options  Parsed options.
		 * @return array settings, plan rows.
		 * @throws WPFS_Error On collisions or nothing to migrate.
		 */
		private static function plan( array $settings, array $options ) {
			$connections = isset( $settings['connections'] ) && is_array( $settings['connections'] ) ? $settings['connections'] : array();
			$mappings    = isset( $settings['mappings'] ) && is_array( $settings['mappings'] ) ? $settings['mappings'] : array();
			$from_domain = isset( $options['from_domain'] ) ? $options['from_domain'] : '';
			$renames     = array();
			$plan        = array();
			$migrated    = array();

			foreach ( $connections as $key => $connection ) {
				$provider = isset( $connection['provider_settings'] ) ? (array) $connection['provider_settings'] : array();
				if ( 'ses' !== ( isset( $provider['provider'] ) ? $provider['provider'] : '' ) ) {
					$migrated[ $key ] = $connection;
					continue;
				}
				$old_sender = (string) $provider['sender_email'];
				$old_domain = self::domain_of( $old_sender );
				if ( '' !== $from_domain && $old_domain !== $from_domain ) {
					$migrated[ $key ] = $connection;
					continue;
				}
				$new_sender = substr( $old_sender, 0, strrpos( $old_sender, '@' ) ) . '@' . $options['domain'];
				$new_key    = md5( $new_sender );
				if ( in_array( $new_key, $renames, true ) ) {
					throw new WPFS_Error( 'Two connections would share sender ' . $new_sender . '; resolve that in FluentSMTP first', 1 );
				}
				$provider['sender_email']        = $new_sender;
				$provider['region']              = $options['region'];
				$provider['key_store']           = 'wp_config';
				$provider['access_key']          = '';
				$provider['secret_key']          = '';
				$connection['provider_settings'] = $provider;
				$migrated[ $new_key ]            = $connection;
				$renames[ $key ]                 = $new_key;
				$plan[]                          = array(
					'from'   => $old_sender,
					'to'     => $new_sender,
					'key'    => $new_key,
					'region' => $options['region'],
				);
			}
			if ( ! $renames ) {
				throw new WPFS_Error( 'No Amazon SES connection matched' . ( '' !== $from_domain ? ' from_domain=' . $from_domain : '' ), 1 );
			}
			// A kept (unmoved) connection already owning a new key would be overwritten.
			foreach ( $renames as $old_key => $new_key ) {
				if ( isset( $connections[ $new_key ] ) && ! isset( $renames[ $new_key ] ) && $new_key !== $old_key ) {
					throw new WPFS_Error( 'A connection for ' . $connections[ $new_key ]['provider_settings']['sender_email'] . ' already exists; remove or merge it in FluentSMTP first', 1 );
				}
			}

			// Mappings: senders of moved connections follow the new domain.
			$new_mappings = array();
			foreach ( $mappings as $email => $mapped_key ) {
				if ( isset( $renames[ $mapped_key ] ) ) {
					$old_domain = self::domain_of( $email );
					if ( '' === $from_domain || $old_domain === $from_domain ) {
						$email = substr( $email, 0, strrpos( $email, '@' ) ) . '@' . $options['domain'];
					}
					$mapped_key = $renames[ $mapped_key ];
				}
				$new_mappings[ $email ] = $mapped_key;
			}
			foreach ( $plan as $row ) {
				$new_mappings[ $row['to'] ] = $row['key'];
			}

			$misc = isset( $settings['misc'] ) && is_array( $settings['misc'] ) ? $settings['misc'] : array();
			foreach ( array( 'default_connection', 'fallback_connection' ) as $ref ) {
				if ( ! empty( $misc[ $ref ] ) && isset( $renames[ $misc[ $ref ] ] ) ) {
					$misc[ $ref ] = $renames[ $misc[ $ref ] ];
				}
			}

			$settings['connections'] = $migrated;
			$settings['mappings']    = $new_mappings;
			$settings['misc']        = $misc;
			return array( $settings, $plan );
		}

		/**
		 * Locate wp-config.php the way WordPress does.
		 *
		 * @return string Path.
		 * @throws WPFS_Error When it cannot be found or written.
		 */
		private static function wp_config_path() {
			$path = ABSPATH . 'wp-config.php';
			if ( ! file_exists( $path ) ) {
				$parent = dirname( ABSPATH ) . '/wp-config.php';
				if ( file_exists( $parent ) && ! file_exists( dirname( ABSPATH ) . '/wp-settings.php' ) ) {
					$path = $parent;
				}
			}
			if ( ! is_file( $path ) || ! is_readable( $path ) || ! is_writable( dirname( $path ) ) ) {
				throw new WPFS_Error( 'wp-config.php not found or its directory is not writable: ' . $path, 1 );
			}
			return $path;
		}

		/**
		 * Backup root: the WP-CLI user's home, outside the webroot.
		 *
		 * @return string
		 * @throws WPFS_Error Without a usable home directory.
		 */
		private static function backup_root() {
			$home = getenv( 'HOME' );
			if ( ! $home || ! is_dir( $home ) || ! is_writable( $home ) ) {
				throw new WPFS_Error( 'No writable HOME for backups; set HOME for the WP-CLI user', 1 );
			}
			return rtrim( $home, '/' ) . '/.aidevops-backups/fluentsmtp/' . substr( md5( (string) get_option( 'siteurl' ) ), 0, 12 );
		}

		/**
		 * Write a file with mode 0600.
		 *
		 * @param string $path  Destination.
		 * @param string $bytes Content.
		 * @throws WPFS_Error On failure.
		 */
		private static function write_private( $path, $bytes ) {
			$old_umask = umask( 0077 );
			$written   = file_put_contents( $path, $bytes, LOCK_EX );
			umask( $old_umask );
			if ( strlen( $bytes ) !== $written || ! chmod( $path, 0600 ) ) {
				throw new WPFS_Error( 'Could not write ' . $path, 1 );
			}
		}

		/**
		 * Back up the raw option and wp-config.php; return the backup directory.
		 *
		 * @param string $config_path wp-config.php path.
		 * @return string
		 * @throws WPFS_Error On failure.
		 */
		private static function backup( $config_path ) {
			$dir       = self::backup_root() . '/' . gmdate( 'Ymd-His' ) . '-' . wp_generate_password( 6, false );
			$old_umask = umask( 0077 );
			$made      = wp_mkdir_p( $dir );
			umask( $old_umask );
			if ( ! $made ) {
				throw new WPFS_Error( 'Could not create backup directory ' . $dir, 1 );
			}
			$raw    = self::raw_option();
			$option = serialize( $raw ); // phpcs:ignore WordPress.PHP.DiscouragedPHPFunctions -- exact bytes for undo.
			$config = file_get_contents( $config_path );
			if ( false === $config ) {
				throw new WPFS_Error( 'Could not read ' . $config_path, 1 );
			}
			self::write_private( $dir . '/option.ser', $option );
			self::write_private( $dir . '/wp-config.php', $config );
			self::write_private(
				$dir . '/meta.json',
				wp_json_encode(
					array(
						'siteurl'         => get_option( 'siteurl' ),
						'created'         => gmdate( 'c' ),
						'option_present'  => false !== $raw,
						'option_sha256'   => hash( 'sha256', $option ),
						'wpconfig_path'   => $config_path,
						'wpconfig_mode'   => fileperms( $config_path ) & 0777,
						'wpconfig_sha256' => hash( 'sha256', $config ),
					),
					JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES
				)
			);
			return $dir;
		}

		/**
		 * wp-config.php content with the two constants set (old lines removed).
		 *
		 * @param string $config Current content.
		 * @param array  $keys   access_key, secret_key.
		 * @return string
		 * @throws WPFS_Error Without an insertion point.
		 */
		private static function config_with_keys( $config, array $keys ) {
			$names  = self::CONST_ACCESS . '|' . self::CONST_SECRET;
			$config = preg_replace( '/^[ \t]*' . preg_quote( self::MARKER, '/' ) . '[ \t]*\R/m', '', $config );
			$config = preg_replace( '/^[ \t]*define\(\s*[\'"](?:' . $names . ')[\'"]\s*,.*\);[ \t]*\R/m', '', $config );
			if ( preg_match( '/' . $names . '/', $config ) ) {
				// A define we could not remove would win over ours (first define sticks).
				throw new WPFS_Error( 'wp-config.php defines the FLUENTMAIL_AWS_* constants in a form this tool cannot replace; edit them by hand', 1 );
			}
			$block  = self::MARKER . "\n"
				. 'define( ' . var_export( self::CONST_ACCESS, true ) . ', ' . var_export( $keys[0], true ) . " );\n" // phpcs:ignore WordPress.PHP.DevelopmentFunctions
				. 'define( ' . var_export( self::CONST_SECRET, true ) . ', ' . var_export( $keys[1], true ) . " );\n\n"; // phpcs:ignore WordPress.PHP.DevelopmentFunctions
			foreach ( array( '/^.*That\'s all, stop editing.*$/m', '/^[ \t]*require_once\s*\(?\s*ABSPATH\s*\.\s*[\'"]wp-settings\.php[\'"].*$/m' ) as $anchor ) {
				if ( preg_match( $anchor, $config, $match, PREG_OFFSET_CAPTURE ) ) {
					return substr_replace( $config, $block, $match[0][1], 0 );
				}
			}
			throw new WPFS_Error( 'No insertion point in wp-config.php ("stop editing" comment or wp-settings.php require)', 1 );
		}

		/**
		 * Parse-check PHP, then replace a file atomically with the given mode.
		 *
		 * @param string $path  Destination.
		 * @param string $bytes New content.
		 * @param int    $mode  File mode.
		 * @throws WPFS_Error On a parse error or failed write.
		 */
		private static function replace_php_file( $path, $bytes, $mode ) {
			try {
				token_get_all( $bytes, TOKEN_PARSE );
			} catch ( ParseError $error ) {
				throw new WPFS_Error( 'Refusing to write ' . basename( $path ) . ': parse error on line ' . $error->getLine(), 1 );
			}
			$tmp = dirname( $path ) . '/.' . basename( $path ) . '.aidevops-' . wp_generate_password( 8, false );
			self::write_private( $tmp, $bytes );
			if ( ! chmod( $tmp, $mode ) || ! rename( $tmp, $path ) ) {
				@unlink( $tmp ); // phpcs:ignore WordPress.PHP.NoSilencedErrors
				throw new WPFS_Error( 'Could not replace ' . $path, 1 );
			}
			clearstatcache( true, $path );
			if ( hash_file( 'sha256', $path ) !== hash( 'sha256', $bytes ) ) {
				throw new WPFS_Error( 'Read-back of ' . $path . ' does not match what was written', 1 );
			}
		}

		/**
		 * Move SES connections to a new domain, region and the wp_config key store.
		 *
		 * @param array $options Parsed options.
		 * @return array
		 */
		public static function action_migrate( array $options ) {
			list( $settings, $plan ) = self::plan( self::settings(), $options );
			$config_path             = self::wp_config_path();
			if ( ! empty( $options['dry_run'] ) ) {
				return array(
					'dry_run'   => true,
					'plan'      => $plan,
					'wp_config' => $config_path,
				);
			}
			$keys   = self::read_keys();
			$backup = self::backup( $config_path );
			fwrite( STDERR, 'BACKUP: ' . $backup . "\n" );
			$config = file_get_contents( $config_path );
			self::replace_php_file( $config_path, self::config_with_keys( $config, $keys ), fileperms( $config_path ) & 0777 );
			fluentMailSetSettings( $settings );
			$after = self::action_list();
			foreach ( $after['connections'] as &$row ) {
				// This process loaded wp-config.php before the write; the next request sees the constants.
				if ( 'wp_config-missing' === $row['keys'] ) {
					$row['keys'] = 'wp_config-next-request';
				}
			}
			unset( $row );
			return array(
				'backup'      => $backup,
				'plan'        => $plan,
				'connections' => $after['connections'],
				'note'        => 'Constants take effect in the next PHP request; run `test` next.',
			);
		}

		/**
		 * One proof send in this process, past a staging HTTP block.
		 *
		 * @param array $options Parsed options.
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
			$sent    = fluentMailSend( $options['to'], $subject, $body, $headers );
			if ( ! $sent ) {
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
		 * List backups for this site, newest first.
		 *
		 * @return array
		 */
		public static function action_backups() {
			$root = self::backup_root();
			$dirs = is_dir( $root ) ? glob( $root . '/*', GLOB_ONLYDIR ) : array();
			rsort( $dirs );
			return array( 'backups' => $dirs );
		}

		/**
		 * Restore the option and wp-config.php from a backup, then verify both.
		 *
		 * @param array $options Parsed options.
		 * @return array
		 * @throws WPFS_Error On a missing, foreign or unverifiable backup.
		 */
		public static function action_undo( array $options ) {
			$dir  = rtrim( $options['backup'], '/' );
			$root = self::backup_root();
			if ( 0 !== strpos( realpath( $dir ) ? realpath( $dir ) : '', realpath( $root ) ? realpath( $root ) . '/' : "\0" ) ) {
				throw new WPFS_Error( 'Backup must be one of this site\'s backups (see: backups)', 2 );
			}
			$meta   = json_decode( (string) file_get_contents( $dir . '/meta.json' ), true );
			$option = file_get_contents( $dir . '/option.ser' );
			$config = file_get_contents( $dir . '/wp-config.php' );
			if ( ! is_array( $meta ) || false === $option || false === $config
				|| hash( 'sha256', $option ) !== $meta['option_sha256'] || hash( 'sha256', $config ) !== $meta['wpconfig_sha256'] ) {
				throw new WPFS_Error( 'Backup is incomplete or does not match its checksums', 1 );
			}
			if ( $meta['wpconfig_path'] !== self::wp_config_path() ) {
				throw new WPFS_Error( 'Backup belongs to ' . $meta['wpconfig_path'] . ', not this site', 1 );
			}
			self::replace_php_file( $meta['wpconfig_path'], $config, (int) $meta['wpconfig_mode'] );
			$raw = unserialize( $option, array( 'allowed_classes' => false ) ); // phpcs:ignore WordPress.PHP.DiscouragedPHPFunctions
			if ( empty( $meta['option_present'] ) ) {
				delete_option( self::OPTION );
			} else {
				update_option( self::OPTION, $raw );
			}
			$now = serialize( self::raw_option() ); // phpcs:ignore WordPress.PHP.DiscouragedPHPFunctions
			$ok  = hash( 'sha256', $now ) === $meta['option_sha256'] && hash_file( 'sha256', $meta['wpconfig_path'] ) === $meta['wpconfig_sha256'];
			if ( ! $ok ) {
				throw new WPFS_Error( 'Restore written but checksums differ from the backup', 1 );
			}
			return array(
				'restored'        => $dir,
				'option_sha256'   => $meta['option_sha256'],
				'wpconfig_sha256' => $meta['wpconfig_sha256'],
				'verified'        => true,
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
$wpfs_exit = WPFS_Ses::main( isset( $args ) && is_array( $args ) ? $args : array() );
if ( 0 !== $wpfs_exit ) {
	exit( $wpfs_exit );
}
