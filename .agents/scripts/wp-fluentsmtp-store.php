<?php
/**
 * Settings, path and file helpers shared by wp-fluentsmtp.php (GH#38865).
 *
 * SPDX-License-Identifier: MIT
 * SPDX-FileCopyrightText: 2026 Marcus Quinn
 *
 * Settings go through FluentSMTP's own fluentMailGetSettings(), which decrypts
 * DB-stored secrets; raw_option() is the stored blob, kept for exact backups.
 *
 * @package aidevops
 */

if ( ! class_exists( 'WPFS_Error' ) ) {
	/**
	 * A failure with its exit code (1 refused/unconfirmed, 2 usage/unavailable).
	 */
	class WPFS_Error extends Exception {
	}
}

if ( ! class_exists( 'WPFS_Store' ) ) {

	/**
	 * Read settings and files; write private files and PHP files safely.
	 */
	final class WPFS_Store {

		const OPTION       = 'fluentmail-settings';
		const CONST_ACCESS = 'FLUENTMAIL_AWS_ACCESS_KEY_ID';
		const CONST_SECRET = 'FLUENTMAIL_AWS_SECRET_ACCESS_KEY';

		/**
		 * Raw stored option, exactly as the plugin saved it (secrets encrypted).
		 *
		 * @return mixed
		 */
		public static function raw_option() {
			wp_cache_delete( self::OPTION, 'options' );
			wp_cache_delete( 'alloptions', 'options' );
			return get_option( self::OPTION, false );
		}

		/**
		 * Decrypted settings through the plugin, bypassing its static cache.
		 *
		 * @return array
		 */
		public static function settings() {
			$settings = fluentMailGetSettings( array(), false );
			return is_array( $settings ) ? $settings : array();
		}

		/**
		 * An array member, or an empty array.
		 *
		 * @param array  $settings Settings or any array.
		 * @param string $key      Member name.
		 * @return array
		 */
		public static function section( array $settings, $key ) {
			return isset( $settings[ $key ] ) && is_array( $settings[ $key ] ) ? $settings[ $key ] : array();
		}

		/**
		 * A connection's provider settings.
		 *
		 * @param mixed $connection Stored connection.
		 * @return array
		 */
		public static function provider( $connection ) {
			return is_array( $connection ) ? self::section( $connection, 'provider_settings' ) : array();
		}

		/**
		 * A scalar member as a string, or the default.
		 *
		 * @param array  $values  Any array.
		 * @param string $key     Member name.
		 * @param string $default Fallback.
		 * @return string
		 */
		public static function field( array $values, $key, $default = '' ) {
			return isset( $values[ $key ] ) && is_scalar( $values[ $key ] ) ? (string) $values[ $key ] : $default;
		}

		/**
		 * Domain part of an address, lowercased; empty without an "@".
		 *
		 * @param string $email Address.
		 * @return string
		 */
		public static function domain_of( $email ) {
			$at = strrpos( (string) $email, '@' );
			return false === $at ? '' : strtolower( substr( $email, $at + 1 ) );
		}

		/**
		 * The same local part on another domain.
		 *
		 * @param string $email  Address with an "@".
		 * @param string $domain New domain.
		 * @return string
		 */
		public static function with_domain( $email, $domain ) {
			return substr( $email, 0, strrpos( $email, '@' ) ) . '@' . $domain;
		}

		/**
		 * Locate wp-config.php the way WordPress does and require it writable.
		 *
		 * @return string Path.
		 * @throws WPFS_Error When it cannot be found or replaced.
		 */
		public static function wp_config_path() {
			$path = ABSPATH . 'wp-config.php';
			if ( ! file_exists( $path ) && ! file_exists( dirname( ABSPATH ) . '/wp-settings.php' ) ) {
				// WordPress also loads wp-config.php from the parent of a non-nested install.
				$path = dirname( ABSPATH ) . '/wp-config.php';
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
		public static function backup_root() {
			$home = (string) getenv( 'HOME' );
			if ( '' === $home || ! is_dir( $home ) || ! is_writable( $home ) ) {
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
		public static function write_private( $path, $bytes ) {
			$old_umask = umask( 0077 );
			$written   = file_put_contents( $path, $bytes, LOCK_EX );
			umask( $old_umask );
			if ( strlen( $bytes ) !== $written || ! chmod( $path, 0600 ) ) {
				throw new WPFS_Error( 'Could not write ' . $path, 1 );
			}
		}

		/**
		 * Parse-check PHP, then replace a file atomically with the given mode.
		 *
		 * @param string $path  Destination.
		 * @param string $bytes New content.
		 * @param int    $mode  File mode.
		 * @throws WPFS_Error On a parse error, failed write or failed read-back.
		 */
		public static function replace_php_file( $path, $bytes, $mode ) {
			try {
				token_get_all( $bytes, TOKEN_PARSE );
			} catch ( ParseError $error ) {
				throw new WPFS_Error( 'Refusing to write ' . basename( $path ) . ': parse error on line ' . $error->getLine(), 1 );
			}
			$tmp = dirname( $path ) . '/.' . basename( $path ) . '.aidevops-' . wp_generate_password( 8, false );
			self::write_private( $tmp, $bytes );
			if ( ! chmod( $tmp, $mode ) || ! rename( $tmp, $path ) ) {
				unlink( $tmp );
				throw new WPFS_Error( 'Could not replace ' . $path, 1 );
			}
			clearstatcache( true, $path );
			if ( hash_file( 'sha256', $path ) !== hash( 'sha256', $bytes ) ) {
				throw new WPFS_Error( 'Read-back of ' . $path . ' does not match what was written', 1 );
			}
		}
	}
}
