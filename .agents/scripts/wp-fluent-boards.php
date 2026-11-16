<?php
/**
 * Fluent Boards cards over WP-CLI, through the plugin's own models (GH#38593).
 *
 * SPDX-License-Identifier: MIT
 * SPDX-FileCopyrightText: 2026 Marcus Quinn
 *
 * Run from the WordPress root; add --url=<blog> on multisite:
 *   wp eval-file wp-fluent-boards.php boards
 *   wp eval-file wp-fluent-boards.php cards board=ID [stage=ID|TITLE]
 *   wp eval-file wp-fluent-boards.php show card=ID
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

if ( ! class_exists( 'WPFB_Cards' ) ) {

	/**
	 * Reads and writes Fluent Boards boards, cards, checklists and comments.
	 */
	final class WPFB_Cards {

		const NS            = 'FluentBoards\\App\\Models\\';
		const SERVICES      = 'FluentBoards\\App\\Services\\';
		const MAX_BODY      = 20000;
		const STATUS_CLOSED = 'closed';
		const ACTIONS       = array(
			'boards'  => array(),
			'cards'   => array( 'board' ),
			'show'    => array( 'card' ),
			'move'    => array( 'card', 'stage' ),
			'comment' => array( 'card', 'body_file' ),
			'check'   => array( 'card', 'item' ),
		);
		const WRITES        = array( 'move', 'comment', 'check' );

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
				if ( in_array( $action, self::WRITES, true ) && get_current_user_id() < 1 ) {
					throw new WPFB_Error( 'Writes need --user=<id> so Fluent Boards attributes the change to a real account', 2 );
				}
				$result = call_user_func( array( __CLASS__, 'action_' . $action ), $options );
				self::emit( $result );
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
		 * Parse key=value options and require the action's keys.
		 *
		 * @param string $action Action name.
		 * @param array  $args   Remaining positional arguments.
		 * @return array Options.
		 * @throws WPFB_Error On usage errors.
		 */
		private static function parse_options( $action, array $args ) {
			if ( ! isset( self::ACTIONS[ $action ] ) ) {
				throw new WPFB_Error( 'Unknown action: ' . ( '' === $action ? '<none>' : $action ) . ' (boards|cards|show|move|comment|check)', 2 );
			}
			$options = array();
			foreach ( $args as $arg ) {
				$pair = explode( '=', (string) $arg, 2 );
				if ( 2 !== count( $pair ) || '' === $pair[1] ) {
					throw new WPFB_Error( 'Expected key=value, got: ' . $arg, 2 );
				}
				$options[ $pair[0] ] = $pair[1];
			}
			foreach ( self::ACTIONS[ $action ] as $key ) {
				if ( ! isset( $options[ $key ] ) ) {
					throw new WPFB_Error( $action . ' needs ' . $key . '=...', 2 );
				}
			}
			foreach ( array( 'board', 'card', 'item' ) as $key ) {
				if ( isset( $options[ $key ] ) && ! ctype_digit( $options[ $key ] ) ) {
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
				if ( ! class_exists( self::NS . $model ) ) {
					throw new WPFB_Error( 'Fluent Boards is not active here (missing ' . $model . ' model); on multisite pass --url for the blog that runs it', 2 );
				}
			}
		}

		/**
		 * Fully-qualified model class name.
		 *
		 * @param string $model Short name.
		 * @return string Class name.
		 */
		private static function model( $model ) {
			return self::NS . $model;
		}

		/**
		 * Print a JSON document.
		 *
		 * @param mixed $data Result.
		 */
		private static function emit( $data ) {
			echo wp_json_encode( $data, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE ), "\n";
		}

		/**
		 * HTML card text as plain text.
		 *
		 * @param string|null $html Stored HTML.
		 * @return string Plain text.
		 */
		private static function plain( $html ) {
			$text = preg_replace( '#<br\s*/?>|</p>|</li>|</h[1-6]>|</div>#i', "\n", (string) $html );
			$text = html_entity_decode( wp_strip_all_tags( $text ), ENT_QUOTES, 'UTF-8' );
			return trim( preg_replace( "/\n{3,}/", "\n\n", $text ) );
		}

		/**
		 * True when a task row is a top-level card (not a checklist item).
		 *
		 * @param object $task Task model.
		 * @return bool
		 */
		private static function is_card( $task ) {
			return empty( $task->parent_id ) && empty( $task->archived_at );
		}

		/**
		 * Board model or a not-found error.
		 *
		 * @param int $id Board ID.
		 * @return object Board.
		 * @throws WPFB_Error When missing.
		 */
		private static function board( $id ) {
			$class = self::model( 'Board' );
			$board = $class::find( (int) $id );
			if ( ! $board ) {
				throw new WPFB_Error( 'Board not found: ' . $id, 1 );
			}
			return $board;
		}

		/**
		 * Card (top-level task) model or a not-found error.
		 *
		 * @param int $id Task ID.
		 * @return object Task.
		 * @throws WPFB_Error When missing or a checklist item.
		 */
		private static function card( $id ) {
			$class = self::model( 'Task' );
			$task  = $class::find( (int) $id );
			if ( ! $task || ! empty( $task->parent_id ) ) {
				throw new WPFB_Error( 'Card not found: ' . $id, 1 );
			}
			return $task;
		}

		/**
		 * Unarchived stages of a board in board order.
		 *
		 * @param int $board_id Board ID.
		 * @return array Stage models.
		 */
		private static function stages( $board_id ) {
			$class  = self::model( 'Stage' );
			$stages = array();
			foreach ( $class::where( 'board_id', (int) $board_id )->orderBy( 'position', 'ASC' )->get() as $stage ) {
				if ( empty( $stage->archived_at ) ) {
					$stages[] = $stage;
				}
			}
			return $stages;
		}

		/**
		 * Resolve a stage by ID or case-insensitive title within a board.
		 *
		 * @param int    $board_id Board ID.
		 * @param string $wanted   Stage ID or title.
		 * @return object Stage.
		 * @throws WPFB_Error When no single stage matches.
		 */
		private static function stage( $board_id, $wanted ) {
			$matches = array();
			foreach ( self::stages( $board_id ) as $stage ) {
				if ( ctype_digit( $wanted ) ? (int) $stage->id === (int) $wanted : 0 === strcasecmp( trim( $stage->title ), trim( $wanted ) ) ) {
					$matches[] = $stage;
				}
			}
			if ( 1 !== count( $matches ) ) {
				throw new WPFB_Error( 'Stage ' . ( $matches ? 'is ambiguous' : 'not found' ) . ' on board ' . $board_id . ': ' . $wanted, 1 );
			}
			return $matches[0];
		}

		/**
		 * Stage default status: 'closed' moves close the card (plugin rule).
		 *
		 * @param object $stage Stage model.
		 * @return string open|closed
		 */
		private static function stage_status( $stage ) {
			if ( method_exists( $stage, 'defaultTaskStatus' ) ) {
				return (string) $stage->defaultTaskStatus();
			}
			$settings = is_array( $stage->settings ) ? $stage->settings : maybe_unserialize( $stage->settings );
			return ( is_array( $settings ) && isset( $settings['default_task_status'] ) && 'open' !== $settings['default_task_status'] ) ? self::STATUS_CLOSED : 'open';
		}

		/**
		 * Unarchived tasks of a board, optionally limited to one parent card.
		 *
		 * @param int      $board_id Board ID.
		 * @param int|null $parent   Parent card ID for checklist items.
		 * @return array Task models.
		 */
		private static function tasks( $board_id, $parent = null ) {
			$class = self::model( 'Task' );
			$query = $class::where( 'board_id', (int) $board_id );
			if ( null !== $parent ) {
				$query = $query->where( 'parent_id', (int) $parent );
			}
			$tasks = array();
			foreach ( $query->orderBy( 'position', 'ASC' )->get() as $task ) {
				if ( empty( $task->archived_at ) ) {
					$tasks[] = $task;
				}
			}
			return $tasks;
		}

		/**
		 * Checklist items of a card with group names when the plugin stores them.
		 *
		 * @param object $card Card model.
		 * @return array Items.
		 */
		private static function checklist( $card ) {
			$groups   = array();
			$children = array();
			$meta     = self::model( 'TaskMeta' );
			$items    = self::tasks( $card->board_id, $card->id );
			if ( class_exists( $meta ) ) {
				foreach ( $meta::where( 'task_id', (int) $card->id )->where( 'key', 'group_name' )->get() as $row ) {
					$groups[ (int) $row->id ] = (string) $row->value;
				}
				$ids = array_map(
					static function ( $item ) {
						return (int) $item->id;
					},
					$items
				);
				if ( $ids ) {
					foreach ( $meta::whereIn( 'task_id', $ids )->where( 'key', 'subtask_group_id' )->get() as $row ) {
						$children[ (int) $row->task_id ] = (int) $row->value;
					}
				}
			}
			$list = array();
			foreach ( $items as $item ) {
				$group  = isset( $children[ (int) $item->id ] ) ? $children[ (int) $item->id ] : 0;
				$list[] = array(
					'id'     => (int) $item->id,
					'title'  => (string) $item->title,
					'done'   => self::STATUS_CLOSED === $item->status,
					'group'  => isset( $groups[ $group ] ) ? $groups[ $group ] : null,
				);
			}
			return $list;
		}

		/**
		 * Display name for a user ID, or null.
		 *
		 * @param int $user_id User ID.
		 * @return string|null
		 */
		private static function user_name( $user_id ) {
			$user = $user_id ? get_userdata( (int) $user_id ) : false;
			return $user ? $user->display_name : null;
		}

		/**
		 * Summary row for one card.
		 *
		 * @param object $card       Card model.
		 * @param array  $stage_names Stage titles by ID.
		 * @return array Row.
		 */
		private static function card_row( $card, array $stage_names ) {
			$items = self::tasks( $card->board_id, $card->id );
			$done  = count(
				array_filter(
					$items,
					static function ( $item ) {
						return self::STATUS_CLOSED === $item->status;
					}
				)
			);
			return array(
				'id'        => (int) $card->id,
				'title'     => (string) $card->title,
				'stage_id'  => (int) $card->stage_id,
				'stage'     => isset( $stage_names[ (int) $card->stage_id ] ) ? $stage_names[ (int) $card->stage_id ] : null,
				'status'    => (string) $card->status,
				'checklist' => $done . '/' . count( $items ),
				'comments'  => (int) $card->comments_count,
				'due_at'    => $card->due_at ? (string) $card->due_at : null,
			);
		}

		/**
		 * Stage titles by ID for a board.
		 *
		 * @param int $board_id Board ID.
		 * @return array Titles.
		 */
		private static function stage_names( $board_id ) {
			$names = array();
			foreach ( self::stages( $board_id ) as $stage ) {
				$names[ (int) $stage->id ] = (string) $stage->title;
			}
			return $names;
		}

		/**
		 * Boards with their stages and open card counts.
		 *
		 * @return array Boards.
		 */
		private static function action_boards() {
			$class  = self::model( 'Board' );
			$boards = array();
			foreach ( $class::orderBy( 'id', 'ASC' )->get() as $board ) {
				if ( ! empty( $board->archived_at ) ) {
					continue;
				}
				$counts = array();
				foreach ( self::tasks( $board->id ) as $task ) {
					if ( self::is_card( $task ) ) {
						$key            = (int) $task->stage_id;
						$counts[ $key ] = isset( $counts[ $key ] ) ? $counts[ $key ] + 1 : 1;
					}
				}
				$stages = array();
				foreach ( self::stages( $board->id ) as $stage ) {
					$stages[] = array(
						'id'             => (int) $stage->id,
						'title'          => (string) $stage->title,
						'closes_cards'   => self::STATUS_CLOSED === self::stage_status( $stage ),
						'cards'          => isset( $counts[ (int) $stage->id ] ) ? $counts[ (int) $stage->id ] : 0,
					);
				}
				$boards[] = array(
					'id'     => (int) $board->id,
					'title'  => (string) $board->title,
					'stages' => $stages,
				);
			}
			return array(
				'site'   => home_url(),
				'boards' => $boards,
			);
		}

		/**
		 * Cards of a board, optionally in one stage, in board order.
		 *
		 * @param array $options board, optional stage.
		 * @return array Cards.
		 */
		private static function action_cards( array $options ) {
			$board = self::board( $options['board'] );
			$names = self::stage_names( $board->id );
			$only  = isset( $options['stage'] ) ? (int) self::stage( $board->id, $options['stage'] )->id : null;
			$order = array_flip( array_keys( $names ) );
			$cards = array();
			foreach ( self::tasks( $board->id ) as $task ) {
				if ( self::is_card( $task ) && ( null === $only || (int) $task->stage_id === $only ) ) {
					$cards[] = $task;
				}
			}
			usort(
				$cards,
				static function ( $a, $b ) use ( $order ) {
					$sa = isset( $order[ (int) $a->stage_id ] ) ? $order[ (int) $a->stage_id ] : PHP_INT_MAX;
					$sb = isset( $order[ (int) $b->stage_id ] ) ? $order[ (int) $b->stage_id ] : PHP_INT_MAX;
					return $sa === $sb ? ( (float) $a->position <=> (float) $b->position ) : ( $sa <=> $sb );
				}
			);
			return array(
				'board' => array(
					'id'    => (int) $board->id,
					'title' => (string) $board->title,
				),
				'cards' => array_map(
					static function ( $card ) use ( $names ) {
						return self::card_row( $card, $names );
					},
					$cards
				),
			);
		}

		/**
		 * One card: plain-text description, checklist and comments.
		 *
		 * @param array $options card.
		 * @return array Card.
		 */
		private static function action_show( array $options ) {
			$card     = self::card( $options['card'] );
			$names    = self::stage_names( $card->board_id );
			$class    = self::model( 'Comment' );
			$comments = array();
			foreach ( $class::where( 'task_id', (int) $card->id )->orderBy( 'id', 'ASC' )->get() as $comment ) {
				if ( 'comment' !== $comment->type ) {
					continue;
				}
				$comments[] = array(
					'id'      => (int) $comment->id,
					'author'  => self::user_name( $comment->created_by ) ?: ( $comment->author_name ? (string) $comment->author_name : null ),
					'created' => (string) $comment->created_at,
					'text'    => self::plain( $comment->description ),
				);
			}
			$row = self::card_row( $card, $names );
			return array_merge(
				$row,
				array(
					'board_id'        => (int) $card->board_id,
					'description'     => self::plain( $card->description ),
					'checklist_items' => self::checklist( $card ),
					'comment_list'    => $comments,
				)
			);
		}

		/**
		 * Move a card to a stage the way the board UI does, then read back.
		 *
		 * @param array $options card, stage.
		 * @return array Result.
		 * @throws WPFB_Error When the read-back disagrees.
		 */
		private static function action_move( array $options ) {
			$card  = self::card( $options['card'] );
			$stage = self::stage( $card->board_id, $options['stage'] );
			$old   = (int) $card->stage_id;
			if ( $old !== (int) $stage->id ) {
				// Mirrors TaskController::moveTask (Fluent Boards 2.3): position at the
				// end of the stage, default assignees, stage close rule, hooks. Stage
				// change e-mails are not sent.
				$class          = self::model( 'Task' );
				$card->stage_id = (int) $stage->id;
				if ( method_exists( $card, 'moveToNewPosition' ) ) {
					$others = $class::where( 'stage_id', (int) $stage->id )->whereNull( 'parent_id' )->whereNull( 'archived_at' )->where( 'id', '!=', (int) $card->id )->count();
					$card   = $card->moveToNewPosition( $others + 1 );
				} else {
					$card->position = (float) $class::where( 'stage_id', (int) $stage->id )->max( 'position' ) + 1;
					$card->save();
				}
				$meta = self::model( 'TaskMeta' );
				if ( class_exists( $meta ) ) {
					$meta::where( 'task_id', (int) $card->id )->where( 'key', 'archived_by_stage' )->delete();
				}
				$service = self::SERVICES . 'TaskService';
				if ( class_exists( $service ) && method_exists( $service, 'manageDefaultAssignees' ) ) {
					( new $service() )->manageDefaultAssignees( $card, (int) $stage->id );
				}
				if ( self::STATUS_CLOSED === self::stage_status( $stage ) && self::STATUS_CLOSED !== $card->status && method_exists( $card, 'close' ) ) {
					$card->close();
				}
				do_action( 'fluent_boards/task_stage_updated', $card, $old );
				do_action( 'fluent_boards/task_updated', $card, 'position' );
			}
			$after = self::card( $card->id );
			if ( (int) $after->stage_id !== (int) $stage->id ) {
				throw new WPFB_Error( 'Read-back shows card ' . $card->id . ' still in stage ' . $after->stage_id, 1 );
			}
			return array(
				'moved'      => $old !== (int) $stage->id,
				'card'       => (int) $after->id,
				'from_stage' => $old,
				'stage_id'   => (int) $after->stage_id,
				'stage'      => (string) $stage->title,
				'status'     => (string) $after->status,
			);
		}

		/**
		 * Add a comment from a file through the plugin's comment service.
		 *
		 * @param array $options card, body_file.
		 * @return array Result.
		 * @throws WPFB_Error On a bad body or a failed read-back.
		 */
		private static function action_comment( array $options ) {
			$card = self::card( $options['card'] );
			$path = $options['body_file'];
			if ( ! is_readable( $path ) || filesize( $path ) > self::MAX_BODY ) {
				throw new WPFB_Error( 'Comment body file is unreadable or larger than ' . self::MAX_BODY . ' bytes', 2 );
			}
			$raw = trim( (string) file_get_contents( $path ) );
			if ( '' === $raw ) {
				throw new WPFB_Error( 'Comment body file is empty', 2 );
			}
			// Plain text in, escaped paragraphs out; then the same sanitise/render
			// steps as CommentController::create when the service offers them.
			$html    = wpautop( esc_html( $raw ) );
			$service = self::SERVICES . 'CommentService';
			$handler = class_exists( $service ) ? new $service() : null;
			if ( $handler && method_exists( $handler, 'sanitizeContent' ) ) {
				$html = $handler->sanitizeContent( $html );
			}
			$data = array(
				'parent_id'   => null,
				'description' => ( $handler && method_exists( $handler, 'renderContent' ) ) ? $handler->renderContent( $html, array() ) : $html,
				'created_by'  => get_current_user_id(),
				'task_id'     => (int) $card->id,
				'type'        => 'comment',
				'board_id'    => (int) $card->board_id,
				'settings'    => array(
					'raw_description' => $html,
					'mentioned_id'    => array(),
				),
			);
			if ( $handler && method_exists( $handler, 'create' ) ) {
				$comment = $handler->create( $data, (int) $card->id, (int) $card->board_id );
			} else {
				$class   = self::model( 'Comment' );
				$comment = $class::create( $data );
				do_action( 'fluent_boards/comment_created', $comment );
			}
			$class = self::model( 'Comment' );
			$saved = ( is_object( $comment ) && ! empty( $comment->id ) ) ? $class::find( (int) $comment->id ) : null;
			if ( ! $saved || (int) $saved->task_id !== (int) $card->id ) {
				throw new WPFB_Error( 'Read-back found no saved comment on card ' . $card->id, 1 );
			}
			return array(
				'commented' => true,
				'card'      => (int) $card->id,
				'comment'   => (int) $saved->id,
				'author'    => self::user_name( $saved->created_by ),
			);
		}

		/**
		 * Mark one checklist item of a card done, then read back.
		 *
		 * @param array $options card, item.
		 * @return array Result.
		 * @throws WPFB_Error When the item is not on the card or stays open.
		 */
		private static function action_check( array $options ) {
			$card  = self::card( $options['card'] );
			$class = self::model( 'Task' );
			$item  = $class::find( (int) $options['item'] );
			if ( ! $item || (int) $item->parent_id !== (int) $card->id ) {
				throw new WPFB_Error( 'Checklist item ' . $options['item'] . ' is not on card ' . $card->id, 1 );
			}
			$changed = self::STATUS_CLOSED !== $item->status;
			if ( $changed ) {
				$service = self::SERVICES . 'TaskService';
				if ( class_exists( $service ) && method_exists( $service, 'updateTaskProperty' ) ) {
					( new $service() )->updateTaskProperty( 'status', self::STATUS_CLOSED, $item );
				} else {
					$item->close();
					do_action( 'fluent_boards/task_completed_activity', $item, self::STATUS_CLOSED );
				}
			}
			$after = $class::find( (int) $item->id );
			if ( ! $after || self::STATUS_CLOSED !== $after->status ) {
				throw new WPFB_Error( 'Read-back shows checklist item ' . $item->id . ' still open', 1 );
			}
			return array(
				'checked' => $changed,
				'card'    => (int) $card->id,
				'item'    => (int) $after->id,
				'title'   => (string) $after->title,
				'done'    => true,
			);
		}
	}
}

// phpcs:ignore WordPress.NamingConventions.PrefixAllGlobals -- $args is set by `wp eval-file`.
$wpfb_exit = WPFB_Cards::main( isset( $args ) && is_array( $args ) ? $args : array() );
if ( 0 !== $wpfb_exit ) {
	exit( $wpfb_exit );
}
