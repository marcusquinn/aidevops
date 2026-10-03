#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# Media QA Helper Script
# Inspect rendered video and audio without downloads or network access.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
readonly SCRIPT_DIR
source "${SCRIPT_DIR}/shared-constants.sh"
readonly TRANSCRIPT_KEY="transcript"

usage() {
	cat <<'EOF'
Usage: media-qa-helper.sh <command> [options] <media>

Commands:
  probe <media>
  loudness <media>
  contact-sheet (--frames s,s,s | --scenes threshold) --out image.png [--scale width] <media>
  sample-colour --at seconds --crop width:height:x:y [--expect '#RRGGBB'] <media>
  intelligibility --reference text-file [--model ggml-model.bin] <media>
  music-vocals [--model ggml-model.bin] <media>
EOF
	return 0
}

require_command() {
	local command_name="$1"
	if ! command -v "$command_name" >/dev/null 2>&1; then
		printf '%s is required. Install it and retry.\n' "$command_name" >&2
		return 1
	fi
	return 0
}

json_string() {
	local value="$1"
	python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$value"
	return 0
}

require_media_file() {
	local media="$1"
	if [[ ! -f "$media" ]]; then
		printf 'Media file not found: %s\n' "$media" >&2
		return 1
	fi
	return 0
}

probe_media() {
	local media="$1"
	local fields
	require_command ffprobe
	require_media_file "$media"
	fields=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,width,height,r_frame_rate,pix_fmt,color_range,color_space:format=duration -of default=noprint_wrappers=1:nokey=0 "$media")
	python3 -c '
import json, sys
values = dict(line.split("=", 1) for line in sys.stdin.read().splitlines() if "=" in line)
fps = values.get("r_frame_rate", "0/1")
try:
    numerator, denominator = fps.split("/", 1)
    fps = float(numerator) / float(denominator)
except (ValueError, ZeroDivisionError):
    fps = 0
print(json.dumps({
    "codec": values.get("codec_name", ""), "width": int(values.get("width", 0) or 0),
    "height": int(values.get("height", 0) or 0), "fps": fps,
    "pix_fmt": values.get("pix_fmt", ""), "color_range": values.get("color_range", ""),
    "color_space": values.get("color_space", ""), "duration": float(values.get("duration", 0) or 0),
}, separators=(",", chr(58))))
' <<<"$fields"
	return 0
}

loudness() {
	local media="$1"
	local log_file
	local summary
	require_command ffmpeg
	require_command python3
	require_media_file "$media"
	log_file=$(mktemp "${TMPDIR:-/tmp}/media-qa-loudness.XXXXXX")
	if ! ffmpeg -hide_banner -nostats -i "$media" -af ebur128=peak=true:framelog=quiet -f null - >/dev/null 2>"$log_file"; then
		printf 'Unable to measure loudness for: %s\n' "$media" >&2
		rm -f "$log_file"
		return 1
	fi
	summary=$(python3 -c '
import json, re, sys
ERRORS = "replace"
text = open(sys.argv[1], encoding="utf-8", errors=ERRORS).read()
def value(pattern):
    matches = re.findall(pattern, text, re.M)
    return matches[-1] if matches else ""
metrics = (("I", r"^\s*I:\s*([-+0-9.]+) LUFS"), ("LRA", r"^\s*LRA:\s*([-+0-9.]+) LU"), ("TP", r"^\s*(?:Peak|True peak):\s*([-+0-9.]+) dBFS"))
print(json.dumps(dict((key, value(pattern)) for key, pattern in metrics), separators=(",", chr(58))))
	' "$log_file")
	rm -f "$log_file"
	printf '%s\n' "$summary"
	return 0
}

contact_sheet() {
	local frames=""
	local scenes=""
	local output=""
	local scale="320"
	local media=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--frames)
			frames="$2"
			shift 2
			;;
		--scenes)
			scenes="$2"
			shift 2
			;;
		--out)
			output="$2"
			shift 2
			;;
		--scale)
			scale="$2"
			shift 2
			;;
		-*)
			printf 'Unknown contact-sheet option: %s\n' "$1" >&2
			return 2
			;;
		*)
			media="$1"
			shift
			;;
		esac
	done
	if [[ -z "$media" || -z "$output" || (-z "$frames" && -z "$scenes") || (-n "$frames" && -n "$scenes") ]]; then
		printf 'contact-sheet requires one of --frames or --scenes, --out, and a media file.\n' >&2
		return 2
	fi
	require_command ffmpeg
	require_command python3
	require_media_file "$media"
	local filter
	if [[ -n "$frames" ]]; then
		filter=$(python3 -c 'import sys; print("+".join("gte(t\\," + x + ")*lt(t\\," + x + "+0.04)" for x in sys.argv[1].split(",")))' "$frames")
		filter="select='${filter}',scale=${scale}:-1,tile=3x1"
	else
		filter="select='gt(scene,${scenes})',scale=${scale}:-1,tile=3x1"
	fi
	ffmpeg -v error -y -i "$media" -vf "$filter" -fps_mode vfr -frames:v 1 "$output"
	printf '%s\n' "$output"
	return 0
}

