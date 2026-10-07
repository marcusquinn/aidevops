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
readonly DURATION_KEY="duration"
readonly SHEET_MAX_SIDE_DEFAULT="1568"
readonly SWS_ACCURATE="accurate_rnd+full_chroma_int"

usage() {
	cat <<'EOF'
Usage: media-qa-helper.sh <command> [options] <media>

Commands:
  probe <media>
  loudness <media>
  contact-sheet (--frames s,s,s | --every seconds | --scenes threshold) --out image.png
                [--scale width] [--grid CxR] [--max-side px] <media>
  strip --at seconds --out image.png [--count 12] [--scale 240] [--max-side px] <media>
  scan [--freeze-seconds 1] [--black-seconds 0.1] [--silence-seconds 1] [--silence-db -50] <media>
  loopcheck <media>
  compare <media-a> <media-b>
  sample-colour --at seconds --crop width:height:x:y [--expect '#RRGGBB'] <media>
  intelligibility --reference text-file [--model ggml-model.bin] <media>
  music-vocals [--model ggml-model.bin] <media>

Sheets print JSON {sheets, grid, times}: tile i (row-major, across pages) shows times[i].
They fit --max-side (default 1568, 0 disables) and split into -01, -02 pages when needed.
scan reports freeze/black/silence spans as review pointers, not verdicts.
loopcheck exits 1 when the last-to-first seam jumps more than the film's own last step.
compare exits 1 when decoded frame hashes differ (determinism check).
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
length_key = sys.argv[1]
try:
    length = float(values.get(length_key, 0) or 0)
except ValueError:
    length = 0.0
print(json.dumps({
    "codec": values.get("codec_name", ""), "width": int(values.get("width", 0) or 0),
    "height": int(values.get("height", 0) or 0), "fps": fps,
    "pix_fmt": values.get("pix_fmt", ""), "color_range": values.get("color_range", ""),
    "color_space": values.get("color_space", ""), length_key: length,
}, separators=(",", chr(58))))
' "$DURATION_KEY" <<<"$fields"
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

# Prints "width height fps duration" for the first video stream.
video_geometry() {
	local media="$1"
	local fields
	# CSV rows: stream "w,h,num/den" then format "seconds" (N/A for stills).
	fields=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height,r_frame_rate:format=duration -of csv=p=0 "$media")
	python3 -c '
import sys
rows = [line.split(",") for line in sys.stdin.read().splitlines() if line.strip()]
stream = (rows[0] if rows else []) + ["0", "0", "0/1"]
def number(text):
    try:
        return float(text)
    except ValueError:
        return 0.0
try:
    numerator, denominator = stream[2].split("/", 1)
    fps = float(numerator) / float(denominator)
except (ValueError, ZeroDivisionError):
    fps = 0.0
seconds = number(rows[1][0]) if len(rows) > 1 else 0.0
print(int(number(stream[0])), int(number(stream[1])), fps, seconds)
' <<<"$fields"
	return 0
}

require_positive_integer() {
	local name="$1"
	local value="$2"
	if [[ ! "$value" =~ ^[0-9]+$ ]]; then
		printf '%s must be a non-negative integer: %s\n' "$name" "$value" >&2
		return 2
	fi
	return 0
}

