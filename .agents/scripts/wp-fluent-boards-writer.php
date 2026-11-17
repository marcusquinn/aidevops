<?php
/**
 * Fluent Boards write actions: move, comment, check (GH#38593).
 *
 * SPDX-License-Identifier: MIT
 * SPDX-FileCopyrightText: 2026 Marcus Quinn
 *
 * Loaded by wp-fluent-boards.php; keep the wp-fluent-boards*.php files together.
 * Each write goes through the plugin's models/services and hooks, then is read back.
 *
 * @package aidevops
 */

if ( ! defined( 'ABSPATH' ) ) {
	exit( 2 );
}

if ( ! class_exists( 'WPFB_Writer' ) ) {

	/**
	 * Card writes that mirror what the Fluent Boards UI does.
	 */
	final class WPFB_Writer {

		const MAX_BODY = 20000;

		/**
		 * Place a card at the end of its new stage.
		 *
		 * @param object $card     Card model with the new stage_id set.
		 * @param int    $stage_id Stage ID.
		 * @return object Card.
		 */
		private static function place_at_end( $card, $stage_id ) {
			$class = WPFB_Store::model( 'Task' );
			if ( method_exists( $card, 'moveToNewPosition' ) ) {
				$others = $class::where( 'stage_id', $stage_id )->whereNull( 'parent_id' )->whereNull( 'archived_at' )->where( 'id', '!=', (int) $card->id )->count();
				return $card->moveToNewPosition( $others + 1 );
			}
			$card->position = (float) $class::where( 'stage_id', $stage_id )->max( 'position' ) + 1;
			$card->save();
			return $card;
		}

		/**
		 * Stage-change side effects from TaskController::moveTask (Fluent Boards 2.3).
		 *
		 * @param object $card  Card model, already in the new stage.
		 * @param object $stage Stage model.
		 */
		private static function after_stage_change( $card, $stage ) {
			$meta = WPFB_Store::model( 'TaskMeta' );
			if ( class_exists( $meta ) ) {
				$meta::where( 'task_id', (int) $card->id )->where( 'key', 'archived_by_stage' )->delete();
			}
			$tasks = WPFB_Store::service( 'TaskService' );
			if ( $tasks && method_exists( $tasks, 'manageDefaultAssignees' ) ) {
				$tasks->manageDefaultAssignees( $card, (int) $stage->id );
			}
			if ( WPFB_Store::stage_closes( $stage ) && ! WPFB_Store::is_closed( $card ) && method_exists( $card, 'close' ) ) {
				$card->close();
			}
		}

		/**
		 * Move a card to a stage the way the board UI does, then read back.
		 * Stage-change e-mails are not sent.
		 *
		 * @param array $options card, stage.
		 * @return array Result.
		 * @throws WPFB_Error When the read-back disagrees.
		 */
		public static function action_move( array $options ) {
			$card     = WPFB_Store::card( $options['card'] );
			$stage    = WPFB_Store::stage( $card->board_id, $options['stage'] );
			$old      = (int) $card->stage_id;
			$stage_id = (int) $stage->id;
			if ( $old !== $stage_id ) {
				$card->stage_id = $stage_id;
				$card           = self::place_at_end( $card, $stage_id );
				self::after_stage_change( $card, $stage );
				do_action( 'fluent_boards/task_stage_updated', $card, $old );
				do_action( 'fluent_boards/task_updated', $card, 'position' );
			}
			$after = WPFB_Store::card( $card->id );
			if ( (int) $after->stage_id !== $stage_id ) {
				throw new WPFB_Error( 'Read-back shows card ' . $card->id . ' still in stage ' . $after->stage_id, 1 );
			}
			return array(
				'moved'      => $old !== $stage_id,
				'card'       => (int) $after->id,
				'from_stage' => $old,
				'stage_id'   => (int) $after->stage_id,
				'stage'      => (string) $stage->title,
				'status'     => (string) $after->status,
			);
		}

		/**
		 * Plain-text body (comment or card description) from a file,
		 * size-limited and non-empty. Shared with WPFB_Creator.
		 *
		 * @param string $path Body file.
		 * @return string Text.
		 * @throws WPFB_Error On a bad body.
		 */
		public static function read_body( $path ) {
			if ( ! is_readable( $path ) || filesize( $path ) > self::MAX_BODY ) {
				throw new WPFB_Error( 'Body file is unreadable or larger than ' . self::MAX_BODY . ' bytes', 2 );
			}
			$raw = trim( (string) file_get_contents( $path ) );
			if ( '' === $raw ) {
				throw new WPFB_Error( 'Body file is empty', 2 );
			}
			return $raw;
		}

		/**
		 * Save a comment through CommentService (fires its hooks), or the model
		 * plus the comment_created hook on versions without the service.
		 *
		 * @param string $raw  Plain text.
		 * @param object $card Card model.
		 * @return object|null Saved comment.
		 */
		private static function save_comment( $raw, $card ) {
			// Plain text in, escaped paragraphs out; then the same sanitise/render
			// steps as CommentController::create when the service offers them.
			$html    = wpautop( esc_html( $raw ) );
			$handler = WPFB_Store::service( 'CommentService' );
			$methods = $handler ? get_class_methods( $handler ) : array();
			if ( in_array( 'sanitizeContent', $methods, true ) ) {
				$html = $handler->sanitizeContent( $html );
			}
			$data = array(
				'parent_id'   => null,
				'description' => in_array( 'renderContent', $methods, true ) ? $handler->renderContent( $html, array() ) : $html,
				'created_by'  => get_current_user_id(),
				'task_id'     => (int) $card->id,
				'type'        => 'comment',
				'board_id'    => (int) $card->board_id,
				'settings'    => array(
					'raw_description' => $html,
					'mentioned_id'    => array(),
				),
			);
			if ( in_array( 'create', $methods, true ) ) {
				return $handler->create( $data, (int) $card->id, (int) $card->board_id );
			}
			$class   = WPFB_Store::model( 'Comment' );
			$comment = $class::create( $data );
			do_action( 'fluent_boards/comment_created', $comment );
			return $comment;
		}

		/**
		 * Add a comment from a file through the plugin's comment service.
		 *
		 * @param array $options card, body_file.
		 * @return array Result.
		 * @throws WPFB_Error On a bad body or a failed read-back.
		 */
		public static function action_comment( array $options ) {
			$card    = WPFB_Store::card( $options['card'] );
			$comment = self::save_comment( self::read_body( $options['body_file'] ), $card );
			$class   = WPFB_Store::model( 'Comment' );
			$saved   = empty( $comment->id ) ? null : $class::find( (int) $comment->id );
			if ( ! $saved || (int) $saved->task_id !== (int) $card->id ) {
				throw new WPFB_Error( 'Read-back found no saved comment on card ' . $card->id, 1 );
			}
			return array(
				'commented' => true,
				'card'      => (int) $card->id,
				'comment'   => (int) $saved->id,
				'author'    => WPFB_Store::user_name( $saved->created_by ),
			);
		}

		/**
		 * Close a checklist item the way the board UI does.
		 *
		 * @param object $item Checklist item (task) model.
		 */
		private static function close_item( $item ) {
			$tasks = WPFB_Store::service( 'TaskService' );
			if ( $tasks && method_exists( $tasks, 'updateTaskProperty' ) ) {
				$tasks->updateTaskProperty( 'status', WPFB_Store::STATUS_CLOSED, $item );
				return;
			}
			$item->close();
			do_action( 'fluent_boards/task_completed_activity', $item, WPFB_Store::STATUS_CLOSED );
		}

		/**
		 * Mark one checklist item of a card done, then read back.
		 *
		 * @param array $options card, item.
		 * @return array Result.
		 * @throws WPFB_Error When the item is not on the card or stays open.
		 */
		public static function action_check( array $options ) {
			$card  = WPFB_Store::card( $options['card'] );
			$class = WPFB_Store::model( 'Task' );
			$item  = $class::find( (int) $options['item'] );
			if ( ! $item || (int) $item->parent_id !== (int) $card->id ) {
				throw new WPFB_Error( 'Checklist item ' . $options['item'] . ' is not on card ' . $card->id, 1 );
			}
			$changed = ! WPFB_Store::is_closed( $item );
			if ( $changed ) {
				self::close_item( $item );
			}
			$after = $class::find( (int) $item->id );
			if ( ! $after || ! WPFB_Store::is_closed( $after ) ) {
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
