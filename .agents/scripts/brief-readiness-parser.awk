# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Markdown-aware parsing primitives for brief-readiness-helper.sh.

function update_fence(text, trimmed, marker_char, marker_len, remainder) {
	trimmed = text
	sub(/^[[:space:]]*/, "", trimmed)
	marker_char = substr(trimmed, 1, 1)
	marker_len = 0
	if (marker_char == "`" || marker_char == "~") {
		while (substr(trimmed, marker_len + 1, 1) == marker_char) marker_len++
	}
	if (!in_fence && marker_len >= 3) {
		in_fence = 1
		fence_char = marker_char
		fence_len = marker_len
		return 1
	}
	if (in_fence && marker_char == fence_char && marker_len >= fence_len) {
		remainder = substr(trimmed, marker_len + 1)
		if (remainder ~ /^[[:space:]]*$/) {
			in_fence = 0
			return 1
		}
	}
	return 0
}

# Remove only the GitHub HTML wrappers emitted by issue-sync composition.
# Recompute the lowercase copy after each removal so matching remains portable
# without IGNORECASE. Unknown tags stay visible to placeholder classification.
function strip_generated_tags(text, lower) {
	lower = tolower(text)
	while (match(lower, /<\/?(details|summary|code)([[:space:]][^>]*)?>/)) {
		text = substr(text, 1, RSTART - 1) substr(text, RSTART + RLENGTH)
		lower = tolower(text)
	}
	return text
}

BEGIN {
	if (mode == "section") {
		target = tolower(target)
		level = (target ~ /^### /) ? 3 : 2
	}
}

mode == "unfenced" {
	if (update_fence($0)) next
	if (!in_fence) print
	next
}

mode == "visible" {
	line = $0
	while (length(line) > 0) {
		if (in_comment) {
			if (match(line, /-->/)) {
				line = substr(line, RSTART + RLENGTH)
				in_comment = 0
				continue
			}
			line = ""
			break
		}
		if (match(line, /<!--/)) {
			prefix = substr(line, 1, RSTART - 1)
			rest = substr(line, RSTART + RLENGTH)
			if (match(rest, /-->/)) {
				line = prefix substr(rest, RSTART + RLENGTH)
				continue
			}
			line = prefix
			in_comment = 1
		}
		break
	}
	if (length(line) > 0) print line
	next
}

mode == "section" {
	normalized = tolower($0)
	heading_line = normalized
	sub(/[[:space:]]+$/, "", heading_line)
	if (update_fence(normalized)) next
	if (!in_fence && !capture && heading_line == target) {
		capture = 1
		next
	}
	if (!in_fence && capture && ((level == 3 && normalized ~ /^###[[:space:]]/) || normalized ~ /^##[[:space:]]/)) {
		exit
	}
	if (capture && (!in_fence || include_fenced == true_value)) print
	next
}

mode == "prose" {
	if (update_fence($0)) next
	if (in_fence) next
	line = $0
	gsub(/`[^`]*`/, "", line)
	line = strip_generated_tags(line)
	print line
	next
}