# Prints "cols rows pages" so every page fits max_side (0 = unlimited, six columns).
sheet_layout() {
	local width="$1"
	local height="$2"
	local scale="$3"
	local count="$4"
	local max_side="$5"
	local grid="$6"
	python3 -c '
import math, sys
width, height, scale, count, max_side = (int(float(x)) for x in sys.argv[1:6])
grid = sys.argv[6]
count = max(1, count)
if grid:
    cols, rows = (max(1, int(x)) for x in grid.lower().split("x", 1))
else:
    tile_height = max(1, round(scale * height / width)) if width else scale
    cols = min(count, max(1, max_side // scale)) if max_side > 0 else min(count, 6)
    rows_cap = max(1, max_side // tile_height) if max_side > 0 else count
    rows = max(1, min(math.ceil(count / cols), rows_cap))
print(cols, rows, math.ceil(count / (cols * rows)))
' "$width" "$height" "$scale" "$count" "$max_side" "$grid"
	return 0
}

# Tiles pre-filtered frames into one or more sheets and prints {sheets, grid, times}.
render_sheet() {
	local media="$1"
	local output="$2"
	local pre_filter="$3"
	local seek="$4"
	local count="$5"
	local scale="$6"
	local grid="$7"
	local max_side="$8"
	local times="$9"
	local geometry
	local width
	local height
	local layout
	local cols
	local rows
	local pages
	geometry=$(video_geometry "$media")
	read -r width height _ _ <<<"$geometry"
	layout=$(sheet_layout "$width" "$height" "$scale" "$count" "$max_side" "$grid")
	read -r cols rows pages <<<"$layout"
	local filter="${pre_filter},scale=${scale}:-1:flags=lanczos,tile=${cols}x${rows}"
	if [[ "$max_side" -gt 0 ]]; then
		filter="${filter},scale='min(${max_side},iw)':'min(${max_side},ih)':force_original_aspect_ratio=decrease"
	fi
	local target="$output"
	if [[ "$pages" -gt 1 ]]; then
		target="${output%.*}-%02d.${output##*.}"
	fi
	local seek_args=()
	if [[ -n "$seek" ]]; then
		seek_args=(-ss "$seek")
	fi
	ffmpeg -v error -y ${seek_args[@]+"${seek_args[@]}"} -i "$media" -vf "$filter" -fps_mode vfr -frames:v "$pages" "$target"
	python3 -c '
import json, os, sys
target, pages, grid, times = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
sheets = [target % page for page in range(1, pages + 1)] if pages > 1 else [target]
print(json.dumps({"sheets": [path for path in sheets if os.path.isfile(path)], "grid": grid,
    "times": [float(x) for x in times.split(",") if x]}, separators=(",", chr(58))))
' "$target" "$pages" "${cols}x${rows}" "$times"
	return 0
}

contact_sheet() {
	local frames=""
	local scenes=""
	local every=""
	local output=""
	local scale="320"
	local grid=""
	local max_side="$SHEET_MAX_SIDE_DEFAULT"
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
		--every)
			every="$2"
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
		--grid)
			grid="$2"
			shift 2
			;;
		--max-side)
			max_side="$2"
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
	local modes=0
	if [[ -n "$frames" ]]; then modes=$((modes + 1)); fi
	if [[ -n "$scenes" ]]; then modes=$((modes + 1)); fi
	if [[ -n "$every" ]]; then modes=$((modes + 1)); fi
	if [[ -z "$media" || -z "$output" || "$modes" -ne 1 ]]; then
		printf 'contact-sheet requires exactly one of --frames, --every or --scenes, --out, and a media file.\n' >&2
		return 2
	fi
	if [[ -n "$grid" && ! "$grid" =~ ^[1-9][0-9]*x[1-9][0-9]*$ ]]; then
		printf 'contact-sheet --grid must be COLSxROWS, for example 4x3.\n' >&2
		return 2
	fi
	require_positive_integer --scale "$scale" || return 2
	require_positive_integer --max-side "$max_side" || return 2
	require_command ffmpeg
	require_command ffprobe
	require_command python3
	require_media_file "$media"
	contact_sheet_render "$media" "$output" "$frames" "$every" "$scenes" "$scale" "$grid" "$max_side"
	return $?
}