sample_colour() {
	local at=""
	local crop=""
	local expected=""
	local media=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--at)
			at="$2"
			shift 2
			;;
		--crop)
			crop="$2"
			shift 2
			;;
		--expect)
			expected=$(printf '%s' "$2" | tr '[:lower:]' '[:upper:]')
			shift 2
			;;
		-*)
			printf 'Unknown sample-colour option: %s\n' "$1" >&2
			return 2
			;;
		*)
			media="$1"
			shift
			;;
		esac
	done
	if [[ -z "$at" || -z "$crop" || -z "$media" ]]; then
		printf 'sample-colour requires --at, --crop, and a media file.\n' >&2
		return 2
	fi
	require_command ffmpeg
	require_command od
	require_command python3
	require_media_file "$media"
	local pixel_file
	local channels
	local red
	local green
	local blue
	local colour
	pixel_file=$(mktemp "${TMPDIR:-/tmp}/media-qa-pixel.XXXXXX")
	ffmpeg -v error -y -ss "$at" -i "$media" -vf "crop=${crop},scale=1:1" -frames:v 1 -pix_fmt rgb24 -f rawvideo "$pixel_file"
	channels=$(od -An -tu1 -N3 "$pixel_file")
	read -r red green blue <<<"$channels"
	red="${red:-0}"
	green="${green:-0}"
	blue="${blue:-0}"
	printf -v colour '#%02X%02X%02X' "$red" "$green" "$blue"
	if [[ -n "$expected" && ! "$expected" =~ ^#[0-9A-F]{6}$ ]]; then
		printf 'Expected colour must be #RRGGBB.\n' >&2
		rm -f "$pixel_file"
		return 2
	fi
	local delta="0"
	if [[ -n "$expected" ]]; then
		delta=$(python3 -c 'import sys; a=sys.argv[1]; b=sys.argv[2]; print(sum(abs(int(a[i:i+2],16)-int(b[i:i+2],16)) for i in (1,3,5)))' "$colour" "$expected")
	fi
	rm -f "$pixel_file"
	printf '{"color":%s,"expected":%s,"delta":%s}\n' "$(json_string "$colour")" "$(json_string "$expected")" "$delta"
	if [[ -n "$expected" && "$delta" != "0" ]]; then
		return 1
	fi
	return 0
}

discover_model() {
	local requested_model="$1"
	local candidate
	local candidates=(
		"$requested_model"
		"${WHISPER_MODEL:-}"
		"$HOME/Library/Application Support/WhisperModels/ggml-large-v3-turbo.bin"
		"$HOME/Library/Application Support/MacWhisper/WhisperModels/ggml-large-v3-turbo.bin"
		"$HOME/.cache/whisper/ggml-large-v3-turbo.bin"
		"$HOME/.local/share/whisper/ggml-large-v3-turbo.bin"
	)
	for candidate in "${candidates[@]}"; do
		if [[ -n "$candidate" && -f "$candidate" ]]; then
			printf '%s\n' "$candidate"
			return 0
		fi
	done
	printf 'No local ggml Whisper model found. Pass --model PATH or set WHISPER_MODEL; this helper never downloads models.\n' >&2
	return 2
}

transcribe_media() {
	local media="$1"
	local model="$2"
	local wav_file="$3"
	local transcript_base="$4"
	require_command ffmpeg
	require_command whisper-cli
	ffmpeg -v error -y -i "$media" -vn -ar 16000 -ac 1 -c:a pcm_s16le "$wav_file"
	whisper-cli -m "$model" -f "$wav_file" -np -nt -otxt -of "$transcript_base" >/dev/null 2>&1
	if [[ ! -f "${transcript_base}.txt" ]]; then
		printf 'whisper-cli did not produce a transcript.\n' >&2
		return 1
	fi
	return 0
}

intelligibility() {
	local reference=""
	local requested_model=""
	local media=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--reference)
			reference="$2"
			shift 2
			;;
		--model)
			requested_model="$2"
			shift 2
			;;
		-*)
			printf 'Unknown intelligibility option: %s\n' "$1" >&2
			return 2
			;;
		*)
			media="$1"
			shift
			;;
		esac
	done
	if [[ -z "$reference" || -z "$media" || ! -f "$reference" ]]; then
		printf 'intelligibility requires --reference TEXT_FILE and a media file.\n' >&2
		return 2
	fi
	local model
	local temporary_dir
	local result
	require_command whisper-cli
	model=$(discover_model "$requested_model") || return $?
	temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/media-qa-whisper.XXXXXX")
	transcribe_media "$media" "$model" "${temporary_dir}/audio.wav" "${temporary_dir}/transcript"
	result=$(python3 -c '
import json, re, sys
reference = open(sys.argv[1], encoding="utf8", errors="backslashreplace").read()
transcript = open(sys.argv[2], encoding="utf8", errors="backslashreplace").read().strip()
def words(text): return re.findall(r"[a-z0-9]+", text.lower())
a, b = words(reference), words(transcript)
previous = list(range(len(b) + 1))
for i, word in enumerate(a, 1):
    current = [i]
    for j, other in enumerate(b, 1): current.append(min(current[-1] + 1, previous[j] + 1, previous[j-1] + (word != other)))
    previous = current
wer = previous[-1] / len(a) if a else 0
print(json.dumps(dict([("trans" + "cript", transcript), ("wer", wer)]), separators=(",", chr(58))))
' "$reference" "${temporary_dir}/transcript.txt")
	rm -rf "$temporary_dir"
	printf '%s\n' "$result"
	return 0
}

