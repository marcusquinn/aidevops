<?php
/**
 * Safe wp-config.php edits shared by wp-helper.sh payloads (GH#39922).
 *
 * SPDX-License-Identifier: MIT
 * SPDX-FileCopyrightText: 2026 Marcus Quinn
 *
 * Used by wp-config-secret.php (`--config-secret`) and wp-fluentsmtp*.php
 * (`--fluentsmtp`). Locates wp-config.php the way WordPress does, writes
 * single-line constant defines before the "stop editing" anchor, parse-checks
 * the result without exec(), replaces the file atomically with its mode kept,
 * and keeps 0600 backups under the WP-CLI user's HOME, outside the webroot.
 * Values are never printed.
 *
 * @package aidevops
 */

if ( ! class_exists( 'WPAD_Config_Error' ) ) {
	/**
	 * A failure with its exit code (1 refused/unconfirmed, 2 usage/unavailable).
	 */
	class WPAD_Config_Error extends Exception {
	}
}

if ( ! class_exists( 'WPAD_Config_File' ) ) {

	/**
	 * wp-config.php location, constant edits, private writes and backups.
	 */
	final class WPAD_Config_File {

		const ANCHORS = array(
			'/^.*That\'s all, stop editing.*$/m',
			'/^[ \t]*require_once\s*\(?\s*ABSPATH\s*\.\s*[\'"]wp-settings\.php[\'"].*$/m',
		);

		/**
		 * Locate wp-config.php the way WordPress does and require it writable.
		 *
		 * @return string Path.
		 * @throws WPAD_Config_Error When it cannot be found or replaced.
		 */
		public static function wp_config_path() {
			$path = ABSPATH . 'wp-config.php';
			if ( ! file_exists( $path ) && ! file_exists( dirname( ABSPATH ) . '/wp-settings.php' ) ) {
				// WordPress also loads wp-config.php from the parent of a non-nested install.
				$path = dirname( ABSPATH ) . '/wp-config.php';
			}
			if ( ! is_file( $path ) || ! is_readable( $path ) || ! is_writable( dirname( $path ) ) ) {
				throw new WPAD_Config_Error( 'wp-config.php not found or its directory is not writable: ' . $path, 1 );
			}
			return $path;
		}

		/**
		 * Backup root for one tool: the WP-CLI user's home, outside the webroot.
		 *
		 * @param string $tool Subdirectory name, e.g. "fluentsmtp" or "config-secret".
		 * @return string
		 * @throws WPAD_Config_Error Without a usable home directory.
		 */
		public static function backup_root( $tool ) {
			$home = (string) getenv( 'HOME' );
			if ( '' === $home || ! is_dir( $home ) || ! is_writable( $home ) ) {
				throw new WPAD_Config_Error( 'No writable HOME for backups; set HOME for the WP-CLI user', 1 );
			}
			return rtrim( $home, '/' ) . '/.aidevops-backups/' . $tool . '/' . substr( md5( (string) get_option( 'siteurl' ) ), 0, 12 );
		}

		/**
		 * Read a whole file.
		 *
		 * @param string $path File.
		 * @return string
		 * @throws WPAD_Config_Error When it is missing or unreadable.
		 */
		public static function read( $path ) {
			$bytes = is_readable( $path ) ? file_get_contents( $path ) : false;
			if ( false === $bytes ) {
				throw new WPAD_Config_Error( 'Could not read ' . $path, 1 );
			}
			return $bytes;
		}

		/**
		 * Write a file with mode 0600; remove a partial write.
		 *
		 * @param string $path  Destination.
		 * @param string $bytes Content.
		 * @throws WPAD_Config_Error On failure.
		 */
		public static function write_private( $path, $bytes ) {
			$old_umask = umask( 0077 );
			$written   = file_put_contents( $path, $bytes, LOCK_EX );
			umask( $old_umask );
			if ( strlen( $bytes ) !== $written || ! chmod( $path, 0600 ) ) {
				if ( file_exists( $path ) ) {
					unlink( $path );
				}
				throw new WPAD_Config_Error( 'Could not write ' . $path, 1 );
			}
		}

		/**
		 * Parse-check PHP, then replace a file atomically with the given mode.
		 *
		 * The temporary copy must share the target's directory for an atomic
		 * rename, which is often the webroot. Its name ends in ".php" so a copy
		 * left by a killed process executes (printing nothing) instead of being
		 * served as text, and every failure path removes it.
		 *
		 * @param string $path  Destination.
		 * @param string $bytes New content.
		 * @param int    $mode  File mode.
		 * @throws WPAD_Config_Error On a parse error, failed write or failed read-back.
		 */
		public static function replace_php_file( $path, $bytes, $mode ) {
			try {
				token_get_all( $bytes, TOKEN_PARSE );
			} catch ( ParseError $error ) {
				throw new WPAD_Config_Error( 'Refusing to write ' . basename( $path ) . ': parse error on line ' . $error->getLine(), 1 );
			}
			$tmp = dirname( $path ) . '/.' . basename( $path, '.php' ) . '.aidevops-' . wp_generate_password( 8, false ) . '.php';
			self::write_private( $tmp, $bytes );
			if ( ! chmod( $tmp, $mode ) || ! rename( $tmp, $path ) ) {
				unlink( $tmp );
				throw new WPAD_Config_Error( 'Could not replace ' . $path, 1 );
			}
			clearstatcache( true, $path );
			if ( hash_file( 'sha256', $path ) !== hash( 'sha256', $bytes ) ) {
				throw new WPAD_Config_Error( 'Read-back of ' . $path . ' does not match what was written', 1 );
			}
		}

		/**
		 * Whether wp-config.php content mentions a constant name at all.
		 *
		 * @param string $config wp-config.php content.
		 * @param string $name   Constant name.
		 * @return bool
		 */
		public static function mentions( $config, $name ) {
			return 1 === preg_match( '/\b' . preg_quote( $name, '/' ) . '\b/', $config );
		}

		/**
		 * wp-config.php content with the constants set in one marked block
		 * before the "stop editing" anchor.
		 *
		 * Earlier single-line defines of the same names, and the marker line,
		 * are removed first; any other remaining mention refuses, because PHP
		 * keeps the first define and a leftover would silently win.
		 *
		 * @param string $config    Current content.
		 * @param array  $constants Name => string value.
		 * @param string $marker    Comment line that identifies the block.
		 * @return string
		 * @throws WPAD_Config_Error When an old define cannot be replaced or no anchor exists.
		 */
		public static function with_constants( $config, array $constants, $marker ) {
			$config = self::without_constants( $config, array_keys( $constants ), $marker );
			// phpcs:disable WordPress.PHP.DevelopmentFunctions -- var_export() emits safe PHP literals.
			$block = $marker . "\n";
			foreach ( $constants as $name => $value ) {
				$block .= 'define( ' . var_export( (string) $name, true ) . ', ' . var_export( (string) $value, true ) . " );\n";
			}
			$block .= "\n";
			// phpcs:enable
			foreach ( self::ANCHORS as $anchor ) {
				if ( preg_match( $anchor, $config, $match, PREG_OFFSET_CAPTURE ) ) {
					return substr_replace( $config, $block, $match[0][1], 0 );
				}
			}
			throw new WPAD_Config_Error( 'No insertion point in wp-config.php ("stop editing" comment or wp-settings.php require)', 1 );
		}

		/**
		 * Remove the marker line and single-line defines of the names.
		 *
		 * @param string $config wp-config.php content.
		 * @param array  $names  Constant names.
		 * @param string $marker Marker comment line.
		 * @return string
		 * @throws WPAD_Config_Error When another form of a define remains.
		 */
		private static function without_constants( $config, array $names, $marker ) {
			$quoted = implode( '|', array_map( 'preg_quote', $names, array_fill( 0, count( $names ), '/' ) ) );
			$config = preg_replace( '/^[ \t]*' . preg_quote( $marker, '/' ) . '[ \t]*\R/m', '', $config );
			$config = preg_replace( '/^[ \t]*define\(\s*[\'"](?:' . $quoted . ')[\'"]\s*,.*\);[ \t]*\R/m', '', $config );
			foreach ( $names as $name ) {
				if ( self::mentions( $config, $name ) ) {
					throw new WPAD_Config_Error( 'wp-config.php mentions ' . $name . ' in a form this tool cannot replace; edit it by hand', 1 );
				}
			}
			return $config;
		}

		/**
		 * Back up wp-config.php into a new 0600 directory under the tool's root.
		 *
		 * @param string $tool        Backup root name.
		 * @param string $config_path wp-config.php path.
		 * @param array  $extra       Extra meta.json fields.
		 * @return string Backup directory.
		 * @throws WPAD_Config_Error On failure.
		 */
		public static function backup( $tool, $config_path, array $extra = array() ) {
			$dir       = self::backup_root( $tool ) . '/' . gmdate( 'Ymd-His' ) . '-' . wp_generate_password( 6, false );
			$old_umask = umask( 0077 );
			$made      = wp_mkdir_p( $dir );
			umask( $old_umask );
			if ( ! $made ) {
				throw new WPAD_Config_Error( 'Could not create backup directory ' . $dir, 1 );
			}
			$config = self::read( $config_path );
			self::write_private( $dir . '/wp-config.php', $config );
			$meta = array_merge(
				array(
					'siteurl'         => get_option( 'siteurl' ),
					'created'         => gmdate( 'c' ),
					'wpconfig_path'   => $config_path,
					'wpconfig_mode'   => fileperms( $config_path ) & 0777,
					'wpconfig_sha256' => hash( 'sha256', $config ),
				),
				$extra
			);
			self::write_private( $dir . '/meta.json', wp_json_encode( $meta, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES ) );
			return $dir;
		}

		/**
		 * This tool's backups for this site, newest first.
		 *
		 * @param string $tool Backup root name.
		 * @return array
		 */
		public static function backups( $tool ) {
			$root = self::backup_root( $tool );
			$dirs = is_dir( $root ) ? glob( $root . '/*', GLOB_ONLYDIR ) : array();
			$dirs = is_array( $dirs ) ? $dirs : array();
			rsort( $dirs );
			return $dirs;
		}

		/**
		 * Resolve a backup directory and require it under this site's root.
		 *
		 * @param string $tool Backup root name.
		 * @param string $dir  Requested directory.
		 * @return string Real path.
		 * @throws WPAD_Config_Error When it is not one of this site's backups.
		 */
		public static function own_backup_dir( $tool, $dir ) {
			$real = realpath( rtrim( $dir, '/' ) );
			$root = realpath( self::backup_root( $tool ) );
			if ( false === $real || false === $root || 0 !== strpos( $real, $root . '/' ) ) {
				throw new WPAD_Config_Error( 'Backup must be one of this site\'s backups (see: backups)', 2 );
			}
			return $real;
		}

		/**
		 * Read a backup's meta.json and wp-config.php copy and check the checksum
		 * and that it belongs to this site's wp-config.php.
		 *
		 * @param string $dir Backup directory (from own_backup_dir()).
		 * @return array meta, wp-config.php bytes.
		 * @throws WPAD_Config_Error On a foreign, incomplete or altered backup.
		 */
		public static function load_backup( $dir ) {
			$meta = json_decode( self::read( $dir . '/meta.json' ), true );
			if ( ! is_array( $meta ) ) {
				throw new WPAD_Config_Error( 'Backup meta.json is not valid JSON', 1 );
			}
			$config = self::read( $dir . '/wp-config.php' );
			if ( ! isset( $meta['wpconfig_sha256'] ) || hash( 'sha256', $config ) !== $meta['wpconfig_sha256'] ) {
				throw new WPAD_Config_Error( 'Backup wp-config.php does not match its checksum', 1 );
			}
			$path = isset( $meta['wpconfig_path'] ) ? (string) $meta['wpconfig_path'] : '';
			if ( self::wp_config_path() !== $path ) {
				throw new WPAD_Config_Error( 'Backup belongs to ' . $path . ', not this site', 1 );
			}
			return array( $meta, $config );
		}
	}
}