# Turns one validated sampling mode into a pre-filter, frame count and tile times.
contact_sheet_render() {
	local media="$1"
	local output="$2"
	local frames="$3"
	local every="$4"
	local scenes="$5"
	local scale="$6"
	local grid="$7"
	local max_side="$8"
	local geometry
	local fps
	local duration
	local pre_filter
	local count
	local times=""
	geometry=$(video_geometry "$media")
	read -r _ _ fps duration <<<"$geometry"
	if [[ -n "$frames" ]]; then
		# One frame per requested time: the window is one frame interval wide.
		pre_filter=$(python3 -c 'import sys; w = 1 / float(sys.argv[2]) if float(sys.argv[2]) > 0 else 0.04; print("+".join("gte(t\\," + x + ")*lt(t\\," + x + "+" + format(w, ".6f") + ")" for x in sys.argv[1].split(",")))' "$frames" "$fps")
		pre_filter="select='${pre_filter}'"
		count=$(python3 -c 'import sys; print(len(sys.argv[1].split(",")))' "$frames")
		times="$frames"
	elif [[ -n "$every" ]]; then
		local plan
		plan=$(python3 -c '
import math, sys
every, duration = float(sys.argv[1]), float(sys.argv[2])
if every <= 0:
    raise SystemExit("--every must be greater than 0")
count = max(1, math.ceil(duration / every))
print(format(1 / every, ".6f"), count, ",".join(format(i * every, "g") for i in range(count)))
' "$every" "$duration") || return 2
		local rate
		read -r rate count times <<<"$plan"
		pre_filter="fps=${rate}"
	else
		pre_filter="select='gt(scene,${scenes})'"
		if [[ -z "$grid" ]]; then grid="3x1"; fi
		count=$((${grid%x*} * ${grid#*x}))
	fi
	render_sheet "$media" "$output" "$pre_filter" "" "$count" "$scale" "$grid" "$max_side" "$times"
	return 0
}

strip_frames() {
	local at=""
	local output=""
	local count="12"
	local scale="240"
	local max_side="$SHEET_MAX_SIDE_DEFAULT"
	local media=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--at)
			at="$2"
			shift 2
			;;
		--out)
			output="$2"
			shift 2
			;;
		--count)
			count="$2"
			shift 2
			;;
		--scale)
			scale="$2"
			shift 2
			;;
		--max-side)
			max_side="$2"
			shift 2
			;;
		-*)
			printf 'Unknown strip option: %s\n' "$1" >&2
			return 2
			;;
		*)
			media="$1"
			shift
			;;
		esac
	done
	if [[ -z "$at" || -z "$output" || -z "$media" ]]; then
		printf 'strip requires --at, --out, and a media file.\n' >&2
		return 2
	fi
	require_positive_integer --count "$count" || return 2
	require_positive_integer --scale "$scale" || return 2
	require_positive_integer --max-side "$max_side" || return 2
	require_command ffmpeg
	require_command ffprobe
	require_command python3
	require_media_file "$media"
	local geometry
	local fps
	local times
	geometry=$(video_geometry "$media")
	read -r _ _ fps _ <<<"$geometry"
	times=$(python3 -c 'import sys; at, fps = float(sys.argv[1]), float(sys.argv[2]) or 25.0; print(",".join(format(round(at + i / fps, 4), "g") for i in range(int(sys.argv[3]))))' "$at" "$fps" "$count")
	render_sheet "$media" "$output" "trim=end_frame=${count}" "$at" "$count" "$scale" "" "$max_side" "$times"
	return 0
}

scan_media() {
	local freeze_seconds="1"
	local black_seconds="0.1"
	local silence_seconds="1"
	local silence_db="-50"
	local media=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--freeze-seconds)
			freeze_seconds="$2"
			shift 2
			;;
		--black-seconds)
			black_seconds="$2"
			shift 2
			;;
		--silence-seconds)
			silence_seconds="$2"
			shift 2
			;;
		--silence-db)
			silence_db="$2"
			shift 2
			;;
		-*)
			printf 'Unknown scan option: %s\n' "$1" >&2
			return 2
			;;
		*)
			media="$1"
			shift
			;;
		esac
	done
	if [[ -z "$media" ]]; then
		printf 'scan requires a media file.\n' >&2
		return 2
	fi
	require_command ffmpeg
	require_command ffprobe
	require_command python3
	require_media_file "$media"
	local has_audio
	local geometry
	local duration
	local log_file
	local result
	has_audio=$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$media")
	geometry=$(video_geometry "$media")
	read -r _ _ _ duration <<<"$geometry"
	local args=(-hide_banner -nostats -i "$media" -map 0:v:0 -vf "freezedetect=n=-60dB:d=${freeze_seconds},blackdetect=d=${black_seconds}:pix_th=0.10")
	if [[ -n "$has_audio" ]]; then
		args+=(-map 0:a:0 -af "silencedetect=n=${silence_db}dB:d=${silence_seconds}")
	fi
	args+=(-f null -)
	log_file=$(mktemp "${TMPDIR:-/tmp}/media-qa-scan.XXXXXX")
	if ! ffmpeg "${args[@]}" >/dev/null 2>"$log_file"; then
		printf 'Unable to scan: %s\n' "$media" >&2
		rm -f "$log_file"
		return 1
	fi
	result=$(python3 -c '
import json, re, sys
text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
length, has_audio, length_key = float(sys.argv[2] or 0), bool(sys.argv[3]), sys.argv[4]
def times(label):
    return [float(x) for x in re.findall(label + r":\s*([-+0-9.]+)", text)]
def spans(kind):
    starts, ends = times(kind + "_start"), times(kind + "_end")
    out = []
    for index, start in enumerate(starts):
        end = ends[index] if index < len(ends) else length
        out.append({"start": round(start, 3), "end": round(end, 3), length_key: round(end - start, 3)})
    return out
report = {length_key: length, "has_audio": has_audio, "freeze": spans("freeze"), "black": spans("black")}
report["silence"] = spans("silence") if has_audio else []
print(json.dumps(report, separators=(",", chr(58))))
' "$log_file" "$duration" "$has_audio" "$DURATION_KEY")
	rm -f "$log_file"
	printf '%s\n' "$result"
	return 0
}

