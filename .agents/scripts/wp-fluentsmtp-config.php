<?php
/**
 * SES keys for wp-fluentsmtp.php `migrate`: read them from STDIN and place
 * the two FLUENTMAIL_AWS_* constants in wp-config.php (GH#38865).
 *
 * SPDX-License-Identifier: MIT
 * SPDX-FileCopyrightText: 2026 Marcus Quinn
 *
 * Key values are never printed. Earlier single-line defines of the constants,
 * and our marker, are replaced; any other form refuses the migration.
 *
 * @package aidevops
 */

if ( ! class_exists( 'WPFS_Config' ) ) {

	/**
	 * Key input and the wp-config.php content transform.
	 */
	final class WPFS_Config {

		const MARKER = '/* aidevops: FluentSMTP SES keys (wp-helper.sh --fluentsmtp) */';

		/**
		 * Read and validate the two keys from STDIN.
		 *
		 * @return array access_key, secret_key.
		 * @throws WPFS_Error When the input is missing or malformed.
		 */
		public static function read_keys() {
			$input  = stream_get_contents( STDIN, 8192 );
			$keys   = is_string( $input ) ? json_decode( $input, true ) : null;
			$keys   = is_array( $keys ) ? $keys : array();
			$access = WPFS_Store::field( $keys, 'access_key' );
			$secret = WPFS_Store::field( $keys, 'secret_key' );
			// FluentSMTP has no session-token field, so only long-term (AKIA) keys can work.
			if ( ! preg_match( '/^AKIA[A-Z0-9]{16}$/', $access ) ) {
				throw new WPFS_Error( 'migrate needs a long-term AWS access key ID (AKIA...) as "access_key" in the STDIN JSON', 2 );
			}
			if ( ! preg_match( '#^[A-Za-z0-9/+]{40}$#', $secret ) ) {
				throw new WPFS_Error( 'migrate needs a 40-character AWS secret access key as "secret_key" in the STDIN JSON', 2 );
			}
			return array( $access, $secret );
		}

		/**
		 * wp-config.php content with the two constants set before the anchor.
		 *
		 * @param string $config Current content.
		 * @param array  $keys   access_key, secret_key.
		 * @return string
		 */
		public static function with_keys( $config, array $keys ) {
			$constants = array(
				WPFS_Store::CONST_ACCESS => $keys[0],
				WPFS_Store::CONST_SECRET => $keys[1],
			);
			return WPAD_Config_File::with_constants( $config, $constants, self::MARKER );
		}
	}
}
