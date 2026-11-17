<?php
/**
 * Fluent Boards model lookups shared by the reader and writer (GH#38593).
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

if ( ! class_exists( 'WPFB_Store' ) ) {

	/**
	 * Boards, stages, cards and checklist items through the plugin's models.
	 */
	final class WPFB_Store {

		const NS            = 'FluentBoards\\App\\Models\\';
		const SERVICES      = 'FluentBoards\\App\\Services\\';
		const STATUS_CLOSED = 'closed';

		/**
		 * Fully-qualified model class name.
		 *
		 * @param string $model Short name.
		 * @return string Class name.
		 */
		public static function model( $model ) {
			return self::NS . $model;
		}

		/**
		 * Plugin service instance, or null when this version lacks it.
		 *
		 * @param string $service Short name.
		 * @return object|null Service.
		 */
		public static function service( $service ) {
			$class = self::SERVICES . $service;
			return class_exists( $class ) ? new $class() : null;
		}

		/**
		 * HTML card text as plain text.
		 *
		 * @param string|null $html Stored HTML.
		 * @return string Plain text.
		 */
		public static function plain( $html ) {
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
		public static function is_card( $task ) {
			return empty( $task->parent_id ) && empty( $task->archived_at );
		}

		/**
		 * True when a checklist item or card is closed.
		 *
		 * @param object $task Task model.
		 * @return bool
		 */
		public static function is_closed( $task ) {
			return self::STATUS_CLOSED === $task->status;
		}

		/**
		 * Board model or a not-found error.
		 *
		 * @param int $id Board ID.
		 * @return object Board.
		 * @throws WPFB_Error When missing.
		 */
		public static function board( $id ) {
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
		public static function card( $id ) {
			$class = self::model( 'Task' );
			$task  = $class::find( (int) $id );
			if ( ! $task || ! empty( $task->parent_id ) ) {
				throw new WPFB_Error( 'Card not found: ' . $id, 1 );
			}
			return $task;
		}

		/**
		 * Drop archived rows from a query result.
		 *
		 * @param iterable $rows Models.
		 * @return array Unarchived models.
		 */
		private static function unarchived( $rows ) {
			$kept = array();
			foreach ( $rows as $row ) {
				if ( empty( $row->archived_at ) ) {
					$kept[] = $row;
				}
			}
			return $kept;
		}

		/**
		 * Unarchived stages of a board in board order.
		 *
		 * @param int $board_id Board ID.
		 * @return array Stage models.
		 */
		public static function stages( $board_id ) {
			$class = self::model( 'Stage' );
			return self::unarchived( $class::where( 'board_id', (int) $board_id )->orderBy( 'position', 'ASC' )->get() );
		}

		/**
		 * True when a stage matches an ID or a case-insensitive title.
		 *
		 * @param object $stage  Stage model.
		 * @param string $wanted Stage ID or title.
		 * @return bool
		 */
		private static function stage_matches( $stage, $wanted ) {
			if ( ctype_digit( $wanted ) ) {
				return (int) $stage->id === (int) $wanted;
			}
			return 0 === strcasecmp( trim( $stage->title ), trim( $wanted ) );
		}

		/**
		 * Resolve a stage by ID or case-insensitive title within a board.
		 *
		 * @param int    $board_id Board ID.
		 * @param string $wanted   Stage ID or title.
		 * @return object Stage.
		 * @throws WPFB_Error When no single stage matches.
		 */
		public static function stage( $board_id, $wanted ) {
			$matches = array();
			foreach ( self::stages( $board_id ) as $stage ) {
				if ( self::stage_matches( $stage, $wanted ) ) {
					$matches[] = $stage;
				}
			}
			if ( 1 === count( $matches ) ) {
				return $matches[0];
			}
			$problem = $matches ? 'is ambiguous' : 'not found';
			throw new WPFB_Error( 'Stage ' . $problem . ' on board ' . $board_id . ': ' . $wanted, 1 );
		}

		/**
		 * True when moving a card into the stage closes it (plugin rule).
		 *
		 * @param object $stage Stage model.
		 * @return bool
		 */
		public static function stage_closes( $stage ) {
			if ( method_exists( $stage, 'defaultTaskStatus' ) ) {
				return self::STATUS_CLOSED === (string) $stage->defaultTaskStatus();
			}
			$settings = is_array( $stage->settings ) ? $stage->settings : maybe_unserialize( $stage->settings );
			$status   = is_array( $settings ) && isset( $settings['default_task_status'] ) ? $settings['default_task_status'] : 'open';
			return 'open' !== $status;
		}

		/**
		 * Stage titles by ID for a board.
		 *
		 * @param int $board_id Board ID.
		 * @return array Titles.
		 */
		public static function stage_names( $board_id ) {
			$names = array();
			foreach ( self::stages( $board_id ) as $stage ) {
				$names[ (int) $stage->id ] = (string) $stage->title;
			}
			return $names;
		}

		/**
		 * Unarchived tasks of a board, optionally limited to one parent card.
		 *
		 * @param int      $board_id Board ID.
		 * @param int|null $parent   Parent card ID for checklist items.
		 * @return array Task models.
		 */
		public static function tasks( $board_id, $parent = null ) {
			$class = self::model( 'Task' );
			$query = $class::where( 'board_id', (int) $board_id );
			if ( null !== $parent ) {
				$query = $query->where( 'parent_id', (int) $parent );
			}
			return self::unarchived( $query->orderBy( 'position', 'ASC' )->get() );
		}

		/**
		 * Display name for a user ID, or null.
		 *
		 * @param int $user_id User ID.
		 * @return string|null
		 */
		public static function user_name( $user_id ) {
			$user = $user_id ? get_userdata( (int) $user_id ) : false;
			return $user ? $user->display_name : null;
		}

		/**
		 * Meta values keyed by a column, for one key and a set of task IDs.
		 *
		 * @param array  $task_ids Task IDs.
		 * @param string $key      Meta key.
		 * @param string $by       Column to key results by (id or task_id).
		 * @return array Values.
		 */
		private static function meta_values( array $task_ids, $key, $by ) {
			$meta = self::model( 'TaskMeta' );
			if ( ! $task_ids || ! class_exists( $meta ) ) {
				return array();
			}
			$values = array();
			foreach ( $meta::whereIn( 'task_id', $task_ids )->where( 'key', $key )->get() as $row ) {
				$values[ (int) $row->{$by} ] = (string) $row->value;
			}
			return $values;
		}

		/**
		 * Checklist items of a card with group names when the plugin stores them.
		 *
		 * @param object $card Card model.
		 * @return array Items.
		 */
		public static function checklist( $card ) {
			$items    = self::tasks( $card->board_id, $card->id );
			$ids      = array_map(
				static function ( $item ) {
					return (int) $item->id;
				},
				$items
			);
			$groups   = self::meta_values( array( (int) $card->id ), 'group_name', 'id' );
			$children = self::meta_values( $ids, 'subtask_group_id', 'task_id' );
			$list     = array();
			foreach ( $items as $item ) {
				$group  = (int) ( $children[ (int) $item->id ] ?? 0 );
				$list[] = array(
					'id'    => (int) $item->id,
					'title' => (string) $item->title,
					'done'  => self::is_closed( $item ),
					'group' => $groups[ $group ] ?? null,
				);
			}
			return $list;
		}
	}
}
