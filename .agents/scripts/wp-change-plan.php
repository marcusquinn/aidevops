<?php
/**
 * WordPress change plan: dry run, apply with backup and read-back, restore.
 *
 * SPDX-License-Identifier: MIT
 * SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
 *
 * Run through WP-CLI from the WordPress root (no plugin needed):
 *   wp eval-file wp-change-plan.php PLAN.json                                dry run (default)
 *   wp eval-file wp-change-plan.php PLAN.json apply --user=<id>              write and read back
 *   wp eval-file wp-change-plan.php PLAN.json restore BACKUP.json --user=<id>
 *
 * Exit codes: 0 done, 1 something skipped, stopped or left, 2 usage, plan or permission error.
 * Backups: ~/backups/wp-change-plan/ (override with WP_CHANGE_PLAN_BACKUP_DIR), mode 600.
 * Plan format, rules and traps: .agents/tools/wordpress/wp-change-plan.md
 *
 * @package aidevops
 */

if ( ! defined( 'ABSPATH' ) || ! class_exists( 'WP_CLI' ) ) {
	fwrite( STDERR, "Run through WP-CLI: wp eval-file wp-change-plan.php PLAN.json [apply | restore BACKUP.json]\n" );
	exit( 2 );
}

if ( ! class_exists( 'WPCP_Plan_Error' ) ) {
	/**
	 * A usage, plan or permission error that stops the run before any write.
	 */
	class WPCP_Plan_Error extends Exception {
	}
}

