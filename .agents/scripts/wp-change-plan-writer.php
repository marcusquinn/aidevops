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

if ( defined( 'ABSPATH' ) === false ) {
	exit( 2 );
}

if ( class_exists( 'WPCP_Writer' ) === false ) {

	/**
	 * Stateless site writes shared by apply and restore.
	 */
	final class WPCP_Writer {

		const ALT_KEY = '_wp_attachment_image_alt';

		/**
		 * Write post items: ACF fields, terms, meta, thumbnail, alt, then one wp_update_post().
		 *
		 * @param int    $target_id Post id.
		 * @param array  $items     Items.
		 * @param string $value_key new (apply) or old (restore).
		 * @param array  $dates     Restored draft dates to resend so WordPress keeps them.
		 * @return array Errors.
		 */
		public function write_post_items( $target_id, array $items, $value_key, array $dates = array() ) {
			$errors = array();
			foreach ( array( 'acf', 'terms', 'meta', 'thumbnail', 'alt' ) as $kind ) {
				$errors = array_merge( $errors, $this->write_values_of_kind( $target_id, $items, $kind, $value_key ) );
			}
			$fields = array();
			foreach ( $items as $item ) {
				if ( 'post' === $item['kind'] ) {
					$fields[ $item['name'] ] = $item[ $value_key ];
				}
			}
			if ( $fields !== array() ) {
				// Without the dates, wp_update_post() gives a floating draft the current date.
				$error = $this->update_post( $target_id, array_merge( $fields, $dates ) );
				if ( '' !== $error ) {
					$errors[] = $error;
				}
			}
			return $errors;
		}

		/**
		 * Write term items: one wp_update_term(), then term meta.
		 *
		 * @param int    $target_id Term id.
		 * @param string $taxonomy  Taxonomy.
		 * @param array  $items     Items.
		 * @param string $value_key new or old.
		 * @return array Errors.
		 */
		public function write_term_items( $target_id, $taxonomy, array $items, $value_key ) {
			$errors = array();
			$fields = array();
			foreach ( $items as $item ) {
				if ( 'term' === $item['kind'] ) {
					$fields[ $item['name'] ] = 'parent' === $item['name'] ? (int) $item[ $value_key ] : (string) $item[ $value_key ];
				}
			}
			if ( $fields !== array() ) {
				$result = wp_update_term( $target_id, $taxonomy, wp_slash( $fields ) );
				if ( is_wp_error( $result ) ) {
					$errors[] = 'wp_update_term: ' . $result->get_error_message();
				}
			}
			return array_merge( $errors, $this->write_values_of_kind( $target_id, $items, 'term_meta', $value_key ) );
		}

		/**
		 * Write every item of one kind.
		 *
		 * @param int    $target_id Post or term id.
		 * @param array  $items     Items.
		 * @param string $kind      Item kind to write.
		 * @param string $value_key new or old.
		 * @return array Errors.
		 */
		private function write_values_of_kind( $target_id, array $items, $kind, $value_key ) {
			$errors = array();
			foreach ( $items as $item ) {
				$error = $kind === $item['kind'] ? $this->write_value( $target_id, $item, $value_key ) : '';
				if ( '' !== $error ) {
					$errors[] = $error;
				}
			}
			return $errors;
		}

		/**
		 * Write one non-row value. Restoring a value that was absent deletes it.
		 *
		 * @param int    $target_id Post or term id.
		 * @param array  $item      Item.
		 * @param string $value_key new or old.
		 * @return string Error or ''.
		 */
		private function write_value( $target_id, array $item, $value_key ) {
			$kind  = $item['kind'];
			$value = $item[ $value_key ];
			if ( 'terms' === $kind ) {
				return $this->write_post_terms( $target_id, $item['name'], (array) $value );
			}
			$writers = $this->value_writers( $target_id, $item['name'] );
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
		 * @param int    $target_id Post or term id.
		 * @param string $name Item name (field, meta key or attachment id).
		 * @return array Kind => ['update' => callable( $value ), 'delete' => callable()].
		 */
		private function value_writers( $target_id, $name ) {
			$alt_id  = (int) $name;
			$alt_key = self::ALT_KEY;
			return array(
				'acf'       => array(
					'update' => function ( $value ) use ( $target_id, $name ) {
						update_field( $name, wp_slash( $value ), $target_id );
					},
					'delete' => function () use ( $target_id, $name ) {
						delete_field( $name, $target_id );
					},
				),
				'meta'      => array(
					'update' => function ( $value ) use ( $target_id, $name ) {
						update_post_meta( $target_id, $name, wp_slash( $value ) );
					},
					'delete' => function () use ( $target_id, $name ) {
						delete_post_meta( $target_id, $name );
					},
				),
				'term_meta' => array(
					'update' => function ( $value ) use ( $target_id, $name ) {
						update_term_meta( $target_id, $name, wp_slash( $value ) );
					},
					'delete' => function () use ( $target_id, $name ) {
						delete_term_meta( $target_id, $name );
					},
				),
				'thumbnail' => array(
					'update' => function ( $value ) use ( $target_id ) {
						set_post_thumbnail( $target_id, (int) $value );
					},
					'delete' => function () use ( $target_id ) {
						delete_post_thumbnail( $target_id );
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
		 * @param int    $target_id Post id.
		 * @param string $taxonomy Taxonomy.
		 * @param array  $slugs    Term slugs.
		 * @return string Error or ''.
		 */
		private function write_post_terms( $target_id, $taxonomy, array $slugs ) {
			$ids = array();
			foreach ( $slugs as $slug ) {
				$term = get_term_by( 'slug', $slug, $taxonomy );
				if ( ! $term ) {
					return "terms.$taxonomy: term \"$slug\" no longer exists";
				}
				$ids[] = (int) $term->term_id;
			}
			$result = wp_set_object_terms( $target_id, $ids, $taxonomy, false );
			return is_wp_error( $result ) ? "terms.$taxonomy: " . $result->get_error_message() : '';
		}

		/**
		 * One wp_update_post() call; an explicit post_date also sets its GMT pair.
		 *
		 * @param int   $target_id Post id.
		 * @param array $fields Fields.
		 * @return string Error or ''.
		 */
		public function update_post( $target_id, array $fields ) {
			$postarr = array_merge( array( 'ID' => $target_id ), $fields );
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
