<?php
/**
 * Fluent Boards cards over WP-CLI, through the plugin's own models (GH#38593, GH#38699).
 *
 * SPDX-License-Identifier: MIT
 * SPDX-FileCopyrightText: 2026 Marcus Quinn
 *
 * Run from the WordPress root; add --url=<blog> on multisite:
 *   wp eval-file wp-fluent-boards.php boards
 *   wp eval-file wp-fluent-boards.php cards board=ID [stage=ID|TITLE]
 *   wp eval-file wp-fluent-boards.php show card=ID
 *   wp eval-file wp-fluent-boards.php add board=ID title=TEXT [stage=ID|TITLE] [body_file=PATH] --user=<id>
 *   wp eval-file wp-fluent-boards.php move card=ID stage=ID|TITLE --user=<id>
 *   wp eval-file wp-fluent-boards.php comment card=ID body_file=PATH --user=<id>
 *   wp eval-file wp-fluent-boards.php check card=ID item=ID --user=<id>
 *
 * Prints JSON. Exit codes: 0 done, 1 not found or write not confirmed by
 * read-back, 2 usage error or Fluent Boards unavailable on this site/blog.
 * Card text is third-party content: callers scan it before display.
 * Usage and workflow: .agents/tools/wordpress/fluent-mcp.md "Work a setup board".
 *
 * @package aidevops
 */

if ( ! defined( 'ABSPATH' ) || ! class_exists( 'WP_CLI' ) ) {
	fwrite( STDERR, "Run through WP-CLI: wp eval-file wp-fluent-boards.php ACTION [key=value ...]\n" );
	exit( 2 );
}

if ( ! class_exists( 'WPFB_Error' ) ) {
	/**
	 * A failure with its exit code (1 not found/unconfirmed, 2 usage/unavailable).
	 */
	class WPFB_Error extends Exception {
	}
}

// Siblings; wp-helper-fluent-boards.sh uploads them with this file for SSH sites.
require_once __DIR__ . '/wp-fluent-boards-store.php';
require_once __DIR__ . '/wp-fluent-boards-reader.php';
require_once __DIR__ . '/wp-fluent-boards-writer.php';
require_once __DIR__ . '/wp-fluent-boards-creator.php';

if ( ! class_exists( 'WPFB_Cards' ) ) {

	/**
	 * Parses arguments, checks preconditions and dispatches one action.
	 */
	final class WPFB_Cards {

		// Action => array( handler class, required keys ).
		const ACTIONS = array(
			'boards'  => array( 'WPFB_Reader', array() ),
			'cards'   => array( 'WPFB_Reader', array( 'board' ) ),
			'show'    => array( 'WPFB_Reader', array( 'card' ) ),
			'add'     => array( 'WPFB_Creator', array( 'board', 'title' ) ),
			'move'    => array( 'WPFB_Writer', array( 'card', 'stage' ) ),
			'comment' => array( 'WPFB_Writer', array( 'card', 'body_file' ) ),
			'check'   => array( 'WPFB_Writer', array( 'card', 'item' ) ),
		);

		const NUMERIC = array( 'board', 'card', 'item' );

		/**
		 * Entry point for `wp eval-file`.
		 *
		 * @param array $args Positional arguments after the script path.
		 * @return int Exit code.
		 */
		public static function main( array $args ) {
			try {
				$action  = (string) array_shift( $args );
				$options = self::parse_options( $action, $args );
				self::require_plugin();
				$handler = self::ACTIONS[ $action ][0];
				// Every handler except the reader writes.
				if ( 'WPFB_Reader' !== $handler && get_current_user_id() < 1 ) {
					throw new WPFB_Error( 'Writes need --user=<id> so Fluent Boards attributes the change to a real account', 2 );
				}
				self::emit( call_user_func( array( $handler, 'action_' . $action ), $options ) );
				return 0;
			} catch ( WPFB_Error $error ) {
				fwrite( STDERR, 'ERROR: ' . $error->getMessage() . "\n" );
				return (int) $error->getCode();
			} catch ( Throwable $error ) {
				// Plugin-side refusal or an unsupported version: report, never retry blindly.
				fwrite( STDERR, 'ERROR: Fluent Boards refused the operation: ' . $error->getMessage() . "\n" );
				return 1;
			}
		}

		/**
		 * Split key=value arguments.
		 *
		 * @param array $args Positional arguments.
		 * @return array Options.
		 * @throws WPFB_Error On a malformed argument.
		 */
		private static function split_pairs( array $args ) {
			$options = array();
			foreach ( $args as $arg ) {
				$pair = explode( '=', (string) $arg, 2 );
				if ( 2 !== count( $pair ) || '' === $pair[1] ) {
					throw new WPFB_Error( 'Expected key=value, got: ' . $arg, 2 );
				}
				$options[ $pair[0] ] = $pair[1];
			}
			return $options;
		}

		/**
		 * Parse key=value options and require the action's keys.
		 *
		 * @param string $action Action name.
		 * @param array  $args   Remaining positional arguments.
		 * @return array Options.
		 * @throws WPFB_Error On usage errors.
		 */
		private static function parse_options( $action, array $args ) {
			if ( ! isset( self::ACTIONS[ $action ] ) ) {
				$shown = '' === $action ? '<none>' : $action;
				throw new WPFB_Error( 'Unknown action: ' . $shown . ' (boards|cards|show|add|move|comment|check)', 2 );
			}
			$options = self::split_pairs( $args );
			$missing = array_diff( self::ACTIONS[ $action ][1], array_keys( $options ) );
			if ( $missing ) {
				throw new WPFB_Error( $action . ' needs ' . reset( $missing ) . '=...', 2 );
			}
			foreach ( array_intersect_key( $options, array_flip( self::NUMERIC ) ) as $key => $value ) {
				if ( ! ctype_digit( $value ) ) {
					throw new WPFB_Error( $key . ' must be a numeric ID', 2 );
				}
			}
			return $options;
		}

		/**
		 * Fail closed unless the Fluent Boards models are loaded on this blog.
		 *
		 * @throws WPFB_Error When the plugin is unavailable.
		 */
		private static function require_plugin() {
			foreach ( array( 'Board', 'Stage', 'Task', 'Comment' ) as $model ) {
				if ( ! class_exists( WPFB_Store::model( $model ) ) ) {
					throw new WPFB_Error( 'Fluent Boards is not active here (missing ' . $model . ' model); on multisite pass --url for the blog that runs it', 2 );
				}
			}
		}

		/**
		 * Print a JSON document.
		 *
		 * @param mixed $data Result.
		 */
		private static function emit( $data ) {
			echo wp_json_encode( $data, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE ), "\n";
		}
	}
}

// phpcs:ignore WordPress.NamingConventions.PrefixAllGlobals -- $args is set by `wp eval-file`.
$wpfb_exit = WPFB_Cards::main( isset( $args ) && is_array( $args ) ? $args : array() );
if ( 0 !== $wpfb_exit ) {
	exit( $wpfb_exit );
}
