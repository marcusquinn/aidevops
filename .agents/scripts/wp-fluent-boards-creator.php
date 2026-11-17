<?php
/**
 * Fluent Boards card creation: add (GH#38699).
 *
 * SPDX-License-Identifier: MIT
 * SPDX-FileCopyrightText: 2026 Marcus Quinn
 *
 * Loaded by wp-fluent-boards.php after the writer; keep the wp-fluent-boards*.php files together.
 * The card is created through the plugin's own service and hooks, then read back.
 *
 * @package aidevops
 */

if ( ! defined( 'ABSPATH' ) ) {
	exit( 2 );
}

if ( ! class_exists( 'WPFB_Creator' ) ) {

	/**
	 * New cards, created the way the Fluent Boards UI creates them.
	 */
	final class WPFB_Creator {

		const MAX_TITLE = 255;

		/**
		 * One-line card title, sanitised as the board UI does.
		 *
		 * @param string $title Requested title.
		 * @return string Title.
		 * @throws WPFB_Error On an empty or over-long title.
		 */
		private static function card_title( $title ) {
			$clean = sanitize_text_field( (string) $title );
			if ( '' === $clean || mb_strlen( $clean ) > self::MAX_TITLE ) {
				throw new WPFB_Error( 'Card title must be 1-' . self::MAX_TITLE . ' characters of plain text', 2 );
			}
			return $clean;
		}

		/**
		 * The requested stage, or the board's first stage.
		 *
		 * @param object      $board Board model.
		 * @param string|null $stage Stage ID or title, if given.
		 * @return object Stage.
		 * @throws WPFB_Error When the stage is unknown or the board has none.
		 */
		private static function target_stage( $board, $stage ) {
			if ( null !== $stage ) {
				return WPFB_Store::stage( $board->id, $stage );
			}
			$stages = WPFB_Store::stages( $board->id );
			if ( ! $stages ) {
				throw new WPFB_Error( 'Board ' . $board->id . ' has no stages', 1 );
			}
			return $stages[0];
		}

		/**
		 * Card description HTML from a plain-text body file.
		 *
		 * Plain text in, escaped paragraphs out, as for comments; the plugin
		 * converts stored HTML to its own description format. The newline after
		 * each <br /> is dropped so that conversion does not turn it into a
		 * leading space on the next line.
		 *
		 * @param string $path Body file.
		 * @return string HTML.
		 */
		private static function description( $path ) {
			$html = wpautop( esc_html( WPFB_Writer::read_body( $path ) ) );
			return wp_kses_post( preg_replace( '#<br\s*/?>\n#', '<br />', $html ) );
		}

		/**
		 * Create a card through TaskService::createTask, the call behind the
		 * board UI's TaskController::create (Fluent Boards 2.3). The Task model's
		 * created event fires fluent_boards/task_created, which logs the activity.
		 * Placement and open/closed status follow the stage, as in the UI.
		 *
		 * @param array $options board, title, optional stage and body_file.
		 * @return array Result.
		 * @throws WPFB_Error On bad input, no stages or a failed read-back.
		 */
		public static function action_add( array $options ) {
			$board = WPFB_Store::board( $options['board'] );
			$title = self::card_title( $options['title'] );
			$stage = self::target_stage( $board, isset( $options['stage'] ) ? $options['stage'] : null );
			$tasks = WPFB_Store::service( 'TaskService' );
			if ( ! $tasks || ! method_exists( $tasks, 'createTask' ) ) {
				throw new WPFB_Error( 'This Fluent Boards version has no TaskService::createTask; add the card in the board UI', 2 );
			}
			$data = array(
				'title'    => $title,
				'board_id' => (int) $board->id,
				'stage_id' => (int) $stage->id,
			);
			if ( isset( $options['body_file'] ) ) {
				$data['description'] = self::description( $options['body_file'] );
			}
			$card  = $tasks->createTask( $data, (int) $board->id );
			$class = WPFB_Store::model( 'Task' );
			$after = empty( $card->id ) ? null : $class::find( (int) $card->id );
			// Title is reported as stored: a site filter may rewrite it.
			if ( ! $after || (int) $after->board_id !== (int) $board->id || (int) $after->stage_id !== (int) $stage->id ) {
				throw new WPFB_Error( 'Read-back found no new card "' . $title . '" on board ' . $board->id, 1 );
			}
			return array(
				'added'    => true,
				'card'     => (int) $after->id,
				'board'    => (int) $after->board_id,
				'stage_id' => (int) $after->stage_id,
				'stage'    => (string) $stage->title,
				'title'    => (string) $after->title,
				'status'   => (string) $after->status,
			);
		}
	}
}