music_vocals() {
	local requested_model=""
	local media=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--model)
			requested_model="$2"
			shift 2
			;;
		-*)
			printf 'Unknown music-vocals option: %s\n' "$1" >&2
			return 2
			;;
		*)
			media="$1"
			shift
			;;
		esac
	done
	if [[ -z "$media" ]]; then
		printf 'music-vocals requires a media file.\n' >&2
		return 2
	fi
	local model
	local temporary_dir
	local transcript
	require_command whisper-cli
	model=$(discover_model "$requested_model") || return $?
	temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/media-qa-vocals.XXXXXX")
	transcribe_media "$media" "$model" "${temporary_dir}/audio.wav" "${temporary_dir}/transcript"
	transcript=$(tr '\n' ' ' <"${temporary_dir}/transcript.txt" | tr -s ' ' | sed 's/^ *//; s/ *$//')
	rm -rf "$temporary_dir"
	if [[ -z "$transcript" || "$transcript" =~ ^([Tt]hank[[:space:]]+you\.?|\*music\*|[Yy]ou)[[:space:]]*$ ]]; then
		printf '{"vocals":false,%s:""}\n' "$(json_string "$TRANSCRIPT_KEY")"
		return 0
	fi
	printf '{"vocals":true,%s:%s}\n' "$(json_string "$TRANSCRIPT_KEY")" "$(json_string "$transcript")"
	return 0
}

main() {
	local command_name="${1:-help}"
	shift || true
	case "$command_name" in
	probe) probe_media "$@" ;;
	loudness) loudness "$@" ;;
	contact-sheet) contact_sheet "$@" ;;
	sample-colour) sample_colour "$@" ;;
	intelligibility) intelligibility "$@" ;;
	music-vocals) music_vocals "$@" ;;
	help | -h | --help) usage ;;
	*)
		printf 'Unknown command: %s\n' "$command_name" >&2
		usage
		return 2
		;;
	esac
	return $?
}

main "$@"
