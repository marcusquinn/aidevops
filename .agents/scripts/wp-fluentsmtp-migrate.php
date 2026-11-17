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
 * constants are written into wp-config.php after a backup (WPFS_Backup).
 *
 * @package aidevops
 */

if ( ! class_exists( 'WPFS_Migrate' ) ) {

	/**
	 * Plan and apply a migration.
	 */
	final class WPFS_Migrate {

		const MARKER  = '/* aidevops: FluentSMTP SES keys (wp-helper.sh --fluentsmtp) */';
		const ANCHORS = array(
			'/^.*That\'s all, stop editing.*$/m',
			'/^[ \t]*require_once\s*\(?\s*ABSPATH\s*\.\s*[\'"]wp-settings\.php[\'"].*$/m',
		);

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
			$config = self::config_with_keys( (string) file_get_contents( $config_path ), self::read_keys() );
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
		 * Read and validate the two keys from STDIN.
		 *
		 * @return array access_key, secret_key.
		 * @throws WPFS_Error When the input is missing or malformed.
		 */
		private static function read_keys() {
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
			$settings['mappings']    = array_merge( self::remap_mappings( WPFS_Store::section( $settings, 'mappings' ), $renames, $scope ), self::primary_mappings( $plan ) );
			$settings['misc']        = self::remap_misc( WPFS_Store::section( $settings, 'misc' ), $renames );
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

		/**
		 * Mappings with moved connections' senders on the new domain and key.
		 *
		 * @param array $mappings Sender => key.
		 * @param array $renames  Old key => new key.
		 * @param array $scope    domain (new), from (source domain or '').
		 * @return array
		 */
		private static function remap_mappings( array $mappings, array $renames, array $scope ) {
			$remapped = array();
			foreach ( $mappings as $email => $key ) {
				if ( isset( $renames[ $key ] ) ) {
					$email = self::moved_sender( (string) $email, $scope );
					$key   = $renames[ $key ];
				}
				$remapped[ $email ] = $key;
			}
			return $remapped;
		}

		/**
		 * Every moved connection's primary sender maps to its new key.
		 *
		 * @param array $plan Plan rows.
		 * @return array Sender => key.
		 */
		private static function primary_mappings( array $plan ) {
			return array_combine( array_column( $plan, 'to' ), array_column( $plan, 'key' ) );
		}

		/**
		 * An additional sender on the source domain moves; others stay.
		 *
		 * @param string $email Mapped sender.
		 * @param array  $scope domain (new), from (source domain or '').
		 * @return string
		 */
		private static function moved_sender( $email, array $scope ) {
			$old = WPFS_Store::domain_of( $email );
			if ( '' === $old || ( '' !== $scope['from'] && $old !== $scope['from'] ) ) {
				return $email;
			}
			return WPFS_Store::with_domain( $email, $scope['domain'] );
		}

		/**
		 * Default and fallback references follow renamed connections.
		 *
		 * @param array $misc    Misc settings.
		 * @param array $renames Old key => new key.
		 * @return array
		 */
		private static function remap_misc( array $misc, array $renames ) {
			foreach ( array( 'default_connection', 'fallback_connection' ) as $ref ) {
				$key = WPFS_Store::field( $misc, $ref );
				if ( isset( $renames[ $key ] ) ) {
					$misc[ $ref ] = $renames[ $key ];
				}
			}
			return $misc;
		}

		/**
		 * wp-config.php content with the two constants set before the anchor.
		 *
		 * @param string $config Current content.
		 * @param array  $keys   access_key, secret_key.
		 * @return string
		 * @throws WPFS_Error Without an insertion point.
		 */
		private static function config_with_keys( $config, array $keys ) {
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
