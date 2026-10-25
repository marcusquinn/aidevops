<?php
/**
 * WordPress change plan: site reads and read-back comparisons.
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

if ( ! class_exists( 'WPCP_Reader' ) ) {

	/**
	 * Stateless site reads shared by evaluation, apply and restore.
	 */
	final class WPCP_Reader {

		const ALT_KEY = '_wp_attachment_image_alt';

		/**
		 * Read back every item of a target after writing.
		 *
		 * @param array $target Target.
		 * @param array $record Applied record.
		 * @return array [record with read-back values, mismatches].
		 */
		public static function read_back( array $target, array $record ) {
			$mismatches = array();
			self::flush_caches( $target['type'], $target['id'], $target['taxonomy'] );
			foreach ( $target['items'] as $item ) {
				$site   = self::read_item( $target['type'], $target['id'], $target['taxonomy'], $item );
				$expect = 'change' === $item['state'] ? $item['stored'] : $item['site'];
				if ( 'delete' === $item['kind'] ) {
					$expect = '';
				}
				if ( ! WPCP_Values::same( $site, $expect ) ) {
					$mismatches[] = WPCP_Values::label( $item ) . ': expected ' . WPCP_Values::show( $expect ) . ', site has ' . WPCP_Values::show( $site );
				}
				foreach ( $record['items'] as $index => $written ) {
					if ( $written['kind'] === $item['kind'] && $written['name'] === $item['name'] ) {
						$record['items'][ $index ]['wrote'] = $site;
					}
				}
			}
			return array( $record, $mismatches );
		}

		/**
		 * Drop caches before a read-back.
		 *
		 * @param string $type     Target type.
		 * @param int    $id       Id.
		 * @param string $taxonomy Taxonomy.
		 */
		public static function flush_caches( $type, $id, $taxonomy ) {
			if ( 'post' === $type ) {
				clean_post_cache( $id );
			} elseif ( '' !== $taxonomy ) {
				clean_term_cache( $id, $taxonomy );
			}
		}

		/**
		 * The current site value of an item.
		 *
		 * @param string $type     Target type.
		 * @param int    $id       Post or term id.
		 * @param string $taxonomy Taxonomy for term targets.
		 * @param array  $item     Item.
		 * @return mixed
		 */
		public static function read_item( $type, $id, $taxonomy, array $item ) {
			$name  = $item['name'];
			$value = null;
			switch ( $item['kind'] ) {
				case 'post':
					$post  = get_post( $id );
					$value = $post ? (string) $post->$name : null;
					break;
				case 'meta':
				case 'acf':
					$value = WPCP_Values::single( get_post_meta( $id, $name, false ) );
					break;
				case 'terms':
					$value = self::post_term_slugs( $id, $name );
					break;
				case 'thumbnail':
					$value = (int) get_post_thumbnail_id( $id );
					break;
				case 'alt':
					$value = (string) WPCP_Values::single( get_post_meta( (int) $name, self::ALT_KEY, false ) );
					break;
				case 'term':
					$term  = get_term( $id, $taxonomy );
					$value = ( $term && ! is_wp_error( $term ) ) ? (string) $term->$name : null;
					break;
				case 'term_meta':
					$value = WPCP_Values::single( get_term_meta( $id, $name, false ) );
					break;
				case 'delete':
					$term  = get_term( $id, $taxonomy );
					$value = ( $term && ! is_wp_error( $term ) ) ? $term->slug : '';
					break;
			}
			return $value;
		}

		/**
		 * A post's term slugs in one taxonomy, sorted.
		 *
		 * @param int    $id       Post id.
		 * @param string $taxonomy Taxonomy.
		 * @return array
		 */
		public static function post_term_slugs( $id, $taxonomy ) {
			$slugs = wp_get_object_terms( $id, $taxonomy, array( 'fields' => 'slugs' ) );
			return is_wp_error( $slugs ) ? array() : WPCP_Values::sorted( $slugs );
		}
	}
}
