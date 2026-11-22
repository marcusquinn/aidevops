<?php
/**
 * `migrate` for wp-fluentsmtp.php: move SES connections to a new sending
 * domain and region, with keys in wp-config.php (GH#38865).
 *
 * SPDX-License-Identifier: MIT
 * SPDX-FileCopyrightText: 2026 Marcus Quinn
 *
 * Each matching connection's sender becomes local@DOMAIN under FluentSMTP's
 * key md5(sender); mappings and the default/fallback references follow it.
 * key_store becomes wp_config with empty DB keys, and the two FLUENTMAIL_AWS_*
 * constants are written into wp-config.php (WPFS_Config) after a backup
 * (WPFS_Backup).
 *
 * @package aidevops
 */

if ( ! class_exists( 'WPFS_Migrate' ) ) {

	/**
	 * Plan and apply a migration.
	 */
	final class WPFS_Migrate {

		/**
		 * Dry run, or back up and apply.
		 *
		 * @param array $options Parsed options (domain, region, from_domain, dry_run).
		 * @return array
		 */
		public static function run( array $options ) {
			list( $settings, $plan ) = self::plan( WPFS_Store::settings(), $options );
			$config_path             = WPFS_Store::wp_config_path();
			if ( ! empty( $options['dry_run'] ) ) {
				return array(
					'dry_run'   => true,
					'plan'      => $plan,
					'wp_config' => $config_path,
				);
			}
			// Build the new wp-config.php first so a refusal leaves nothing behind.
			$config = WPFS_Config::with_keys( (string) file_get_contents( $config_path ), WPFS_Config::read_keys() );
			$backup = WPFS_Backup::create( $config_path );
			fwrite( STDERR, 'BACKUP: ' . $backup . "\n" );
			WPFS_Store::replace_php_file( $config_path, $config, fileperms( $config_path ) & 0777 );
			fluentMailSetSettings( $settings );
			return array(
				'backup'      => $backup,
				'plan'        => $plan,
				'connections' => self::rows_after(),
				'note'        => 'Constants take effect in the next PHP request; run `test` next.',
			);
		}

		/**
		 * Connections after the write. This process loaded wp-config.php before
		 * the change, so the constants show as arriving with the next request.
		 *
		 * @return array
		 */
		private static function rows_after() {
			$after = WPFS_Cli::action_list();
			$rows  = array();
			foreach ( $after['connections'] as $row ) {
				if ( 'wp_config-missing' === $row['keys'] ) {
					$row['keys'] = 'wp_config-next-request';
				}
				$rows[] = $row;
			}
			return $rows;
		}

		/**
		 * Build the migrated settings and the plan rows.
		 *
		 * @param array $settings Current decrypted settings.
		 * @param array $options  Parsed options.
		 * @return array settings, plan rows.
		 * @throws WPFS_Error When nothing matches or senders collide.
		 */
		private static function plan( array $settings, array $options ) {
			$from        = WPFS_Store::field( $options, 'from_domain' );
			$connections = WPFS_Store::section( $settings, 'connections' );
			$renames     = self::renames( $connections, $options['domain'], $from );
			if ( ! $renames ) {
				throw new WPFS_Error( 'No Amazon SES connection matched' . ( '' !== $from ? ' from_domain=' . $from : '' ), 1 );
			}
			self::check_collisions( $connections, $renames );

			$moved = array();
			$plan  = array();
			foreach ( $connections as $key => $connection ) {
				if ( ! isset( $renames[ $key ] ) ) {
					$moved[ $key ] = $connection;
					continue;
				}
				$moved[ $renames[ $key ] ] = self::moved_connection( $connection, $options );
				$plan[]                    = array(
					'from'   => WPFS_Store::field( WPFS_Store::provider( $connection ), 'sender_email' ),
					'to'     => WPFS_Store::field( WPFS_Store::provider( $moved[ $renames[ $key ] ] ), 'sender_email' ),
					'key'    => $renames[ $key ],
					'region' => $options['region'],
				);
			}
			$settings['connections'] = $moved;
			$scope                   = array(
				'domain' => $options['domain'],
				'from'   => $from,
			);
			$settings['mappings']    = WPFS_Remap::mappings( WPFS_Store::section( $settings, 'mappings' ), $renames, $scope, $plan );
			$settings['misc']        = WPFS_Remap::misc( WPFS_Store::section( $settings, 'misc' ), $renames );
			return array( $settings, $plan );
		}

		/**
		 * Old key => new key for every SES connection on the source domain.
		 *
		 * @param array  $connections Connections by key.
		 * @param string $domain      New domain.
		 * @param string $from        Source domain, or '' for every SES connection.
		 * @return array
		 * @throws WPFS_Error When two connections would share a sender.
		 */
		private static function renames( array $connections, $domain, $from ) {
			$renames = array();
			foreach ( $connections as $key => $connection ) {
				$provider = WPFS_Store::provider( $connection );
				$sender   = WPFS_Store::field( $provider, 'sender_email' );
				if ( ! self::matches( $provider, $sender, $from ) ) {
					continue;
				}
				$new_sender = WPFS_Store::with_domain( $sender, $domain );
				if ( in_array( md5( $new_sender ), $renames, true ) ) {
					throw new WPFS_Error( 'Two connections would share sender ' . $new_sender . '; resolve that in FluentSMTP first', 1 );
				}
				$renames[ $key ] = md5( $new_sender );
			}
			return $renames;
		}

		/**
		 * Whether a connection is an SES connection on the source domain.
		 *
		 * @param array  $provider Provider settings.
		 * @param string $sender   Its sender address.
		 * @param string $from     Source domain, or ''.
		 * @return bool
		 */
		private static function matches( array $provider, $sender, $from ) {
			if ( 'ses' !== WPFS_Store::field( $provider, 'provider' ) || '' === WPFS_Store::domain_of( $sender ) ) {
				return false;
			}
			return '' === $from || WPFS_Store::domain_of( $sender ) === $from;
		}

		/**
		 * Refuse when a new key belongs to a connection that is not moving.
		 *
		 * @param array $connections Connections by key.
		 * @param array $renames     Old key => new key.
		 * @throws WPFS_Error On a collision.
		 */
		private static function check_collisions( array $connections, array $renames ) {
			foreach ( $renames as $old_key => $new_key ) {
				if ( (string) $old_key === $new_key || isset( $renames[ $new_key ] ) || ! isset( $connections[ $new_key ] ) ) {
					continue;
				}
				$sender = WPFS_Store::field( WPFS_Store::provider( $connections[ $new_key ] ), 'sender_email' );
				throw new WPFS_Error( 'A connection for ' . $sender . ' already exists; remove or merge it in FluentSMTP first', 1 );
			}
		}

		/**
		 * The connection on the new domain and region, keys moved to wp-config.php.
		 *
		 * @param array $connection Stored connection.
		 * @param array $options    Parsed options.
		 * @return array
		 */
		private static function moved_connection( array $connection, array $options ) {
			$provider                        = WPFS_Store::provider( $connection );
			$provider['sender_email']        = WPFS_Store::with_domain( $provider['sender_email'], $options['domain'] );
			$provider['region']              = $options['region'];
			$provider['key_store']           = 'wp_config';
			$provider['access_key']          = '';
			$provider['secret_key']          = '';
			$connection['provider_settings'] = $provider;
			return $connection;
		}
	}
}
