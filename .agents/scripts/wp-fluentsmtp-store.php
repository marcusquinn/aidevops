<?php
/**
 * Settings, path and file helpers shared by wp-fluentsmtp.php (GH#38865).
 *
 * SPDX-License-Identifier: MIT
 * SPDX-FileCopyrightText: 2026 Marcus Quinn
 *
 * Settings go through FluentSMTP's own fluentMailGetSettings(), which decrypts
 * DB-stored secrets; raw_option() is the stored blob, kept for exact backups.
 * wp-config.php location, private writes and atomic replacement delegate to
 * WPAD_Config_File (wp-config-file.php, GH#39922).
 *
 * @package aidevops
 */

require_once __DIR__ . '/wp-config-file.php';

if ( ! class_exists( 'WPFS_Error' ) ) {
	/**
	 * A failure with its exit code (1 refused/unconfirmed, 2 usage/unavailable).
	 */
	class WPFS_Error extends WPAD_Config_Error {
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
		 */
		public static function wp_config_path() {
			return WPAD_Config_File::wp_config_path();
		}

		/**
		 * Backup root: the WP-CLI user's home, outside the webroot.
		 *
		 * @return string
		 */
		public static function backup_root() {
			return WPAD_Config_File::backup_root( 'fluentsmtp' );
		}

		/**
		 * Write a file with mode 0600.
		 *
		 * @param string $path  Destination.
		 * @param string $bytes Content.
		 */
		public static function write_private( $path, $bytes ) {
			WPAD_Config_File::write_private( $path, $bytes );
		}

		/**
		 * Parse-check PHP, then replace a file atomically with the given mode.
		 *
		 * @param string $path  Destination.
		 * @param string $bytes New content.
		 * @param int    $mode  File mode.
		 */
		public static function replace_php_file( $path, $bytes, $mode ) {
			WPAD_Config_File::replace_php_file( $path, $bytes, $mode );
		}
	}
}
