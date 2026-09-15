#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-merge-feedback.sh — stable entry point for focused feedback-routing modules.
#
# Consumers source this file and receive the review, CI-repair, conflict, and
# CI-pattern routing helpers without depending on their physical layout.

[[ -n "${_PULSE_MERGE_FEEDBACK_LOADED:-}" ]] && return 0
_PULSE_MERGE_FEEDBACK_LOADED=1

: "${LOGFILE:=${HOME}/.aidevops/logs/pulse.log}"
: "${PULSE_REVIEW_FEEDBACK_ITEM_LIMIT:=4000}"
: "${PULSE_REVIEW_FEEDBACK_SECTION_LIMIT:=12000}"
PULSE_REVIEW_REPAIR_SOURCE_LABEL="source:review-repair"
PULSE_FEEDBACK_JSON_STRING_TYPE="string"
PULSE_REVIEW_FEEDBACK_NO_TRUSTED_REVIEW_RC=2
_CI_REPAIR_OUTCOME_SUMMARY=""

_pulse_merge_feedback_dir="${BASH_SOURCE[0]%/*}"
[[ "$_pulse_merge_feedback_dir" == "${BASH_SOURCE[0]}" ]] && _pulse_merge_feedback_dir="."

# shellcheck source=./pulse-merge-feedback-finalizer.sh
# shellcheck disable=SC1091  # sibling module resolved via $SCRIPT_DIR
source "${_pulse_merge_feedback_dir}/pulse-merge-feedback-finalizer.sh"
# shellcheck source=./pulse-merge-feedback-review.sh
# shellcheck disable=SC1091  # sibling module resolved via $SCRIPT_DIR
source "${_pulse_merge_feedback_dir}/pulse-merge-feedback-review.sh"
# shellcheck source=./pulse-merge-feedback-ci-repair.sh
# shellcheck disable=SC1091  # sibling module resolved via $SCRIPT_DIR
source "${_pulse_merge_feedback_dir}/pulse-merge-feedback-ci-repair.sh"
# shellcheck source=./pulse-merge-feedback-conflict.sh
# shellcheck disable=SC1091  # sibling module resolved via $SCRIPT_DIR
source "${_pulse_merge_feedback_dir}/pulse-merge-feedback-conflict.sh"
# shellcheck source=./pulse-merge-feedback-ci-patterns.sh
# shellcheck disable=SC1091  # sibling module resolved via $SCRIPT_DIR
source "${_pulse_merge_feedback_dir}/pulse-merge-feedback-ci-patterns.sh"
unset _pulse_merge_feedback_dir
