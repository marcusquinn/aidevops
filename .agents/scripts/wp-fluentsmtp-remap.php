<?php
/**
 * Reference remapping for wp-fluentsmtp.php `migrate`: sender mappings and the
 * default/fallback connection keys follow renamed connections (GH#38865).
 *
 * SPDX-License-Identifier: MIT
 * SPDX-FileCopyrightText: 2026 Marcus Quinn
 *
 * @package aidevops
 */

if ( ! class_exists( 'WPFS_Remap' ) ) {

	/**
	 * Pure transforms over FluentSMTP's mappings and misc sections.
	 */
	final class WPFS_Remap {

		/**
		 * Mappings after a move: moved senders on the new domain and key, plus
		 * each moved connection's primary sender.
		 *
		 * @param array $mappings Sender => key.
		 * @param array $renames  Old key => new key.
		 * @param array $scope    domain (new), from (source domain or '').
		 * @param array $plan     Plan rows (to, key).
		 * @return array
		 */
		public static function mappings( array $mappings, array $renames, array $scope, array $plan ) {
			$remapped = array();
			foreach ( $mappings as $email => $key ) {
				if ( isset( $renames[ $key ] ) ) {
					$email = self::moved_sender( (string) $email, $scope );
					$key   = $renames[ $key ];
				}
				$remapped[ $email ] = $key;
			}
			return array_merge( $remapped, array_combine( array_column( $plan, 'to' ), array_column( $plan, 'key' ) ) );
		}

		/**
		 * Default and fallback references follow renamed connections.
		 *
		 * @param array $misc    Misc settings.
		 * @param array $renames Old key => new key.
		 * @return array
		 */
		public static function misc( array $misc, array $renames ) {
			foreach ( array( 'default_connection', 'fallback_connection' ) as $ref ) {
				$key = WPFS_Store::field( $misc, $ref );
				if ( isset( $renames[ $key ] ) ) {
					$misc[ $ref ] = $renames[ $key ];
				}
			}
			return $misc;
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
	}
}