if ( ! class_exists( 'WPCP_Change_Plan' ) ) {

	/**
	 * Evaluates, applies and restores one change plan.
	 */
	final class WPCP_Change_Plan {

		const POST_FIELDS = array( 'post_title', 'post_name', 'post_status', 'post_excerpt', 'post_content', 'post_date', 'post_parent', 'menu_order', 'comment_status', 'ping_status', 'post_author' );
		const INT_FIELDS  = array( 'post_parent', 'menu_order', 'post_author', 'parent' );
		const TERM_FIELDS = array( 'name', 'slug', 'description', 'parent' );
		const POST_KEYS   = array( 'id', 'note', 'post', 'meta', 'acf', 'terms', 'thumbnail', 'alt' );
		const TERM_KEYS   = array( 'taxonomy', 'id', 'note', 'term', 'meta' );
		const DELETE_KEYS = array( 'taxonomy', 'id', 'slug', 'note' );
		const DRAFT_STATI = array( 'draft', 'pending', 'auto-draft' );
		const ACF_COMPLEX = array( 'repeater', 'flexible_content', 'group', 'clone' );
		const ALT_KEY     = '_wp_attachment_image_alt';

		/** @var string Plan file path as given. */
		private $plan_path = '';

		/** @var array Decoded plan. */
		private $plan = array();

		/** @var string Backup file path for this run. */
		private $backup_path = '';

		/** @var array Backup document. */
		private $backup = array();

		/** @var array Taxonomies touched by the plan (keys). */
		private $taxonomies = array();

		/**
		 * Entry point for `wp eval-file`.
		 *
		 * @param array $args Positional arguments after the script path.
		 * @return int Exit code.
		 */
		public static function main( array $args ) {
			$runner = new self();
			try {
				return $runner->run( $args );
			} catch ( WPCP_Plan_Error $e ) {
				WP_CLI::line( 'ERROR: ' . $e->getMessage() );
				return 2;
			}
		}

		/**
		 * Dispatch the mode.
		 *
		 * @param array $args Positional arguments.
		 * @return int Exit code.
		 * @throws WPCP_Plan_Error On usage or plan errors.
		 */
		private function run( array $args ) {
			$this->plan_path = isset( $args[0] ) ? (string) $args[0] : '';
			$mode            = isset( $args[1] ) ? (string) $args[1] : 'dry-run';
			if ( '' === $this->plan_path ) {
				throw new WPCP_Plan_Error( 'usage: wp eval-file wp-change-plan.php PLAN.json [apply | restore BACKUP.json] [--user=<id>]' );
			}
			if ( ! in_array( $mode, array( 'dry-run', 'apply', 'restore' ), true ) ) {
				throw new WPCP_Plan_Error( "unknown mode \"$mode\"; use apply or restore BACKUP.json, or nothing for a dry run" );
			}
			$this->plan = $this->load_json( $this->plan_path, 'plan' );
			$this->validate_plan_shape();

			if ( 'restore' === $mode ) {
				if ( empty( $args[2] ) ) {
					throw new WPCP_Plan_Error( 'restore needs the backup file: PLAN.json restore BACKUP.json' );
				}
				$this->require_writer();
				return $this->restore( (string) $args[2] );
			}

			$apply = 'apply' === $mode;
			if ( $apply ) {
				$this->require_writer();
			} elseif ( ! get_current_user_id() ) {
				WP_CLI::line( 'note: no --user given; stored forms below assume a user without unfiltered_html. Pass the --user you will apply with.' );
			}

			$targets = $this->evaluate_all();
			$skipped = 0;
			$changes = 0;
			foreach ( $targets as $target ) {
				$this->print_target( $target );
				$skipped += $target['skip'] ? 1 : 0;
				$changes += $target['skip'] ? 0 : $this->count_changes( $target );
			}
			WP_CLI::line( sprintf( '%s: %d targets, %d changes to write, %d skipped.', $apply ? 'Apply' : 'Dry run', count( $targets ), $changes, $skipped ) );
			if ( ! $apply ) {
				return $skipped ? 1 : 0;
			}
			return $this->apply( $targets, $skipped );
		}

		// ------------------------------------------------------------------
		// Plan loading and validation.
		// ------------------------------------------------------------------

		/**
		 * Read and decode a JSON file.
		 *
		 * @param string $path  File path.
		 * @param string $label What the file is, for errors.
		 * @return array
		 * @throws WPCP_Plan_Error When unreadable or invalid.
		 */
		private function load_json( $path, $label ) {
			if ( ! is_readable( $path ) ) {
				throw new WPCP_Plan_Error( "$label file not readable: $path" );
			}
			$data = json_decode( (string) file_get_contents( $path ), true );
			if ( ! is_array( $data ) ) {
				throw new WPCP_Plan_Error( "$label file is not a JSON object: $path (" . json_last_error_msg() . ')' );
			}
			return $data;
		}

		/**
		 * Check the plan's top-level shape and target ids.
		 *
		 * @throws WPCP_Plan_Error On a malformed plan.
		 */
		private function validate_plan_shape() {
			foreach ( array_keys( $this->plan ) as $key ) {
				if ( ! in_array( $key, array( 'posts', 'terms', 'delete_terms' ), true ) ) {
					throw new WPCP_Plan_Error( "unknown top-level key \"$key\"; use posts, terms or delete_terms" );
				}
			}
			$total = 0;
			foreach ( array( 'posts', 'terms', 'delete_terms' ) as $section ) {
				$total += $this->validate_section( $section );
			}
			if ( 0 === $total ) {
				throw new WPCP_Plan_Error( 'the plan has no targets' );
			}
			if ( ! empty( $this->plan['delete_terms'] ) && ( ! empty( $this->plan['posts'] ) || ! empty( $this->plan['terms'] ) ) ) {
				throw new WPCP_Plan_Error( 'delete_terms must be a plan of its own; move the deletions to a separate PLAN.json' );
			}
		}

		/**
		 * Check one plan section is a list of entries with unique positive ids.
		 *
		 * @param string $section Section name.
		 * @return int Number of entries.
		 * @throws WPCP_Plan_Error On a malformed section.
		 */
		private function validate_section( $section ) {
			$list = isset( $this->plan[ $section ] ) ? $this->plan[ $section ] : array();
			if ( ! is_array( $list ) || array_values( $list ) !== $list ) {
				throw new WPCP_Plan_Error( "\"$section\" must be a list" );
			}
			$seen = array();
			foreach ( $list as $index => $entry ) {
				if ( ! is_array( $entry ) || ! isset( $entry['id'] ) || ! is_numeric( $entry['id'] ) || (int) $entry['id'] <= 0 ) {
					throw new WPCP_Plan_Error( "$section[$index] needs a positive \"id\"" );
				}
				$key = ( isset( $entry['taxonomy'] ) ? (string) $entry['taxonomy'] : '' ) . ':' . (int) $entry['id'];
				if ( isset( $seen[ $key ] ) ) {
					throw new WPCP_Plan_Error( "$section lists id {$entry['id']} twice; merge the entries" );
				}
				$seen[ $key ] = true;
			}
			return count( $list );
		}

		/**
		 * Require a --user with unfiltered_html for writes.
		 *
		 * @throws WPCP_Plan_Error When the user is missing or lacks the capability.
		 */
		private function require_writer() {
			$user_id = get_current_user_id();
			if ( ! $user_id ) {
				throw new WPCP_Plan_Error( 'apply and restore need --user=<id> of a user with unfiltered_html' );
			}
			if ( ! current_user_can( 'unfiltered_html' ) ) {
				throw new WPCP_Plan_Error( "user $user_id lacks unfiltered_html; KSES would rewrite markup and the read-back would fail" );
			}
		}

		// ------------------------------------------------------------------
		// Evaluation (dry run and the first step of apply).
		// ------------------------------------------------------------------

		/**
		 * Evaluate every target in plan order.
		 *
		 * @return array List of targets.
		 */
		private function evaluate_all() {
			$targets = array();
			foreach ( $this->section( 'posts' ) as $entry ) {
				$targets[] = $this->finalize( $this->evaluate_post( $entry ) );
			}
			foreach ( $this->section( 'terms' ) as $entry ) {
				$targets[] = $this->finalize( $this->evaluate_term( $entry ) );
			}
			foreach ( $this->section( 'delete_terms' ) as $entry ) {
				$targets[] = $this->finalize( $this->evaluate_delete( $entry ) );
			}
			return $targets;
		}

		/**
		 * A plan section as a list.
		 *
		 * @param string $name Section name.
		 * @return array
		 */
		private function section( $name ) {
			return isset( $this->plan[ $name ] ) ? $this->plan[ $name ] : array();
		}

		/**
		 * Start a target record.
		 *
		 * @param string $type     post, term or delete.
		 * @param array  $entry    Plan entry.
		 * @param array  $allowed  Allowed keys.
		 * @return array
		 */
		private function target( $type, array $entry, array $allowed ) {
			$taxonomy = isset( $entry['taxonomy'] ) ? (string) $entry['taxonomy'] : '';
			$id       = (int) $entry['id'];
			$target   = array(
				'type'     => $type,
				'id'       => $id,
				'taxonomy' => $taxonomy,
				'label'    => 'post' === $type ? "post $id" : ( 'delete' === $type ? "delete term $taxonomy $id" : "term $taxonomy $id" ),
				'note'     => isset( $entry['note'] ) ? (string) $entry['note'] : '',
				'items'    => array(),
				'problems' => array(),
				'skip'     => false,
			);
			foreach ( array_keys( $entry ) as $key ) {
				if ( ! in_array( $key, $allowed, true ) ) {
					$target['problems'][] = "unknown key \"$key\"";
				}
			}
			if ( '' !== $taxonomy ) {
				$this->taxonomies[ $taxonomy ] = true;
			}
			return $target;
		}

		/**
		 * Mark a target skipped when anything differs or is refused.
		 *
		 * @param array $target Target.
		 * @return array
		 */
		private function finalize( array $target ) {
			$bad = count( $target['problems'] );
			foreach ( $target['items'] as $item ) {
				$bad += in_array( $item['state'], array( 'differs', 'invalid' ), true ) ? 1 : 0;
			}
			$target['skip'] = $bad > 0;
			return $target;
		}

		/**
		 * A plan section inside a target entry, which must be a JSON object.
		 *
		 * @param array  $entry   Entry.
		 * @param string $key     Section key.
		 * @param array  $target  Target, for problems.
		 * @return array
		 */
		private function entry_map( array $entry, $key, array &$target ) {
			if ( ! isset( $entry[ $key ] ) ) {
				return array();
			}
			if ( ! is_array( $entry[ $key ] ) || ( $entry[ $key ] && array_values( $entry[ $key ] ) === $entry[ $key ] ) ) {
				$target['problems'][] = "\"$key\" must be an object";
				return array();
			}
			return $entry[ $key ];
		}

		/**
		 * Evaluate one post target.
		 *
		 * @param array $entry Plan entry.
		 * @return array Target.
		 */
		private function evaluate_post( array $entry ) {
			$target = $this->target( 'post', $entry, self::POST_KEYS );
			$post   = get_post( $target['id'] );
			if ( ! $post ) {
				$target['problems'][] = 'post not found';
				return $target;
			}
			if ( get_current_user_id() && ! current_user_can( 'edit_post', $post->ID ) ) {
				$target['problems'][] = 'the --user cannot edit this post';
			}
			$fields = $this->entry_map( $entry, 'post', $target );
			foreach ( $fields as $field => $pair ) {
				$target['items'][] = $this->post_field_item( $post, (string) $field, $pair );
			}
			foreach ( $this->entry_map( $entry, 'meta', $target ) as $key => $pair ) {
				$target['items'][] = $this->meta_item( 'meta', (string) $key, $pair, get_post_meta( $post->ID, (string) $key, false ) );
			}
			$term_lists = $this->entry_map( $entry, 'terms', $target );
			foreach ( $this->entry_map( $entry, 'acf', $target ) as $name => $pair ) {
				$target['items'][] = $this->acf_item( $post, (string) $name, $pair, $term_lists );
			}
			foreach ( $term_lists as $taxonomy => $pair ) {
				$target['items'][] = $this->terms_item( $post, (string) $taxonomy, $pair );
			}
			if ( array_key_exists( 'thumbnail', $entry ) ) {
				$target['items'][] = $this->thumbnail_item( $post, $entry['thumbnail'] );
			}
			foreach ( $this->entry_map( $entry, 'alt', $target ) as $attachment_id => $pair ) {
				$target['items'][] = $this->alt_item( (int) $attachment_id, $pair );
			}
			$this->note_publish_date( $target, $fields, $post );
			return $target;
		}

		/**
		 * Warn when a draft is published without a post_date in the plan.
		 *
		 * @param array   $target Target (by reference).
		 * @param array   $fields Plan post fields.
		 * @param WP_Post $post   Post.
		 */
		private function note_publish_date( array &$target, array $fields, $post ) {
			if ( isset( $fields['post_date'] ) || ! in_array( $post->post_status, self::DRAFT_STATI, true ) ) {
				return;
			}
			foreach ( $target['items'] as $index => $item ) {
				if ( 'post' === $item['kind'] && 'post_status' === $item['name'] && 'change' === $item['state'] && in_array( $item['new'], array( 'publish', 'future' ), true ) ) {
					$target['items'][ $index ]['note'] = 'publishing gives the post the current date; add post_date to keep another';
				}
			}
		}

		/**
		 * Evaluate one term target.
		 *
		 * @param array $entry Plan entry.
		 * @return array Target.
		 */
		private function evaluate_term( array $entry ) {
			$target = $this->target( 'term', $entry, self::TERM_KEYS );
			$term   = $this->get_term( $target );
			if ( ! $term ) {
				return $target;
			}
			if ( get_current_user_id() && ! current_user_can( 'edit_term', $term->term_id ) ) {
				$target['problems'][] = 'the --user cannot edit this term';
			}
			foreach ( $this->entry_map( $entry, 'term', $target ) as $field => $pair ) {
				$target['items'][] = $this->term_field_item( $term, (string) $field, $pair );
			}
			foreach ( $this->entry_map( $entry, 'meta', $target ) as $key => $pair ) {
				$target['items'][] = $this->meta_item( 'term_meta', (string) $key, $pair, get_term_meta( $term->term_id, (string) $key, false ) );
			}
			return $target;
		}

		/**
		 * Evaluate one term deletion.
		 *
		 * @param array $entry Plan entry.
		 * @return array Target.
		 */
		private function evaluate_delete( array $entry ) {
			$target = $this->target( 'delete', $entry, self::DELETE_KEYS );
			$slug   = isset( $entry['slug'] ) ? (string) $entry['slug'] : '';
			$item   = array_merge( $this->blank_item( 'delete', $slug ), array( 'now' => $slug, 'new' => '' ) );
			if ( '' === $slug ) {
				$target['problems'][] = '"slug" is required so the deletion checks it deletes the term you reviewed';
			}
			$term = $this->get_term( $target );
			if ( ! $term ) {
				$item['reason'] = 'no such term; it may have been deleted already';
			} else {
				$item['site'] = $term->slug;
				if ( $term->slug !== $slug ) {
					$item['state'] = 'differs';
				} else {
					$item['state'] = 'change';
				}
				foreach ( $this->term_usage( $term ) as $use ) {
					$target['problems'][] = "in use: $use";
				}
				if ( get_current_user_id() && ! current_user_can( 'delete_term', $term->term_id ) ) {
					$target['problems'][] = 'the --user cannot delete this term';
				}
			}
			$target['items'][] = $item;
			return $target;
		}

		/**
		 * Load the target's term or record why not.
		 *
		 * @param array $target Target (by reference).
		 * @return WP_Term|null
		 */
		private function get_term( array &$target ) {
			if ( ! taxonomy_exists( $target['taxonomy'] ) ) {
				$target['problems'][] = 'taxonomy "' . $target['taxonomy'] . '" is not registered';
				return null;
			}
			$term = get_term( $target['id'], $target['taxonomy'] );
			if ( ! $term || is_wp_error( $term ) ) {
				$target['problems'][] = 'term not found in this taxonomy';
				return null;
			}
			return $term;
		}

		/**
		 * An empty item.
		 *
		 * @param string $kind Kind.
		 * @param string $name Field, key, taxonomy or attachment id.
		 * @return array
		 */
		private function blank_item( $kind, $name ) {
			return array(
				'kind'       => $kind,
				'name'       => (string) $name,
				'now'        => null,
				'new'        => null,
				'stored'     => null,
				'site'       => null,
				'absent'     => false,
				'state'      => 'invalid',
				'reason'     => '',
				'note'       => '',
				'save_terms' => '',
			);
		}

		/**
		 * Build an item from a [now, new] pair; state stays invalid when malformed.
		 *
		 * @param string $kind Kind.
		 * @param string $name Name.
		 * @param mixed  $pair Plan value.
		 * @return array
		 */
		private function make_item( $kind, $name, $pair ) {
			$item = $this->blank_item( $kind, $name );
			if ( ! is_array( $pair ) || array_keys( $pair ) !== array( 0, 1 ) ) {
				$item['reason'] = 'a change must be a [now, new] pair';
				return $item;
			}
			$item['now']    = $pair[0];
			$item['new']    = $pair[1];
			$item['stored'] = $pair[1];
			$item['state']  = 'pending';
			return $item;
		}

		/**
		 * Refuse an item.
		 *
		 * @param array  $item   Item.
		 * @param string $reason Why.
		 * @return array
		 */
		private function refuse( array $item, $reason ) {
			$item['state']  = 'invalid';
			$item['reason'] = $reason;
			return $item;
		}

		/**
		 * Compare the site value with the plan and set the state.
		 *
		 * @param array $item Item.
		 * @param mixed $site Value on the site.
		 * @return array
		 */
		private function resolve( array $item, $site ) {
			$item['site'] = $site;
			if ( 'pending' !== $item['state'] ) {
				return $item;
			}
			if ( self::same( $site, $item['new'] ) || self::same( $site, $item['stored'] ) ) {
				$item['state'] = 'unchanged';
			} elseif ( self::same( $site, $item['now'] ) ) {
				$item['state'] = 'change';
			} else {
				$item['state'] = 'differs';
			}
			return $item;
		}

		/**
		 * A post field change.
		 *
		 * @param WP_Post $post  Post.
		 * @param string  $field Field.
		 * @param mixed   $pair  Plan pair.
		 * @return array
		 */
		private function post_field_item( $post, $field, $pair ) {
			$item = $this->make_item( 'post', $field, $pair );
			if ( ! in_array( $field, self::POST_FIELDS, true ) ) {
				return $this->refuse( $item, 'unknown or unsupported post field; allowed: ' . implode( ', ', self::POST_FIELDS ) );
			}
			if ( 'pending' !== $item['state'] ) {
				return $item;
			}
			$error = $this->check_post_value( $field, $item['new'] );
			if ( $error ) {
				return $this->refuse( $item, $error );
			}
			$item['stored'] = $this->stored_post_field( $field, $item['new'], $post->ID );
			return $this->resolve( $item, (string) $post->$field );
		}

		/**
		 * Validate a new post field value.
		 *
		 * @param string $field Field.
		 * @param mixed  $value New value.
		 * @return string Error, or '' when allowed.
		 */
		private function check_post_value( $field, $value ) {
			if ( ! is_scalar( $value ) ) {
				return 'value must be a string or number';
			}
			if ( in_array( $field, self::INT_FIELDS, true ) && ! preg_match( '/^-?\d+$/', (string) $value ) ) {
				return 'value must be an integer';
			}
			$error = '';
			switch ( $field ) {
				case 'post_status':
					$error = in_array( $value, get_post_stati(), true ) ? '' : "unknown post status \"$value\"";
					break;
				case 'post_date':
					$error = preg_match( '/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/', (string) $value ) ? '' : 'post_date must be "YYYY-MM-DD HH:MM:SS" (site time)';
					break;
				case 'comment_status':
				case 'ping_status':
					$error = in_array( $value, array( 'open', 'closed' ), true ) ? '' : 'value must be open or closed';
					break;
				case 'post_parent':
					$error = ( 0 === (int) $value || get_post( (int) $value ) ) ? '' : 'parent post not found';
					break;
				case 'post_author':
					$error = get_userdata( (int) $value ) ? '' : 'author user not found';
					break;
			}
			return $error;
		}

		/**
		 * The form WordPress stores a post field in, for the current user.
		 *
		 * @param string $field Field.
		 * @param mixed  $value New value.
		 * @param int    $id    Post id.
		 * @return string
		 */
		private function stored_post_field( $field, $value, $id ) {
			if ( in_array( $field, self::INT_FIELDS, true ) ) {
				return (string) (int) $value;
			}
			$stored = wp_unslash( sanitize_post_field( $field, wp_slash( (string) $value ), $id, 'db' ) );
			if ( 'post_name' === $field ) {
				$stored = sanitize_title( $stored );
			}
			return (string) $stored;
		}

		/**
		 * A post or term meta change.
		 *
		 * @param string $kind   meta or term_meta.
		 * @param string $key    Meta key.
		 * @param mixed  $pair   Plan pair.
		 * @param array  $values Current values.
		 * @return array
		 */
		private function meta_item( $kind, $key, $pair, $values ) {
			$item = $this->make_item( $kind, $key, $pair );
			if ( '' === $key || '_' === $key[0] ) {
				return $this->refuse( $item, 'hidden meta keys (_...) are refused; use "thumbnail" and "alt" for images' );
			}
			if ( 'pending' !== $item['state'] ) {
				return $item;
			}
			$values = (array) $values;
			if ( count( $values ) > 1 ) {
				return $this->refuse( $item, 'the key has ' . count( $values ) . ' values; only single-value meta is supported' );
			}
			$item['absent'] = ! $values;
			return $this->resolve( $item, $values ? $values[0] : '' );
		}

		/**
		 * An ACF or SCF field change (value as stored).
		 *
		 * @param WP_Post $post       Post.
		 * @param string  $name       Field name.
		 * @param mixed   $pair       Plan pair.
		 * @param array   $term_lists The entry's "terms" section.
		 * @return array
		 */
		private function acf_item( $post, $name, $pair, array $term_lists ) {
			$item = $this->make_item( 'acf', $name, $pair );
			if ( 'pending' !== $item['state'] ) {
				return $item;
			}
			$active = function_exists( 'update_field' ) && function_exists( 'acf_maybe_get_field' );
			$field  = $active ? acf_maybe_get_field( $name, $post->ID, false ) : false;
			$error  = $active ? $this->acf_field_error( $field, $item, $term_lists ) : 'ACF or SCF is not active';
			if ( '' !== $error ) {
				return $this->refuse( $item, $error );
			}
			$values         = get_post_meta( $post->ID, $field['name'], false );
			$item['absent'] = ! $values;
			return $this->resolve( $item, $values ? $values[0] : '' );
		}

		/**
		 * Why an ACF field cannot be changed; records save_terms taxonomies on the item.
		 *
		 * @param array|false $field      ACF field, or false when unknown.
		 * @param array       $item       Item (by reference).
		 * @param array       $term_lists The entry's "terms" section.
		 * @return string Error, or '' when allowed.
		 */
		private function acf_field_error( $field, array &$item, array $term_lists ) {
			if ( ! $field ) {
				return 'unknown ACF field';
			}
			if ( in_array( $field['type'], self::ACF_COMPLEX, true ) ) {
				return "ACF field type {$field['type']} is not supported; change its sub fields by hand";
			}
			if ( 'taxonomy' !== $field['type'] || empty( $field['save_terms'] ) ) {
				return '';
			}
			$taxonomy                      = (string) $field['taxonomy'];
			$item['save_terms']            = $taxonomy;
			$this->taxonomies[ $taxonomy ] = true;
			return isset( $term_lists[ $taxonomy ] ) ? '' : "the field saves terms and replaces all \"$taxonomy\" terms; add the post's complete \"$taxonomy\" terms to \"terms\"";
		}

		/**
		 * A post's complete term list in one taxonomy.
		 *
		 * @param WP_Post $post     Post.
		 * @param string  $taxonomy Taxonomy.
		 * @param mixed   $pair     Plan pair.
		 * @return array
		 */
		private function terms_item( $post, $taxonomy, $pair ) {
			$item = $this->make_item( 'terms', $taxonomy, $pair );
			if ( 'pending' !== $item['state'] ) {
				return $item;
			}
			$this->taxonomies[ $taxonomy ] = true;
			if ( ! taxonomy_exists( $taxonomy ) || ! is_object_in_taxonomy( $post->post_type, $taxonomy ) ) {
				return $this->refuse( $item, "taxonomy is not registered for {$post->post_type}" );
			}
			if ( ! self::is_string_list( $item['now'] ) || ! self::is_string_list( $item['new'] ) ) {
				return $this->refuse( $item, 'terms must be lists of slugs' );
			}
			foreach ( $item['new'] as $slug ) {
				if ( ! get_term_by( 'slug', $slug, $taxonomy ) ) {
					return $this->refuse( $item, "unknown term slug \"$slug\" (the script does not create terms)" );
				}
			}
			$item['now']    = self::sorted( $item['now'] );
			$item['new']    = self::sorted( $item['new'] );
			$item['stored'] = $item['new'];
			return $this->resolve( $item, $this->post_term_slugs( $post->ID, $taxonomy ) );
		}

		/**
		 * The featured image change.
		 *
		 * @param WP_Post $post Post.
		 * @param mixed   $pair Plan pair.
		 * @return array
		 */
		private function thumbnail_item( $post, $pair ) {
			$item = $this->make_item( 'thumbnail', '', $pair );
			if ( 'pending' !== $item['state'] ) {
				return $item;
			}
			if ( ! is_numeric( $item['now'] ) || ! is_numeric( $item['new'] ) ) {
				return $this->refuse( $item, 'thumbnail must be [attachment id, attachment id]; 0 means none' );
			}
			$item['now']    = (int) $item['now'];
			$item['new']    = (int) $item['new'];
			$item['stored'] = $item['new'];
			if ( $item['new'] > 0 && ! wp_attachment_is_image( $item['new'] ) ) {
				return $this->refuse( $item, "attachment {$item['new']} is not an image" );
			}
			return $this->resolve( $item, (int) get_post_thumbnail_id( $post ) );
		}

		/**
		 * An image's alt text change.
		 *
		 * @param int   $attachment_id Attachment id.
		 * @param mixed $pair          Plan pair.
		 * @return array
		 */
		private function alt_item( $attachment_id, $pair ) {
			$item       = $this->make_item( 'alt', (string) $attachment_id, $pair );
			$attachment = get_post( $attachment_id );
			if ( ! $attachment || 'attachment' !== $attachment->post_type ) {
				return $this->refuse( $item, 'not an attachment' );
			}
			if ( 'pending' !== $item['state'] ) {
				return $item;
			}
			if ( ! is_scalar( $item['new'] ) ) {
				return $this->refuse( $item, 'alt text must be a string' );
			}
			if ( get_current_user_id() && ! current_user_can( 'edit_post', $attachment_id ) ) {
				return $this->refuse( $item, 'the --user cannot edit this attachment' );
			}
			$values         = get_post_meta( $attachment_id, self::ALT_KEY, false );
			$item['absent'] = ! $values;
			$item['stored'] = (string) $item['new'];
			return $this->resolve( $item, $values ? (string) $values[0] : '' );
		}

		/**
		 * A term field change.
		 *
		 * @param WP_Term $term  Term.
		 * @param string  $field Field.
		 * @param mixed   $pair  Plan pair.
		 * @return array
		 */
		private function term_field_item( $term, $field, $pair ) {
			$item = $this->make_item( 'term', $field, $pair );
			if ( ! in_array( $field, self::TERM_FIELDS, true ) ) {
				return $this->refuse( $item, 'unknown term field; allowed: ' . implode( ', ', self::TERM_FIELDS ) );
			}
			if ( 'pending' !== $item['state'] ) {
				return $item;
			}
			$error = $this->check_term_value( $term, $field, $item['new'] );
			if ( '' !== $error ) {
				return $this->refuse( $item, $error );
			}
			$item['stored'] = 'parent' === $field
				? (string) (int) $item['new']
				: (string) wp_unslash( sanitize_term_field( $field, wp_slash( (string) $item['new'] ), $term->term_id, $term->taxonomy, 'db' ) );
			return $this->resolve( $item, (string) $term->$field );
		}

		/**
		 * Validate a new term field value.
		 *
		 * @param WP_Term $term  Term.
		 * @param string  $field Field.
		 * @param mixed   $value New value.
		 * @return string Error, or '' when allowed.
		 */
		private function check_term_value( $term, $field, $value ) {
			if ( ! is_scalar( $value ) ) {
				return 'value must be a string or number';
			}
			$parent = (int) $value;
			if ( 'parent' === $field && ( $parent === (int) $term->term_id || ( $parent > 0 && ! get_term( $parent, $term->taxonomy ) ) ) ) {
				return 'parent term not found in this taxonomy';
			}
			if ( 'name' === $field && '' === trim( (string) $value ) ) {
				return 'a term name cannot be empty';
			}
			return '';
		}

		/**
		 * Everything that still uses a term.
		 *
		 * @param WP_Term $term Term.
		 * @return array Descriptions of uses.
		 */
		private function term_usage( $term ) {
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
			$acf = $this->acf_term_references( $term );
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
		private function acf_term_references( $term ) {
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
					$found = array_merge( $found, $this->acf_table_references( $term, $key, $label, $table ) );
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
		private function acf_table_references( $term, $key, $label, array $table ) {
			global $wpdb;
			list( $name, $object_col, $key_col, $value_col ) = $table;
			// Table and column names come from $wpdb and the literal list in acf_term_references().
			$refs  = $wpdb->get_results( $wpdb->prepare( "SELECT {$object_col} AS object_id, {$key_col} AS ref_key FROM {$name} WHERE {$value_col} = %s AND {$key_col} LIKE %s", $key, $wpdb->esc_like( '_' ) . '%' ) );
			$found = array();
			foreach ( (array) $refs as $ref ) {
				$value_key = substr( $ref->ref_key, 1 );
				if ( self::value_has_term( $this->acf_reference_value( $label, $table, $ref->object_id, $value_key ), $term->term_id ) ) {
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
		private function acf_reference_value( $label, array $table, $object_id, $value_key ) {
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

		// ------------------------------------------------------------------
		// Apply.
		// ------------------------------------------------------------------

		/**
		 * Back up, write, and read back each target in plan order.
		 *
		 * @param array $targets Evaluated targets.
		 * @param int   $skipped Number of skipped targets.
		 * @return int Exit code.
		 * @throws WPCP_Plan_Error When the backup cannot be written.
		 */
		private function apply( array $targets, $skipped ) {
			$writable = array();
			foreach ( $targets as $target ) {
				if ( ! $target['skip'] && $this->count_changes( $target ) > 0 ) {
					$writable[] = $this->mark_forced_terms( $target );
				}
			}
			if ( ! $writable ) {
				WP_CLI::line( 'Nothing to write.' );
				return $skipped ? 1 : 0;
			}
			$this->create_backup( $writable );
			foreach ( $writable as $index => $target ) {
				$key                               = $target['type'] . ':' . $target['taxonomy'] . ':' . $target['id'];
				$record                            = $this->applied_record( $target );
				$this->backup['applied'][ $key ]   = $record;
				$this->save_backup();
				$errors                            = $this->write_target( $target );
				list( $record, $mismatches )       = $this->read_back( $target, $record );
				$record['status']                  = ( $errors || $mismatches ) ? 'mismatch' : 'applied';
				$this->backup['applied'][ $key ]   = $record;
				$this->save_backup();
				if ( $errors || $mismatches ) {
					foreach ( array_merge( $errors, $mismatches ) as $line ) {
						WP_CLI::line( "STOP {$target['label']}: $line" );
					}
					$untouched = count( $writable ) - $index - 1;
					WP_CLI::line( "Stopped at {$target['label']}; $untouched later target(s) left untouched." );
					$this->print_restore_hint();
					$this->print_follow_ups();
					return 1;
				}
				WP_CLI::line( "OK {$target['label']}: written and read back." );
			}
			$this->print_restore_hint();
			$this->print_follow_ups();
			return $skipped ? 1 : 0;
		}

		/**
		 * Number of items that will be written.
		 *
		 * @param array $target Target.
		 * @return int
		 */
		private function count_changes( array $target ) {
			$count = 0;
			foreach ( $target['items'] as $item ) {
				$count += 'change' === $item['state'] ? 1 : 0;
			}
			return $count;
		}

		/**
		 * Mark unchanged term lists for write when a changed save-terms ACF field
		 * would replace that taxonomy's terms.
		 *
		 * @param array $target Target.
		 * @return array
		 */
		private function mark_forced_terms( array $target ) {
			$replaced = array();
			foreach ( $target['items'] as $item ) {
				if ( 'acf' === $item['kind'] && 'change' === $item['state'] && '' !== $item['save_terms'] ) {
					$replaced[ $item['save_terms'] ] = true;
				}
			}
			foreach ( $target['items'] as $index => $item ) {
				if ( 'terms' === $item['kind'] && 'unchanged' === $item['state'] && isset( $replaced[ $item['name'] ] ) ) {
					$target['items'][ $index ]['state']  = 'change';
					$target['items'][ $index ]['stored'] = $item['site'];
					$target['items'][ $index ]['new']    = $item['site'];
				}
			}
			return $target;
		}

		/**
		 * The applied record kept in the backup: old value and value written per item.
		 *
		 * @param array $target Target.
		 * @return array
		 */
		private function applied_record( array $target ) {
			$items = array();
			foreach ( $target['items'] as $item ) {
				if ( 'change' !== $item['state'] ) {
					continue;
				}
				$items[] = array(
					'kind'       => $item['kind'],
					'name'       => $item['name'],
					'old'        => $item['site'],
					'absent'     => $item['absent'],
					'wrote'      => 'delete' === $item['kind'] ? '' : $item['stored'],
					'save_terms' => $item['save_terms'],
				);
			}
			return array(
				'type'     => $target['type'],
				'id'       => $target['id'],
				'taxonomy' => $target['taxonomy'],
				'label'    => $target['label'],
				'status'   => 'pending',
				'items'    => $items,
			);
		}

		/**
		 * Write one target's changes through core APIs.
		 *
		 * @param array $target Target.
		 * @return array Errors.
		 */
		private function write_target( array $target ) {
			$items = array();
			foreach ( $target['items'] as $item ) {
				if ( 'change' === $item['state'] ) {
					$items[] = $item;
				}
			}
			if ( 'delete' === $target['type'] ) {
				$result = wp_delete_term( $target['id'], $target['taxonomy'] );
				return ( true === $result ) ? array() : array( 'wp_delete_term failed' . ( is_wp_error( $result ) ? ': ' . $result->get_error_message() : '' ) );
			}
			if ( 'term' === $target['type'] ) {
				return $this->write_term_items( $target['id'], $target['taxonomy'], $items, 'new' );
			}
			return $this->write_post_items( $target['id'], $items, 'new' );
		}

		/**
		 * Write post items: ACF fields, terms, meta, thumbnail, alt, then one wp_update_post().
		 *
		 * @param int    $id        Post id.
		 * @param array  $items     Items.
		 * @param string $value_key new (apply) or old (restore).
		 * @param array  $dates     Restored draft dates to resend so WordPress keeps them.
		 * @return array Errors.
		 */
		private function write_post_items( $id, array $items, $value_key, array $dates = array() ) {
			$errors = array();
			foreach ( array( 'acf', 'terms', 'meta', 'thumbnail', 'alt' ) as $kind ) {
				$errors = array_merge( $errors, $this->write_values_of_kind( $id, $items, $kind, $value_key ) );
			}
			$fields = array();
			foreach ( $items as $item ) {
				if ( 'post' === $item['kind'] ) {
					$fields[ $item['name'] ] = $item[ $value_key ];
				}
			}
			if ( $fields ) {
				// Without the dates, wp_update_post() gives a floating draft the current date.
				$error = $this->update_post( $id, array_merge( $fields, $dates ) );
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
		private function write_term_items( $id, $taxonomy, array $items, $value_key ) {
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
			return array_merge( $errors, $this->write_values_of_kind( $id, $items, 'term_meta', $value_key ) );
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
		private function write_values_of_kind( $id, array $items, $kind, $value_key ) {
			$errors = array();
			foreach ( $items as $item ) {
				$error = $kind === $item['kind'] ? $this->write_value( $id, $item, $value_key ) : '';
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
		private function write_value( $id, array $item, $value_key ) {
			$kind  = $item['kind'];
			$value = $item[ $value_key ];
			if ( 'terms' === $kind ) {
				return $this->write_post_terms( $id, $item['name'], (array) $value );
			}
			$writers = $this->value_writers( $id, $item['name'] );
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
		private function value_writers( $id, $name ) {
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
		private function write_post_terms( $id, $taxonomy, array $slugs ) {
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
		private function update_post( $id, array $fields ) {
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

		/**
		 * Read back every item of a target after writing.
		 *
		 * @param array $target Target.
		 * @param array $record Applied record.
		 * @return array [record with read-back values, mismatches].
		 */
		private function read_back( array $target, array $record ) {
			$mismatches = array();
			$this->flush_caches( $target['type'], $target['id'], $target['taxonomy'] );
			foreach ( $target['items'] as $item ) {
				$site   = $this->read_item( $target['type'], $target['id'], $target['taxonomy'], $item );
				$expect = 'change' === $item['state'] ? $item['stored'] : $item['site'];
				if ( 'delete' === $item['kind'] ) {
					$expect = '';
				}
				if ( ! self::same( $site, $expect ) ) {
					$mismatches[] = self::label( $item ) . ': expected ' . self::show( $expect ) . ', site has ' . self::show( $site );
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
		private function flush_caches( $type, $id, $taxonomy ) {
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
		private function read_item( $type, $id, $taxonomy, array $item ) {
			$name  = $item['name'];
			$value = null;
			switch ( $item['kind'] ) {
				case 'post':
					$post  = get_post( $id );
					$value = $post ? (string) $post->$name : null;
					break;
				case 'meta':
				case 'acf':
					$value = self::single( get_post_meta( $id, $name, false ) );
					break;
				case 'terms':
					$value = $this->post_term_slugs( $id, $name );
					break;
				case 'thumbnail':
					$value = (int) get_post_thumbnail_id( $id );
					break;
				case 'alt':
					$value = (string) self::single( get_post_meta( (int) $name, self::ALT_KEY, false ) );
					break;
				case 'term':
					$term  = get_term( $id, $taxonomy );
					$value = ( $term && ! is_wp_error( $term ) ) ? (string) $term->$name : null;
					break;
				case 'term_meta':
					$value = self::single( get_term_meta( $id, $name, false ) );
					break;
				case 'delete':
					$term  = get_term( $id, $taxonomy );
					$value = ( $term && ! is_wp_error( $term ) ) ? $term->slug : '';
					break;
			}
			return $value;
		}

		// ------------------------------------------------------------------
		// Backup.
		// ------------------------------------------------------------------

		/**
		 * Save the backup before the first write.
		 *
		 * @param array $targets Targets that will be written.
		 * @throws WPCP_Plan_Error When the backup cannot be written.
		 */
		private function create_backup( array $targets ) {
			$this->backup = array(
				'tool'          => 'wp-change-plan',
				'version'       => 1,
				'created_utc'   => gmdate( 'c' ),
				'site_url'      => home_url( '/' ),
				'user_id'       => get_current_user_id(),
				'plan_file'     => basename( $this->plan_path ),
				'plan_sha256'   => hash_file( 'sha256', $this->plan_path ),
				'plan'          => $this->plan,
				'posts'         => array(),
				'attachments'   => array(),
				'terms'         => array(),
				'deleted_terms' => array(),
				'applied'       => array(),
			);
			foreach ( $targets as $target ) {
				if ( 'post' === $target['type'] ) {
					$this->backup_post( $target );
				} else {
					$term = get_term( $target['id'], $target['taxonomy'] );
					$copy = array(
						'taxonomy' => $target['taxonomy'],
						'row'      => (array) $term->data,
						'meta'     => get_term_meta( $target['id'] ),
					);
					$this->backup[ 'delete' === $target['type'] ? 'deleted_terms' : 'terms' ][ (string) $target['id'] ] = $copy;
				}
			}
			$this->backup_path = $this->backup_file_path();
			$this->save_backup();
			WP_CLI::line( 'BACKUP: ' . $this->backup_path );
		}

		/**
		 * Copy a post's row, all meta, touched terms and image alt texts into the backup.
		 *
		 * @param array $target Post target.
		 */
		private function backup_post( array $target ) {
			$id    = $target['id'];
			$terms = array();
			$alts  = array();
			foreach ( $target['items'] as $item ) {
				$taxonomy = 'terms' === $item['kind'] ? $item['name'] : $item['save_terms'];
				if ( '' !== $taxonomy && taxonomy_exists( $taxonomy ) ) {
					$terms[ $taxonomy ] = wp_get_object_terms( $id, $taxonomy, array( 'fields' => 'id=>slug' ) );
				}
				if ( 'alt' === $item['kind'] ) {
					$alts[] = (int) $item['name'];
				}
				if ( 'thumbnail' === $item['kind'] ) {
					$alts[] = (int) $item['site'];
					$alts[] = (int) $item['new'];
				}
			}
			$this->backup['posts'][ (string) $id ] = array(
				'row'   => get_post( $id, ARRAY_A ),
				'meta'  => get_post_meta( $id ),
				'terms' => $terms,
			);
			foreach ( array_filter( array_unique( $alts ) ) as $attachment_id ) {
				$this->backup['attachments'][ (string) $attachment_id ] = array( 'alt' => get_post_meta( $attachment_id, self::ALT_KEY, false ) );
			}
		}

		/**
		 * Backup path outside the web root: ~/backups/wp-change-plan/before-<UTC>-<pid>.json.
		 *
		 * @return string
		 * @throws WPCP_Plan_Error When no safe directory is available.
		 */
		private function backup_file_path() {
			$dir = (string) getenv( 'WP_CHANGE_PLAN_BACKUP_DIR' );
			if ( '' === $dir ) {
				$home = (string) getenv( 'HOME' );
				if ( '' === $home && function_exists( 'posix_getpwuid' ) && function_exists( 'posix_geteuid' ) ) {
					$info = posix_getpwuid( posix_geteuid() );
					$home = isset( $info['dir'] ) ? (string) $info['dir'] : '';
				}
				if ( '' === $home ) {
					throw new WPCP_Plan_Error( 'cannot find the home directory for backups; set WP_CHANGE_PLAN_BACKUP_DIR' );
				}
				$dir = rtrim( $home, '/' ) . '/backups/wp-change-plan';
			}
			if ( ! is_dir( $dir ) && ! mkdir( $dir, 0700, true ) ) {
				throw new WPCP_Plan_Error( "cannot create backup directory $dir" );
			}
			chmod( $dir, 0700 );
			$real = realpath( $dir );
			$root = realpath( ABSPATH );
			if ( false === $real ) {
				throw new WPCP_Plan_Error( "cannot resolve backup directory $dir" );
			}
			if ( false !== $root && 0 === strpos( $real . '/', rtrim( $root, '/' ) . '/' ) ) {
				throw new WPCP_Plan_Error( "backup directory $real is inside the web root; set WP_CHANGE_PLAN_BACKUP_DIR outside it" );
			}
			return $real . '/before-' . gmdate( 'Ymd\THis\Z' ) . '-' . getmypid() . '.json';
		}

		/**
		 * Write the backup atomically with mode 600.
		 *
		 * @throws WPCP_Plan_Error When encoding or writing fails.
		 */
		private function save_backup() {
			$json = wp_json_encode( $this->backup, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_INVALID_UTF8_SUBSTITUTE );
			if ( false === $json ) {
				throw new WPCP_Plan_Error( 'cannot encode the backup as JSON: ' . json_last_error_msg() );
			}
			$tmp   = $this->backup_path . '.tmp';
			$umask = umask( 0077 );
			$bytes = file_put_contents( $tmp, $json . "\n", LOCK_EX );
			umask( $umask );
			if ( false === $bytes || ! chmod( $tmp, 0600 ) || ! rename( $tmp, $this->backup_path ) ) {
				throw new WPCP_Plan_Error( "cannot write backup {$this->backup_path}" );
			}
		}

		// ------------------------------------------------------------------
		// Restore.
		// ------------------------------------------------------------------

		/**
		 * Put back each value that still holds what apply wrote.
		 *
		 * @param string $backup_path Backup file.
		 * @return int Exit code.
		 * @throws WPCP_Plan_Error On a bad backup file.
		 */
		private function restore( $backup_path ) {
			$backup = $this->load_json( $backup_path, 'backup' );
			if ( ! isset( $backup['tool'] ) || 'wp-change-plan' !== $backup['tool'] ) {
				throw new WPCP_Plan_Error( "not a wp-change-plan backup: $backup_path" );
			}
			if ( isset( $backup['plan_sha256'] ) && hash_file( 'sha256', $this->plan_path ) !== $backup['plan_sha256'] ) {
				WP_CLI::line( 'note: PLAN.json differs from the plan this backup was made for; restoring from the backup record.' );
			}
			$this->backup = $backup;
			$applied      = isset( $backup['applied'] ) ? (array) $backup['applied'] : array();
			if ( ! $applied ) {
				WP_CLI::line( 'The backup records no applied changes; nothing to restore.' );
				return 0;
			}
			$left = 0;
			foreach ( $applied as $record ) {
				$left += 'delete' === $record['type'] ? $this->restore_deleted( $record ) : $this->restore_record( $record );
			}
			WP_CLI::line( $left ? "Restore finished; $left value(s) left as they are." : 'Restore finished; every value is back.' );
			$this->print_follow_ups();
			return $left ? 1 : 0;
		}

		/**
		 * Restore one post or term target.
		 *
		 * @param array $record Applied record.
		 * @return int Values left.
		 */
		private function restore_record( array $record ) {
			$type     = $record['type'];
			$id       = (int) $record['id'];
			$taxonomy = (string) $record['taxonomy'];
			$this->flush_caches( $type, $id, $taxonomy );
			if ( '' !== $taxonomy ) {
				$this->taxonomies[ $taxonomy ] = true;
			}
			// Decide every item against the site before writing anything.
			list( $revert, $left ) = $this->restore_candidates( $record );
			if ( ! $revert ) {
				return $left;
			}
			if ( 'term' === $type ) {
				$errors = $this->write_term_items( $id, $taxonomy, $revert, 'old' );
			} else {
				// $revert keeps post_status so the read-back below still checks it.
				list( $errors, $writes, $dates ) = $this->restore_post_status( $id, $revert );
				$errors                          = array_merge( $errors, $this->write_post_items( $id, $writes, 'old', $dates ) );
			}
			foreach ( $errors as $error ) {
				WP_CLI::line( "{$record['label']}: $error" );
			}
			$this->flush_caches( $type, $id, $taxonomy );
			return $left + $this->restore_read_back( $record, $revert );
		}

		/**
		 * Split a record's items into those still holding what apply wrote and those left.
		 *
		 * @param array $record Applied record.
		 * @return array [items to revert, number of values left as they are].
		 */
		private function restore_candidates( array $record ) {
			$revert = array();
			$left   = 0;
			foreach ( $record['items'] as $item ) {
				$site  = $this->read_item( $record['type'], (int) $record['id'], (string) $record['taxonomy'], $item );
				$label = "{$record['label']} " . self::label( $item );
				if ( 'terms' === $item['kind'] ) {
					$this->taxonomies[ $item['name'] ] = true;
				}
				if ( self::same( $site, $item['wrote'] ) ) {
					$revert[] = $item;
				} elseif ( self::same( $site, $item['old'] ) ) {
					WP_CLI::line( "$label: already back" );
				} else {
					WP_CLI::line( "$label: changed since, site has " . self::show( $site ) . '; left as is' );
					++$left;
				}
			}
			return array( $revert, $left );
		}

		/**
		 * Read back reverted items and report each one.
		 *
		 * @param array $record Applied record.
		 * @param array $revert Items that were reverted.
		 * @return int Values whose read-back differs.
		 */
		private function restore_read_back( array $record, array $revert ) {
			$left = 0;
			foreach ( $revert as $item ) {
				$site  = $this->read_item( $record['type'], (int) $record['id'], (string) $record['taxonomy'], $item );
				$label = "{$record['label']} " . self::label( $item );
				if ( self::same( $site, $item['old'] ) || ( ! empty( $item['absent'] ) && self::same( $site, '' ) ) ) {
					WP_CLI::line( "$label: restored " . self::show( $item['old'] ) );
				} else {
					WP_CLI::line( "$label: restore read-back differs, site has " . self::show( $site ) );
					++$left;
				}
			}
			return $left;
		}

		/**
		 * Restore post_status first, with the draft's original dates.
		 *
		 * @param int   $id     Post id.
		 * @param array $revert Items to revert.
		 * @return array [errors, items still to write, restored draft dates].
		 */
		private function restore_post_status( $id, array $revert ) {
			foreach ( $revert as $index => $item ) {
				if ( 'post' !== $item['kind'] || 'post_status' !== $item['name'] ) {
					continue;
				}
				unset( $revert[ $index ] );
				$dates = $this->draft_dates( $id, $item['old'], $revert );
				$error = $this->update_post( $id, array_merge( array( 'post_status' => $item['old'] ), $dates ) );
				return array( '' === $error ? array() : array( $error ), $revert, $dates );
			}
			return array( array(), $revert, array() );
		}

		/**
		 * The backed-up dates of a post being restored to a draft status, unless the
		 * plan restores post_date itself.
		 *
		 * @param int    $id     Post id.
		 * @param string $status Status being restored.
		 * @param array  $revert Other items being restored.
		 * @return array post_date and post_date_gmt, or empty.
		 */
		private function draft_dates( $id, $status, array $revert ) {
			$row = isset( $this->backup['posts'][ (string) $id ]['row'] ) ? $this->backup['posts'][ (string) $id ]['row'] : array();
			if ( ! in_array( $status, self::DRAFT_STATI, true ) || ! isset( $row['post_date'], $row['post_date_gmt'] ) || $this->record_has( $revert, 'post', 'post_date' ) ) {
				return array();
			}
			return array(
				'post_date'     => $row['post_date'],
				'post_date_gmt' => $row['post_date_gmt'],
			);
		}

		/**
		 * Whether a list of items has a given kind and name.
		 *
		 * @param array  $items Items.
		 * @param string $kind  Kind.
		 * @param string $name  Name.
		 * @return bool
		 */
		private function record_has( array $items, $kind, $name ) {
			foreach ( $items as $item ) {
				if ( $kind === $item['kind'] && $name === $item['name'] ) {
					return true;
				}
			}
			return false;
		}

		/**
		 * Recreate a deleted term from the backup; WordPress gives it a new id.
		 *
		 * @param array $record Applied record.
		 * @return int Values left.
		 */
		private function restore_deleted( array $record ) {
			$id       = (int) $record['id'];
			$taxonomy = (string) $record['taxonomy'];
			$copy     = isset( $this->backup['deleted_terms'][ (string) $id ] ) ? $this->backup['deleted_terms'][ (string) $id ] : null;
			$this->taxonomies[ $taxonomy ] = true;
			if ( ! $copy ) {
				WP_CLI::line( "{$record['label']}: no copy in the backup; left as is" );
				return 1;
			}
			$row = $copy['row'];
			if ( get_term( $id, $taxonomy ) instanceof WP_Term ) {
				WP_CLI::line( "{$record['label']}: the term still exists; nothing to restore" );
				return 0;
			}
			if ( term_exists( $row['slug'], $taxonomy ) ) {
				WP_CLI::line( "{$record['label']}: a term with slug \"{$row['slug']}\" exists again; left as is" );
				return 1;
			}
			$parent = (int) $row['parent'];
			$result = wp_insert_term(
				wp_slash( $row['name'] ),
				$taxonomy,
				array(
					'slug'        => $row['slug'],
					'description' => wp_slash( $row['description'] ),
					'parent'      => ( $parent > 0 && get_term( $parent, $taxonomy ) ) ? $parent : 0,
				)
			);
			if ( is_wp_error( $result ) ) {
				WP_CLI::line( "{$record['label']}: wp_insert_term failed: " . $result->get_error_message() );
				return 1;
			}
			$new_id = (int) $result['term_id'];
			foreach ( (array) $copy['meta'] as $key => $values ) {
				foreach ( (array) $values as $value ) {
					add_term_meta( $new_id, $key, wp_slash( maybe_unserialize( $value ) ) );
				}
			}
			WP_CLI::line( "RECREATED {$record['label']} as term $new_id (WordPress does not reuse term ids; update references to $id)" );
			return 0;
		}

		// ------------------------------------------------------------------
		// Output.
		// ------------------------------------------------------------------

		/**
		 * Print a target and its items.
		 *
		 * @param array $target Target.
		 */
		private function print_target( array $target ) {
			WP_CLI::line( $target['label'] . ( '' !== $target['note'] ? " - {$target['note']}" : '' ) );
			foreach ( $target['items'] as $item ) {
				WP_CLI::line( '  ' . $this->item_line( $item ) );
			}
			foreach ( $target['problems'] as $problem ) {
				WP_CLI::line( "  problem: $problem" );
			}
			if ( $target['skip'] ) {
				WP_CLI::line( "  SKIP {$target['label']}: nothing in this target will be written" );
			}
		}

		/**
		 * One dry-run line for an item.
		 *
		 * @param array $item Item.
		 * @return string
		 */
		private function item_line( array $item ) {
			$label = self::label( $item );
			switch ( $item['state'] ) {
				case 'unchanged':
					$line = "$label: unchanged";
					break;
				case 'change':
					if ( 'delete' === $item['kind'] ) {
						$line = "$label: will delete";
						break;
					}
					$line = "$label: will change " . self::show( $item['now'] ) . ' -> ' . self::show( $item['new'] );
					if ( ! self::same( $item['stored'], $item['new'] ) ) {
						$line .= ' (stored as ' . self::show( $item['stored'] ) . ')';
					}
					break;
				case 'differs':
					$line = "$label: differs, site has " . self::show( $item['site'] ) . ', plan expects ' . self::show( $item['now'] );
					break;
				default:
					$line = "$label: refused, {$item['reason']}";
			}
			return '' !== $item['note'] ? "$line; note: {$item['note']}" : $line;
		}

		/**
		 * Print the restore command.
		 */
		private function print_restore_hint() {
			WP_CLI::line(
				sprintf(
					'RESTORE: wp eval-file %s %s restore %s --user=%d',
					escapeshellarg( __FILE__ ),
					escapeshellarg( $this->plan_path ),
					escapeshellarg( $this->backup_path ),
					get_current_user_id()
				)
			);
		}

		/**
		 * Print the follow-ups this script does not do.
		 */
		private function print_follow_ups() {
			WP_CLI::line( 'Follow-ups (not done by this script):' );
			WP_CLI::line( '  - Purge page caches (caching plugin, server cache, CDN) for the changed URLs.' );
			if ( $this->taxonomies ) {
				WP_CLI::line( '  - Where term counts are deferred, recount: wp term recount ' . implode( ' ', array_keys( $this->taxonomies ) ) );
			}
			WP_CLI::line( '  - Check the sitemaps for changed slugs, statuses and deleted terms.' );
		}

		// ------------------------------------------------------------------
		// Helpers.
		// ------------------------------------------------------------------

		/**
		 * A post's term slugs in one taxonomy, sorted.
		 *
		 * @param int    $id       Post id.
		 * @param string $taxonomy Taxonomy.
		 * @return array
		 */
		private function post_term_slugs( $id, $taxonomy ) {
			$slugs = wp_get_object_terms( $id, $taxonomy, array( 'fields' => 'slugs' ) );
			return is_wp_error( $slugs ) ? array() : self::sorted( $slugs );
		}

		/**
		 * Item label such as meta.rank_math_title.
		 *
		 * @param array $item Item.
		 * @return string
		 */
		private static function label( array $item ) {
			return '' === $item['name'] ? $item['kind'] : "{$item['kind']}.{$item['name']}";
		}

		/**
		 * Compare values as WordPress stores them: scalars as strings, arrays recursively.
		 *
		 * @param mixed $a Value.
		 * @param mixed $b Value.
		 * @return bool
		 */
		private static function same( $a, $b ) {
			return self::normalize( $a ) === self::normalize( $b );
		}

		/**
		 * Normalize a value for comparison.
		 *
		 * @param mixed $value Value.
		 * @return mixed
		 */
		private static function normalize( $value ) {
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
		private static function show( $value ) {
			$text = (string) wp_json_encode( $value, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE );
			return strlen( $text ) > 160 ? substr( $text, 0, 157 ) . '...' : $text;
		}

		/**
		 * The single value of a meta key, '' when absent, the list when several.
		 *
		 * @param array $values Values from get_*_meta( ..., false ).
		 * @return mixed
		 */
		private static function single( $values ) {
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
		private static function is_string_list( $value ) {
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
		private static function sorted( array $list ) {
			$list = array_values( array_unique( array_map( 'strval', $list ) ) );
			sort( $list, SORT_STRING );
			return $list;
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

// `$args` holds the positional arguments that WP-CLI passes to eval-file.
exit( WPCP_Change_Plan::main( isset( $args ) ? (array) $args : array() ) );
