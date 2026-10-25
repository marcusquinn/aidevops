<?php
/**
 * WordPress change plan: site writes through core APIs.
 *
 * SPDX-License-Identifier: MIT
 * SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
 *
 * Loaded by wp-change-plan.php; keep it next to that file.
 *
 * @package aidevops
 */

if ( ! defined( 'ABSPATH' ) ) {
	exit( 2 );
}

if ( ! class_exists( 'WPCP_Writer' ) ) {

	/**
	 * Stateless site writes shared by apply and restore.
	 */
	final class WPCP_Writer {

		const ALT_KEY = '_wp_attachment_image_alt';

		/**
		 * Write post items: ACF fields, terms, meta, thumbnail, alt, then one wp_update_post().
		 *
		 * @param int    $id        Post id.
		 * @param array  $items     Items.
		 * @param string $value_key new (apply) or old (restore).
		 * @param array  $dates     Restored draft dates to resend so WordPress keeps them.
		 * @return array Errors.
		 */
		public static function write_post_items( $id, array $items, $value_key, array $dates = array() ) {
			$errors = array();
			foreach ( array( 'acf', 'terms', 'meta', 'thumbnail', 'alt' ) as $kind ) {
				$errors = array_merge( $errors, self::write_values_of_kind( $id, $items, $kind, $value_key ) );
			}
			$fields = array();
			foreach ( $items as $item ) {
				if ( 'post' === $item['kind'] ) {
					$fields[ $item['name'] ] = $item[ $value_key ];
				}
			}
			if ( $fields ) {
				// Without the dates, wp_update_post() gives a floating draft the current date.
				$error = self::update_post( $id, array_merge( $fields, $dates ) );
				if ( '' !== $error ) {
					$errors[] = $error;
				}
			}
			return $errors;
		}

		/**
		 * Write term items: one wp_update_term(), then term meta.
		 *
		 * @param int    $id        Term id.
		 * @param string $taxonomy  Taxonomy.
		 * @param array  $items     Items.
		 * @param string $value_key new or old.
		 * @return array Errors.
		 */
		public static function write_term_items( $id, $taxonomy, array $items, $value_key ) {
			$errors = array();
			$fields = array();
			foreach ( $items as $item ) {
				if ( 'term' === $item['kind'] ) {
					$fields[ $item['name'] ] = 'parent' === $item['name'] ? (int) $item[ $value_key ] : (string) $item[ $value_key ];
				}
			}
			if ( $fields ) {
				$result = wp_update_term( $id, $taxonomy, wp_slash( $fields ) );
				if ( is_wp_error( $result ) ) {
					$errors[] = 'wp_update_term: ' . $result->get_error_message();
				}
			}
			return array_merge( $errors, self::write_values_of_kind( $id, $items, 'term_meta', $value_key ) );
		}

		/**
		 * Write every item of one kind.
		 *
		 * @param int    $id        Post or term id.
		 * @param array  $items     Items.
		 * @param string $kind      Item kind to write.
		 * @param string $value_key new or old.
		 * @return array Errors.
		 */
		private static function write_values_of_kind( $id, array $items, $kind, $value_key ) {
			$errors = array();
			foreach ( $items as $item ) {
				$error = $kind === $item['kind'] ? self::write_value( $id, $item, $value_key ) : '';
				if ( '' !== $error ) {
					$errors[] = $error;
				}
			}
			return $errors;
		}

		/**
		 * Write one non-row value. Restoring a value that was absent deletes it.
		 *
		 * @param int    $id        Post or term id.
		 * @param array  $item      Item.
		 * @param string $value_key new or old.
		 * @return string Error or ''.
		 */
		private static function write_value( $id, array $item, $value_key ) {
			$kind  = $item['kind'];
			$value = $item[ $value_key ];
			if ( 'terms' === $kind ) {
				return self::write_post_terms( $id, $item['name'], (array) $value );
			}
			$writers = self::value_writers( $id, $item['name'] );
			if ( ! isset( $writers[ $kind ] ) ) {
				return "unknown item kind $kind";
			}
			// A thumbnail of 0 means none; other kinds delete only when restoring an absent value.
			$delete = 'thumbnail' === $kind ? (int) $value <= 0 : ( 'old' === $value_key && ! empty( $item['absent'] ) );
			if ( $delete ) {
				call_user_func( $writers[ $kind ]['delete'] );
			} else {
				call_user_func( $writers[ $kind ]['update'], $value );
			}
			return '';
		}

		/**
		 * Update and delete callbacks for each single-value item kind.
		 *
		 * @param int    $id   Post or term id.
		 * @param string $name Item name (field, meta key or attachment id).
		 * @return array Kind => ['update' => callable( $value ), 'delete' => callable()].
		 */
		private static function value_writers( $id, $name ) {
			$alt_id  = (int) $name;
			$alt_key = self::ALT_KEY;
			return array(
				'acf'       => array(
					'update' => function ( $value ) use ( $id, $name ) {
						update_field( $name, wp_slash( $value ), $id );
					},
					'delete' => function () use ( $id, $name ) {
						delete_field( $name, $id );
					},
				),
				'meta'      => array(
					'update' => function ( $value ) use ( $id, $name ) {
						update_post_meta( $id, $name, wp_slash( $value ) );
					},
					'delete' => function () use ( $id, $name ) {
						delete_post_meta( $id, $name );
					},
				),
				'term_meta' => array(
					'update' => function ( $value ) use ( $id, $name ) {
						update_term_meta( $id, $name, wp_slash( $value ) );
					},
					'delete' => function () use ( $id, $name ) {
						delete_term_meta( $id, $name );
					},
				),
				'thumbnail' => array(
					'update' => function ( $value ) use ( $id ) {
						set_post_thumbnail( $id, (int) $value );
					},
					'delete' => function () use ( $id ) {
						delete_post_thumbnail( $id );
					},
				),
				'alt'       => array(
					'update' => function ( $value ) use ( $alt_id, $alt_key ) {
						update_post_meta( $alt_id, $alt_key, wp_slash( (string) $value ) );
					},
					'delete' => function () use ( $alt_id, $alt_key ) {
						delete_post_meta( $alt_id, $alt_key );
					},
				),
			);
		}

		/**
		 * Replace a post's terms in one taxonomy by slug.
		 *
		 * @param int    $id       Post id.
		 * @param string $taxonomy Taxonomy.
		 * @param array  $slugs    Term slugs.
		 * @return string Error or ''.
		 */
		private static function write_post_terms( $id, $taxonomy, array $slugs ) {
			$ids = array();
			foreach ( $slugs as $slug ) {
				$term = get_term_by( 'slug', $slug, $taxonomy );
				if ( ! $term ) {
					return "terms.$taxonomy: term \"$slug\" no longer exists";
				}
				$ids[] = (int) $term->term_id;
			}
			$result = wp_set_object_terms( $id, $ids, $taxonomy, false );
			return is_wp_error( $result ) ? "terms.$taxonomy: " . $result->get_error_message() : '';
		}

		/**
		 * One wp_update_post() call; an explicit post_date also sets its GMT pair.
		 *
		 * @param int   $id     Post id.
		 * @param array $fields Fields.
		 * @return string Error or ''.
		 */
		public static function update_post( $id, array $fields ) {
			$postarr = array_merge( array( 'ID' => $id ), $fields );
			if ( isset( $fields['post_date'] ) ) {
				$postarr['edit_date'] = true;
				if ( ! isset( $fields['post_date_gmt'] ) ) {
					$postarr['post_date_gmt'] = get_gmt_from_date( $fields['post_date'] );
				}
			}
			$result = wp_update_post( wp_slash( $postarr ), true );
			return is_wp_error( $result ) ? 'wp_update_post: ' . $result->get_error_message() : '';
		}
	}
}
