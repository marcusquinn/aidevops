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

if ( defined( 'ABSPATH' ) === false ) {
	exit( 2 );
}

if ( class_exists( 'WPCP_Reader' ) === false ) {

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
		public function read_back( array $target, array $record ) {
			$mismatches = array();
			$this->flush_caches( $target['type'], $target['id'], $target['taxonomy'] );
			foreach ( $target['items'] as $item ) {
				$site   = $this->read_item( $target['id'], $target['taxonomy'], $item );
				$expect = 'change' === $item['state'] ? $item['stored'] : $item['site'];
				if ( 'delete' === $item['kind'] ) {
					$expect = '';
				}
				if ( WPCP_Values::same( $site, $expect ) === false ) {
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
		 * @param int    $target_id Post or term id.
		 * @param string $taxonomy Taxonomy.
		 */
		public function flush_caches( $type, $target_id, $taxonomy ) {
			if ( 'post' === $type ) {
				clean_post_cache( $target_id );
			} elseif ( '' !== $taxonomy ) {
				clean_term_cache( $target_id, $taxonomy );
			}
		}

		/**
		 * The current site value of an item.
		 *
		 * @param int    $target_id Post or term id.
		 * @param string $taxonomy Taxonomy for term targets.
		 * @param array  $item     Item.
		 * @return mixed
		 */
		public function read_item( $target_id, $taxonomy, array $item ) {
			$name  = $item['name'];
			$value = null;
			switch ( $item['kind'] ) {
				case 'post':
					$post  = get_post( $target_id );
					$value = $post ? (string) $post->$name : null;
					break;
				case 'meta':
				case 'acf':
					$value = WPCP_Values::single( get_post_meta( $target_id, $name, false ) );
					break;
				case 'terms':
					$value = $this->post_term_slugs( $target_id, $name );
					break;
				case 'thumbnail':
					$value = (int) get_post_thumbnail_id( $target_id );
					break;
				case 'alt':
					$value = (string) WPCP_Values::single( get_post_meta( (int) $name, self::ALT_KEY, false ) );
					break;
				default:
					$value = $this->read_term_item( $target_id, $taxonomy, $item );
					break;
			}
			return $value;
		}

		/**
		 * Read term items, retaining their distinct missing-term fallbacks.
		 *
		 * @param int    $target_id Term id.
		 * @param string $taxonomy Taxonomy.
		 * @param array  $item Item.
		 * @return mixed
		 */
		private function read_term_item( $target_id, $taxonomy, array $item ) {
			$name = $item['name'];
			switch ( $item['kind'] ) {
				case 'term':
					$term = get_term( $target_id, $taxonomy );
					return ( $term && ! is_wp_error( $term ) ) ? (string) $term->$name : null;
				case 'term_meta':
					return WPCP_Values::single( get_term_meta( $target_id, $name, false ) );
				case 'delete':
					$term = get_term( $target_id, $taxonomy );
					return ( $term && ! is_wp_error( $term ) ) ? $term->slug : '';
			}
			return null;
		}

		/**
		 * A post's term slugs in one taxonomy, sorted.
		 *
		 * @param int    $target_id Post id.
		 * @param string $taxonomy Taxonomy.
		 * @return array
		 */
		public function post_term_slugs( $target_id, $taxonomy ) {
			$slugs = wp_get_object_terms( $target_id, $taxonomy, array( 'fields' => 'slugs' ) );
			return is_wp_error( $slugs ) ? array() : WPCP_Values::sorted( $slugs );
		}
	}
}
