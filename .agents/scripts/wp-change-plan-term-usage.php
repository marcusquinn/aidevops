<?php
/**
 * WordPress change plan: find what still uses a term before deleting it.
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

if ( ! class_exists( 'WPCP_Term_Usage' ) ) {

	/**
	 * Read-only scan for posts, child terms, nav menu items and ACF/SCF values that use a term.
	 */
	final class WPCP_Term_Usage {

		/**
		 * Everything that still uses a term.
		 *
		 * @param WP_Term $term Term.
		 * @return array Descriptions of uses.
		 */
		public static function describe( $term ) {
			global $wpdb;
			$uses    = array();
			$objects = get_objects_in_term( $term->term_id, $term->taxonomy );
			if ( is_wp_error( $objects ) ) {
				$uses[] = 'could not list objects: ' . $objects->get_error_message();
			} elseif ( $objects ) {
				$uses[] = count( $objects ) . ' post(s) of any status: ' . self::id_list( $objects );
			}
			$children = get_terms(
				array(
					'taxonomy'   => $term->taxonomy,
					'parent'     => $term->term_id,
					'hide_empty' => false,
					'fields'     => 'ids',
				)
			);
			if ( is_array( $children ) && $children ) {
				$uses[] = count( $children ) . ' child term(s): ' . self::id_list( $children );
			}
			$menu_items = $wpdb->get_col(
				$wpdb->prepare(
					"SELECT p.ID FROM {$wpdb->posts} p
					JOIN {$wpdb->postmeta} a ON a.post_id = p.ID AND a.meta_key = '_menu_item_object_id' AND a.meta_value = %s
					JOIN {$wpdb->postmeta} b ON b.post_id = p.ID AND b.meta_key = '_menu_item_object' AND b.meta_value = %s
					WHERE p.post_type = 'nav_menu_item'",
					(string) $term->term_id,
					$term->taxonomy
				)
			);
			if ( $menu_items ) {
				$uses[] = count( $menu_items ) . ' nav menu item(s): ' . self::id_list( $menu_items );
			}
			$acf = self::acf_term_references( $term );
			if ( $acf ) {
				$uses[] = count( $acf ) . ' ACF field value(s): ' . implode( ', ', array_slice( $acf, 0, 10 ) ) . ( count( $acf ) > 10 ? ', ...' : '' );
			}
			return $uses;
		}

		/**
		 * ACF/SCF taxonomy field values that hold the term, found through ACF's
		 * `_name` => field_key reference rows in post, term and user meta and options.
		 *
		 * @param WP_Term $term Term.
		 * @return array Descriptions such as "post 12 regions".
		 */
		private static function acf_term_references( $term ) {
			global $wpdb;
			if ( ! function_exists( 'acf_get_field_groups' ) || ! function_exists( 'acf_get_fields' ) ) {
				return array();
			}
			$keys = array();
			foreach ( acf_get_field_groups() as $group ) {
				self::collect_taxonomy_field_keys( (array) acf_get_fields( $group ), $term->taxonomy, $keys );
			}
			$found  = array();
			$tables = array(
				'post' => array( $wpdb->postmeta, 'post_id', 'meta_key', 'meta_value' ),
				'term' => array( $wpdb->termmeta, 'term_id', 'meta_key', 'meta_value' ),
				'user' => array( $wpdb->usermeta, 'user_id', 'meta_key', 'meta_value' ),
				'option' => array( $wpdb->options, '0', 'option_name', 'option_value' ),
			);
			foreach ( array_unique( $keys ) as $key ) {
				foreach ( $tables as $label => $table ) {
					$found = array_merge( $found, self::acf_table_references( $term, $key, $label, $table ) );
				}
			}
			return $found;
		}

		/**
		 * Values in one meta table that reference an ACF field key and hold the term.
		 *
		 * @param WP_Term $term  Term.
		 * @param string  $key   ACF field key.
		 * @param string  $label post, term, user or option.
		 * @param array   $table [table, object column, key column, value column].
		 * @return array Descriptions such as "post 12 regions".
		 */
		private static function acf_table_references( $term, $key, $label, array $table ) {
			global $wpdb;
			list( $name, $object_col, $key_col, $value_col ) = $table;
			// Table and column names come from $wpdb and the literal list in acf_term_references().
			$refs  = $wpdb->get_results( $wpdb->prepare( "SELECT {$object_col} AS object_id, {$key_col} AS ref_key FROM {$name} WHERE {$value_col} = %s AND {$key_col} LIKE %s", $key, $wpdb->esc_like( '_' ) . '%' ) );
			$found = array();
			foreach ( (array) $refs as $ref ) {
				$value_key = substr( $ref->ref_key, 1 );
				if ( self::value_has_term( self::acf_reference_value( $label, $table, $ref->object_id, $value_key ), $term->term_id ) ) {
					$found[] = 'option' === $label ? "option $value_key" : "$label {$ref->object_id} $value_key";
				}
			}
			return $found;
		}

		/**
		 * The stored value an ACF `_name` => field_key reference row points at.
		 *
		 * @param string $label     post, term, user or option.
		 * @param array  $table     [table, object column, key column, value column].
		 * @param mixed  $object_id Object id from the reference row.
		 * @param string $value_key Meta key or option name holding the value.
		 * @return mixed
		 */
		private static function acf_reference_value( $label, array $table, $object_id, $value_key ) {
			global $wpdb;
			if ( 'option' === $label ) {
				return $wpdb->get_var( $wpdb->prepare( "SELECT option_value FROM {$wpdb->options} WHERE option_name = %s", $value_key ) );
			}
			list( $name, $object_col, $key_col, $value_col ) = $table;
			return $wpdb->get_var( $wpdb->prepare( "SELECT {$value_col} FROM {$name} WHERE {$object_col} = %d AND {$key_col} = %s LIMIT 1", $object_id, $value_key ) );
		}

		/**
		 * Collect keys of taxonomy fields for one taxonomy, including sub fields.
		 *
		 * @param array  $fields   Fields.
		 * @param string $taxonomy Taxonomy.
		 * @param array  $keys     Collected keys (by reference).
		 */
		private static function collect_taxonomy_field_keys( array $fields, $taxonomy, array &$keys ) {
			foreach ( $fields as $field ) {
				if ( isset( $field['type'], $field['taxonomy'] ) && 'taxonomy' === $field['type'] && $taxonomy === $field['taxonomy'] ) {
					$keys[] = $field['key'];
				}
				if ( ! empty( $field['sub_fields'] ) ) {
					self::collect_taxonomy_field_keys( (array) $field['sub_fields'], $taxonomy, $keys );
				}
				if ( ! empty( $field['layouts'] ) ) {
					foreach ( (array) $field['layouts'] as $layout ) {
						self::collect_taxonomy_field_keys( isset( $layout['sub_fields'] ) ? (array) $layout['sub_fields'] : array(), $taxonomy, $keys );
					}
				}
			}
		}

		/**
		 * Whether a stored meta value holds a term id.
		 *
		 * @param mixed $raw     Raw value.
		 * @param int   $term_id Term id.
		 * @return bool
		 */
		private static function value_has_term( $raw, $term_id ) {
			$value = maybe_unserialize( $raw );
			if ( is_array( $value ) ) {
				return in_array( (string) $term_id, array_map( 'strval', array_filter( $value, 'is_scalar' ) ), true );
			}
			return (string) $value === (string) $term_id;
		}

		/**
		 * First ten ids as a comma list.
		 *
		 * @param array $ids Ids.
		 * @return string
		 */
		private static function id_list( array $ids ) {
			return implode( ', ', array_slice( $ids, 0, 10 ) ) . ( count( $ids ) > 10 ? ', ...' : '' );
		}
	}
}
