<?php
/**
 * Fluent Boards card assignees: assign, unassign (GH#39380).
 *
 * SPDX-License-Identifier: MIT
 * SPDX-FileCopyrightText: 2026 Marcus Quinn
 *
 * Loaded by wp-fluent-boards.php; keep the wp-fluent-boards*.php files together.
 * Each change goes through the plugin's own assignee service and hooks, then is read back.
 *
 * @package aidevops
 */

if ( false === defined( 'ABSPATH' ) ) {
	exit( 2 );
}

if ( false === class_exists( 'WPFB_Assigner' ) ) {

	/**
	 * Add or remove one card member the way the card's assignee picker does.
	 */
	final class WPFB_Assigner {

		const MAX_CARDS = 100;

		/**
		 * Distinct card IDs from a comma-separated list.
		 *
		 * @param string $list Card IDs, e.g. "12,13".
		 * @return array IDs.
		 * @throws WPFB_Error On a malformed or over-long list.
		 */
		private static function card_ids( $list ) {
			$list = (string) $list;
			$ids  = array_values( array_unique( array_map( 'intval', explode( ',', $list ) ) ) );
			if ( 1 !== preg_match( '/^[0-9]+(,[0-9]+)*$/', $list ) || true === in_array( 0, $ids, true ) || count( $ids ) > self::MAX_CARDS ) {
				throw new WPFB_Error( 'cards must be 1-' . self::MAX_CARDS . ' comma-separated card IDs', 2 );
			}
			return $ids;
		}

		/**
		 * Existing WordPress user ID.
		 *
		 * @param string $user_id User ID.
		 * @return int User ID.
		 * @throws WPFB_Error When the user does not exist.
		 */
		private static function member( $user_id ) {
			$user = get_userdata( (int) $user_id );
			if ( false === $user ) {
				throw new WPFB_Error( 'User not found: ' . $user_id, 1 );
			}
			return (int) $user->ID;
		}

		/**
		 * TaskService with the assignee toggle behind the board UI
		 * (updateTaskProperty('assignees', ...) -> updateAssignee, Fluent Boards 2.3).
		 *
		 * @return object TaskService.
		 * @throws WPFB_Error On a Fluent Boards version without it.
		 */
		private static function task_service() {
			$tasks = WPFB_Store::service( 'TaskService' );
			$task  = WPFB_Store::model( 'Task' );
			if ( null === $tasks || false === method_exists( $tasks, 'updateTaskProperty' ) || false === method_exists( $task, 'assignees' ) ) {
				throw new WPFB_Error( 'This Fluent Boards version has no TaskService assignee update; change assignees in the board UI', 2 );
			}
			return $tasks;
		}

		/**
		 * Refuse before any write when the user may not be assigned on a board.
		 * Same rule as TaskService::updateAssignee: board members and Fluent Boards admins.
		 *
		 * @param array $cards  Card models.
		 * @param int   $member User ID.
		 * @throws WPFB_Error When the user lacks access to a card's board.
		 */
		private static function require_board_access( array $cards, $member ) {
			$manager = WPFB_Store::SERVICES . 'PermissionManager';
			if ( false === class_exists( $manager ) || false === method_exists( $manager, 'userHasPermission' ) ) {
				return; // The service still enforces its own rule per card.
			}
			$boards = array_unique(
				array_map(
					static function ( $card ) {
						return (int) $card->board_id;
					},
					$cards
				)
			);
			foreach ( $boards as $board_id ) {
				if ( false === (bool) $manager::userHasPermission( $board_id, $member ) ) {
					throw new WPFB_Error( 'Only board members can be assigned to a task: user ' . $member . ' is not a member of board ' . $board_id . ' (add them to the board first)', 1 );
				}
			}
		}

		/**
		 * Assign or unassign one member on one card, then read the card back.
		 * A card already in the wanted state is left alone, so re-runs are no-ops.
		 *
		 * @param object $tasks   TaskService.
		 * @param object $card    Card model.
		 * @param int    $member  User ID.
		 * @param bool   $assign  True to assign, false to unassign.
		 * @param array  $changed Card IDs already changed in this run (for the error).
		 * @return array Row: card, title, changed, before, after.
		 * @throws WPFB_Error When the read-back does not show the wanted state.
		 */
		private static function change_card( $tasks, $card, $member, $assign, array $changed ) {
			$before = WPFB_Store::assignee_ids( $card );
			$change = in_array( $member, $before, true ) !== $assign;
			if ( true === $change ) {
				// updateAssignee toggles: only call it when the state must flip.
				$tasks->updateTaskProperty( 'assignees', $member, $card );
			}
			$after = WPFB_Store::assignee_ids( WPFB_Store::card( $card->id ) );
			if ( in_array( $member, $after, true ) !== $assign ) {
				$done = array() === $changed ? '' : ' (already changed: ' . implode( ',', $changed ) . ')';
				throw new WPFB_Error( 'Read-back shows user ' . $member . ( $assign ? ' not assigned to' : ' still assigned to' ) . ' card ' . $card->id . $done, 1 );
			}
			return array(
				'card'    => (int) $card->id,
				'title'   => (string) $card->title,
				'changed' => $change,
				'before'  => self::people( $before ),
				'after'   => self::people( $after ),
			);
		}

		/**
		 * User IDs as id/name pairs.
		 *
		 * @param array $ids User IDs.
		 * @return array People.
		 */
		private static function people( array $ids ) {
			return WPFB_Store::people( $ids );
		}

		/**
		 * Assign or unassign one member on every listed card.
		 * Board access is checked for every card before the first write.
		 *
		 * @param array $options cards, member.
		 * @param bool  $assign  True to assign, false to unassign.
		 * @return array Result.
		 * @throws WPFB_Error On bad input, refusal or a failed read-back.
		 */
		private static function change( array $options, $assign ) {
			$member = self::member( $options['member'] );
			$tasks  = self::task_service();
			$cards  = array_map( array( 'WPFB_Store', 'card' ), self::card_ids( $options['cards'] ) );
			if ( true === $assign ) {
				self::require_board_access( $cards, $member );
			}
			$rows    = array();
			$changed = array();
			foreach ( $cards as $card ) {
				$row = self::change_card( $tasks, $card, $member, $assign, $changed );
				if ( true === $row['changed'] ) {
					$changed[] = $row['card'];
				}
				$rows[] = $row;
			}
			return array(
				$assign ? 'assigned' : 'unassigned' => count( $changed ),
				'member'                            => array(
					'id'   => $member,
					'name' => WPFB_Store::user_name( $member ),
				),
				'cards'                             => $rows,
			);
		}

		/**
		 * Assign a board member to cards (also adds them as a watcher, as the UI does).
		 *
		 * @param array $options cards, member.
		 * @return array Result.
		 */
		public static function action_assign( array $options ) {
			return self::change( $options, true );
		}

		/**
		 * Remove a member from cards' assignees (and watchers, as the UI does).
		 *
		 * @param array $options cards, member.
		 * @return array Result.
		 */
		public static function action_unassign( array $options ) {
			return self::change( $options, false );
		}
	}
}
