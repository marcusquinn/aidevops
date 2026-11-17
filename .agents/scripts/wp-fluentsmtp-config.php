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

		const MARKER  = '/* aidevops: FluentSMTP SES keys (wp-helper.sh --fluentsmtp) */';
		const ANCHORS = array(
			'/^.*That\'s all, stop editing.*$/m',
			'/^[ \t]*require_once\s*\(?\s*ABSPATH\s*\.\s*[\'"]wp-settings\.php[\'"].*$/m',
		);

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
		 * @throws WPFS_Error Without an insertion point.
		 */
		public static function with_keys( $config, array $keys ) {
			$config = self::without_keys( $config );
			// phpcs:disable WordPress.PHP.DevelopmentFunctions -- var_export() emits safe PHP literals.
			$block = self::MARKER . "\n"
				. 'define( ' . var_export( WPFS_Store::CONST_ACCESS, true ) . ', ' . var_export( $keys[0], true ) . " );\n"
				. 'define( ' . var_export( WPFS_Store::CONST_SECRET, true ) . ', ' . var_export( $keys[1], true ) . " );\n\n";
			// phpcs:enable
			foreach ( self::ANCHORS as $anchor ) {
				if ( preg_match( $anchor, $config, $match, PREG_OFFSET_CAPTURE ) ) {
					return substr_replace( $config, $block, $match[0][1], 0 );
				}
			}
			throw new WPFS_Error( 'No insertion point in wp-config.php ("stop editing" comment or wp-settings.php require)', 1 );
		}

		/**
		 * Remove our marker and single-line defines of the two constants.
		 *
		 * @param string $config wp-config.php content.
		 * @return string
		 * @throws WPFS_Error When another form of the defines remains.
		 */
		private static function without_keys( $config ) {
			$names  = preg_quote( WPFS_Store::CONST_ACCESS, '/' ) . '|' . preg_quote( WPFS_Store::CONST_SECRET, '/' );
			$config = preg_replace( '/^[ \t]*' . preg_quote( self::MARKER, '/' ) . '[ \t]*\R/m', '', $config );
			$config = preg_replace( '/^[ \t]*define\(\s*[\'"](?:' . $names . ')[\'"]\s*,.*\);[ \t]*\R/m', '', $config );
			if ( preg_match( '/' . $names . '/', $config ) ) {
				// PHP keeps the first define, so a leftover would silently win over ours.
				throw new WPFS_Error( 'wp-config.php defines the FLUENTMAIL_AWS_* constants in a form this tool cannot replace; edit them by hand', 1 );
			}
			return $config;
		}
	}
}
