<?php
/**
 * WordPress change plan: value comparison and output formatting.
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

if ( ! class_exists( 'WPCP_Values' ) ) {

	/**
	 * Pure helpers that compare, normalize and show plan and site values.
	 */
	final class WPCP_Values {

		/**
		 * Item label such as meta.rank_math_title.
		 *
		 * @param array $item Item.
		 * @return string
		 */
		public static function label( array $item ) {
			return '' === $item['name'] ? $item['kind'] : "{$item['kind']}.{$item['name']}";
		}

		/**
		 * Compare values as WordPress stores them: scalars as strings, arrays recursively.
		 *
		 * @param mixed $a Value.
		 * @param mixed $b Value.
		 * @return bool
		 */
		public static function same( $a, $b ) {
			return self::normalize( $a ) === self::normalize( $b );
		}

		/**
		 * Normalize a value for comparison.
		 *
		 * @param mixed $value Value.
		 * @return mixed
		 */
		public static function normalize( $value ) {
			if ( is_object( $value ) ) {
				$value = get_object_vars( $value );
			}
			if ( is_array( $value ) ) {
				$out = array();
				foreach ( $value as $key => $inner ) {
					$out[ (string) $key ] = self::normalize( $inner );
				}
				return $out;
			}
			if ( null === $value || false === $value ) {
				return '';
			}
			return true === $value ? '1' : (string) $value;
		}

		/**
		 * Short JSON rendering of a value for output.
		 *
		 * @param mixed $value Value.
		 * @return string
		 */
		public static function show( $value ) {
			$text = (string) wp_json_encode( $value, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE );
			return strlen( $text ) > 160 ? substr( $text, 0, 157 ) . '...' : $text;
		}

		/**
		 * The single value of a meta key, '' when absent, the list when several.
		 *
		 * @param array $values Values from get_*_meta( ..., false ).
		 * @return mixed
		 */
		public static function single( $values ) {
			$values = (array) $values;
			if ( count( $values ) > 1 ) {
				return $values;
			}
			return $values ? $values[0] : '';
		}

		/**
		 * Whether a value is a list of strings.
		 *
		 * @param mixed $value Value.
		 * @return bool
		 */
		public static function is_string_list( $value ) {
			if ( ! is_array( $value ) || array_values( $value ) !== $value ) {
				return false;
			}
			foreach ( $value as $inner ) {
				if ( ! is_string( $inner ) || '' === $inner ) {
					return false;
				}
			}
			return true;
		}

		/**
		 * Sorted unique list of strings.
		 *
		 * @param array $list List.
		 * @return array
		 */
		public static function sorted( array $list ) {
			$list = array_values( array_unique( array_map( 'strval', $list ) ) );
			sort( $list, SORT_STRING );
			return $list;
		}
	}
}
