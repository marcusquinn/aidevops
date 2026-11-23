<?php
/**
 * Backups for wp-fluentsmtp.php: create, list, and checksum-verified undo (GH#38865).
 *
 * SPDX-License-Identifier: MIT
 * SPDX-FileCopyrightText: 2026 Marcus Quinn
 *
 * A backup is a 0600 directory under the WP-CLI user's
 * ~/.aidevops-backups/fluentsmtp/<site-hash>/ holding the raw option bytes
 * (option.ser), wp-config.php, and meta.json with both SHA-256 checksums.
 *
 * @package aidevops
 */

if ( ! class_exists( 'WPFS_Backup' ) ) {

	/**
	 * Create, list and restore backups.
	 */
	final class WPFS_Backup {

		/**
		 * Back up the raw option and wp-config.php; return the backup directory.
		 *
		 * @param string $config_path wp-config.php path.
		 * @return string
		 * @throws WPFS_Error On failure.
		 */
		public static function create( $config_path ) {
			$dir       = WPFS_Store::backup_root() . '/' . gmdate( 'Ymd-His' ) . '-' . wp_generate_password( 6, false );
			$old_umask = umask( 0077 );
			$made      = wp_mkdir_p( $dir );
			umask( $old_umask );
			if ( ! $made ) {
				throw new WPFS_Error( 'Could not create backup directory ' . $dir, 1 );
			}
			$raw    = WPFS_Store::raw_option();
			$option = serialize( $raw ); // phpcs:ignore WordPress.PHP.DiscouragedPHPFunctions -- exact bytes for undo.
			$config = self::read( $config_path );
			WPFS_Store::write_private( $dir . '/option.ser', $option );
			WPFS_Store::write_private( $dir . '/wp-config.php', $config );
			$meta = array(
				'siteurl'         => get_option( 'siteurl' ),
				'created'         => gmdate( 'c' ),
				'option_present'  => false !== $raw,
				'option_sha256'   => hash( 'sha256', $option ),
				'wpconfig_path'   => $config_path,
				'wpconfig_mode'   => fileperms( $config_path ) & 0777,
				'wpconfig_sha256' => hash( 'sha256', $config ),
			);
			WPFS_Store::write_private( $dir . '/meta.json', wp_json_encode( $meta, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES ) );
			return $dir;
		}

		/**
		 * This site's backups, newest first.
		 *
		 * @return array
		 */
		public static function all() {
			$root = WPFS_Store::backup_root();
			$dirs = is_dir( $root ) ? glob( $root . '/*', GLOB_ONLYDIR ) : array();
			$dirs = is_array( $dirs ) ? $dirs : array();
			rsort( $dirs );
			return array( 'backups' => $dirs );
		}

		/**
		 * Restore the option and wp-config.php from a backup, then verify both.
		 *
		 * @param array $options Parsed options (backup).
		 * @return array
		 * @throws WPFS_Error On a foreign, incomplete or unverifiable backup.
		 */
		public static function undo( array $options ) {
			$dir                            = self::own_dir( $options['backup'] );
			list( $meta, $option, $config ) = self::load( $dir );
			if ( WPFS_Store::field( $meta, 'wpconfig_path' ) !== WPFS_Store::wp_config_path() ) {
				throw new WPFS_Error( 'Backup belongs to ' . WPFS_Store::field( $meta, 'wpconfig_path' ) . ', not this site', 1 );
			}
			WPFS_Store::replace_php_file( $meta['wpconfig_path'], $config, (int) $meta['wpconfig_mode'] );
			self::restore_option( $option, ! empty( $meta['option_present'] ) );
			if ( ! self::restored( $meta ) ) {
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
		 * Resolve a backup directory and require it under this site's root.
		 *
		 * @param string $dir Requested directory.
		 * @return string Real path.
		 * @throws WPFS_Error When it is not one of this site's backups.
		 */
		private static function own_dir( $dir ) {
			$real = realpath( rtrim( $dir, '/' ) );
			$root = realpath( WPFS_Store::backup_root() );
			if ( false === $real || false === $root || 0 !== strpos( $real, $root . '/' ) ) {
				throw new WPFS_Error( 'Backup must be one of this site\'s backups (see: backups)', 2 );
			}
			return $real;
		}

		/**
		 * Read a backup's three files and check both checksums.
		 *
		 * @param string $dir Backup directory.
		 * @return array meta, option bytes, wp-config.php bytes.
		 * @throws WPFS_Error On missing files or a checksum mismatch.
		 */
		private static function load( $dir ) {
			$meta = json_decode( self::read( $dir . '/meta.json' ), true );
			if ( ! is_array( $meta ) ) {
				throw new WPFS_Error( 'Backup meta.json is not valid JSON', 1 );
			}
			$option = self::read( $dir . '/option.ser' );
			$config = self::read( $dir . '/wp-config.php' );
			if ( hash( 'sha256', $option ) !== WPFS_Store::field( $meta, 'option_sha256' ) ) {
				throw new WPFS_Error( 'Backup option.ser does not match its checksum', 1 );
			}
			if ( hash( 'sha256', $config ) !== WPFS_Store::field( $meta, 'wpconfig_sha256' ) ) {
				throw new WPFS_Error( 'Backup wp-config.php does not match its checksum', 1 );
			}
			return array( $meta, $option, $config );
		}

		/**
		 * Read a whole file.
		 *
		 * @param string $path File.
		 * @return string
		 * @throws WPFS_Error When it is missing or unreadable.
		 */
		private static function read( $path ) {
			$bytes = is_readable( $path ) ? file_get_contents( $path ) : false;
			if ( false === $bytes ) {
				throw new WPFS_Error( 'Could not read ' . $path, 1 );
			}
			return $bytes;
		}

		/**
		 * Put the raw option back, or delete it if the backup had none.
		 *
		 * @param string $option  Serialized raw option.
		 * @param bool   $present Whether the option existed.
		 */
		private static function restore_option( $option, $present ) {
			if ( ! $present ) {
				delete_option( WPFS_Store::OPTION );
				return;
			}
			update_option( WPFS_Store::OPTION, unserialize( $option, array( 'allowed_classes' => false ) ) ); // phpcs:ignore WordPress.PHP.DiscouragedPHPFunctions
		}

		/**
		 * Whether the live option and wp-config.php match the backup checksums.
		 *
		 * @param array $meta Backup metadata.
		 * @return bool
		 */
		private static function restored( array $meta ) {
			$option = serialize( WPFS_Store::raw_option() ); // phpcs:ignore WordPress.PHP.DiscouragedPHPFunctions
			if ( hash( 'sha256', $option ) !== $meta['option_sha256'] ) {
				return false;
			}
			return hash_file( 'sha256', $meta['wpconfig_path'] ) === $meta['wpconfig_sha256'];
		}
	}
}
