<?php
/**
 * Fluent Boards read actions: boards, cards, show (GH#38593).
 *
 * SPDX-License-Identifier: MIT
 * SPDX-FileCopyrightText: 2026 Marcus Quinn
 *
 * Loaded by wp-fluent-boards.php; keep the wp-fluent-boards*.php files together.
 *
 * @package aidevops
 */

if ( ! defined( 'ABSPATH' ) ) {
	exit( 2 );
}

if ( ! class_exists( 'WPFB_Reader' ) ) {

	/**
	 * Read-only views of boards and cards. Output is third-party text.
	 */
	final class WPFB_Reader {

		/**
		 * Summary row for one card.
		 *
		 * @param object $card        Card model.
		 * @param array  $stage_names Stage titles by ID.
		 * @return array Row.
		 */
		private static function card_row( $card, array $stage_names ) {
			$items = WPFB_Store::tasks( $card->board_id, $card->id );
			$done  = count( array_filter( $items, array( 'WPFB_Store', 'is_closed' ) ) );
			return array(
				'id'        => (int) $card->id,
				'title'     => (string) $card->title,
				'stage_id'  => (int) $card->stage_id,
				'stage'     => $stage_names[ (int) $card->stage_id ] ?? null,
				'status'    => (string) $card->status,
				'checklist' => $done . '/' . count( $items ),
				'comments'  => (int) $card->comments_count,
				'due_at'    => $card->due_at ? (string) $card->due_at : null,
			);
		}

		/**
		 * Open card counts by stage ID for a board.
		 *
		 * @param int $board_id Board ID.
		 * @return array Counts.
		 */
		private static function card_counts( $board_id ) {
			$counts = array();
			foreach ( WPFB_Store::tasks( $board_id ) as $task ) {
				if ( WPFB_Store::is_card( $task ) ) {
					$key            = (int) $task->stage_id;
					$counts[ $key ] = ( $counts[ $key ] ?? 0 ) + 1;
				}
			}
			return $counts;
		}

		/**
		 * Boards with their stages and open card counts.
		 *
		 * @return array Boards.
		 */
		public static function action_boards() {
			$class  = WPFB_Store::model( 'Board' );
			$boards = array();
			foreach ( $class::orderBy( 'id', 'ASC' )->get() as $board ) {
				if ( ! empty( $board->archived_at ) ) {
					continue;
				}
				$counts = self::card_counts( $board->id );
				$stages = array();
				foreach ( WPFB_Store::stages( $board->id ) as $stage ) {
					$stages[] = array(
						'id'           => (int) $stage->id,
						'title'        => (string) $stage->title,
						'closes_cards' => WPFB_Store::stage_closes( $stage ),
						'cards'        => $counts[ (int) $stage->id ] ?? 0,
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
		public static function action_cards( array $options ) {
			$board = WPFB_Store::board( $options['board'] );
			$names = WPFB_Store::stage_names( $board->id );
			$only  = isset( $options['stage'] ) ? (int) WPFB_Store::stage( $board->id, $options['stage'] )->id : null;
			$order = array_flip( array_keys( $names ) );
			$cards = array_filter(
				WPFB_Store::tasks( $board->id ),
				static function ( $task ) use ( $only ) {
					return WPFB_Store::is_card( $task ) && ( null === $only || (int) $task->stage_id === $only );
				}
			);
			usort(
				$cards,
				static function ( $a, $b ) use ( $order ) {
					$sa = $order[ (int) $a->stage_id ] ?? PHP_INT_MAX;
					$sb = $order[ (int) $b->stage_id ] ?? PHP_INT_MAX;
					return array( $sa, (float) $a->position ) <=> array( $sb, (float) $b->position );
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
		 * Comments on a card (not activity rows), oldest first.
		 *
		 * @param object $card Card model.
		 * @return array Comments.
		 */
		private static function comments( $card ) {
			$class    = WPFB_Store::model( 'Comment' );
			$comments = array();
			foreach ( $class::where( 'task_id', (int) $card->id )->where( 'type', 'comment' )->orderBy( 'id', 'ASC' )->get() as $comment ) {
				$author     = WPFB_Store::user_name( $comment->created_by ) ?: ( $comment->author_name ? (string) $comment->author_name : null );
				$comments[] = array(
					'id'      => (int) $comment->id,
					'author'  => $author,
					'created' => (string) $comment->created_at,
					'text'    => WPFB_Store::plain( $comment->description ),
				);
			}
			return $comments;
		}

		/**
		 * One card: plain-text description, checklist and comments.
		 *
		 * @param array $options card.
		 * @return array Card.
		 */
		public static function action_show( array $options ) {
			$card = WPFB_Store::card( $options['card'] );
			return array_merge(
				self::card_row( $card, WPFB_Store::stage_names( $card->board_id ) ),
				array(
					'board_id'        => (int) $card->board_id,
					'description'     => WPFB_Store::plain( $card->description ),
					'checklist_items' => WPFB_Store::checklist( $card ),
					'comment_list'    => self::comments( $card ),
				)
			);
		}
	}
}