# Compares the last decoded frame with the first, against the film's own last step.
loopcheck() {
	local media="${1:-}"
	if [[ -z "$media" ]]; then
		printf 'loopcheck requires a media file.\n' >&2
		return 2
	fi
	require_command ffmpeg
	require_command ffprobe
	require_command python3
	require_media_file "$media"
	local geometry
	local width
	local height
	local temporary_dir
	local result
	geometry=$(video_geometry "$media")
	read -r width height _ _ <<<"$geometry"
	temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/media-qa-loop.XXXXXX")
	ffmpeg -v error -y -i "$media" -map 0:v:0 -frames:v 1 -sws_flags "$SWS_ACCURATE" -pix_fmt rgb24 -f rawvideo "${temporary_dir}/first.rgb"
	ffmpeg -v error -y -sseof -0.5 -i "$media" -map 0:v:0 -sws_flags "$SWS_ACCURATE" -pix_fmt rgb24 -f rawvideo "${temporary_dir}/tail.rgb"
	if ! result=$(python3 -c '
import json, operator, sys
size = int(sys.argv[3]) * int(sys.argv[4]) * 3
first = open(sys.argv[1], "rb").read()[:size]
tail = open(sys.argv[2], "rb").read()
if size == 0 or len(first) < size or len(tail) < 2 * size:
    raise SystemExit("loopcheck needs at least two decodable frames")
last, previous = tail[len(tail) - size:], tail[len(tail) - 2 * size:len(tail) - size]
def diff(a, b):
    values = list(map(abs, map(operator.sub, a, b)))
    return round(sum(values) / len(values), 3), max(values)
seam_mean, seam_max = diff(last, first)
step_mean, step_max = diff(last, previous)
verdict = "smooth" if seam_mean <= max(step_mean * 1.5, 1.0) else "jump"
print(json.dumps({"seam_mean": seam_mean, "seam_max": seam_max, "step_mean": step_mean,
    "step_max": step_max, "verdict": verdict}, separators=(",", chr(58))))
' "${temporary_dir}/first.rgb" "${temporary_dir}/tail.rgb" "$width" "$height"); then
		rm -rf "$temporary_dir"
		return 1
	fi
	rm -rf "$temporary_dir"
	printf '%s\n' "$result"
	if [[ "$result" == *'"verdict":"jump"'* ]]; then
		return 1
	fi
	return 0
}

# Determinism: decoded per-frame hashes of two renders (or two stills) must match.
compare_media() {
	local first="${1:-}"
	local second="${2:-}"
	if [[ -z "$first" || -z "$second" ]]; then
		printf 'compare requires two media files.\n' >&2
		return 2
	fi
	require_command ffmpeg
	require_command python3
	require_media_file "$first"
	require_media_file "$second"
	local temporary_dir
	local result
	temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/media-qa-compare.XXXXXX")
	ffmpeg -v error -y -i "$first" -map 0:v:0 -f framemd5 "${temporary_dir}/a.md5"
	ffmpeg -v error -y -i "$second" -map 0:v:0 -f framemd5 "${temporary_dir}/b.md5"
	result=$(python3 -c '
import json, sys
def hashes(path):
    return [line.rsplit(",", 1)[-1].strip() for line in open(path, encoding="utf-8") if line.strip() and not line.startswith("#")]
a, b = hashes(sys.argv[1]), hashes(sys.argv[2])
mismatched = [index for index, pair in enumerate(zip(a, b)) if pair[0] != pair[1]]
identical = len(a) == len(b) and not mismatched
print(json.dumps({"frames_a": len(a), "frames_b": len(b), "mismatched": len(mismatched),
    "first_mismatch": mismatched[0] if mismatched else None, "identical": identical}, separators=(",", chr(58))))
' "${temporary_dir}/a.md5" "${temporary_dir}/b.md5")
	rm -rf "$temporary_dir"
	printf '%s\n' "$result"
	if [[ "$result" != *'"identical":true'* ]]; then
		return 1
	fi
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
	strip) strip_frames "$@" ;;
	scan) scan_media "$@" ;;
	loopcheck) loopcheck "$@" ;;
	compare) compare_media "$@" ;;
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
