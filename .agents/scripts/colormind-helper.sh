#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# colormind-helper.sh — Colour palette generation via Colormind AI API
#
# Usage:
#   colormind-helper.sh generate                          # Random palette
#   colormind-helper.sh generate --lock "#6366f1"         # Lock primary, generate rest
#   colormind-helper.sh generate --lock "#6366f1,N,N,N,#ffffff"  # Lock specific positions
#   colormind-helper.sh spin "#6366f1" [--count 6]        # Hue-rotate spins
#   colormind-helper.sh models                            # List available models
#   colormind-helper.sh format <r,g,b> <r,g,b> ...       # Convert RGB arrays to hex
#
# Output: Hex colour values with semantic role names, suitable for DESIGN.md Section 2.
# API: http://colormind.io/api/ (no auth required, rate-limited)

set -Eeuo pipefail

readonly SCRIPT_NAME="colormind-helper"
readonly API_URL="http://colormind.io/api/"
readonly ROLES=("background" "surface" "accent" "secondary" "text")

# Colours for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[OK]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

usage() {
	cat <<'EOF'
Usage:
  colormind-helper.sh generate [options]     Generate a palette
  colormind-helper.sh spin <hex> [options]   Generate hue-rotation spins
  colormind-helper.sh models                 List available AI models
  colormind-helper.sh contrast <fg> <bg>     Check WCAG contrast ratio

Generate Options:
  --lock <spec>     Lock colours: hex for fixed, N for generated
                    Single hex: locks position 1 (darkest)
                    Comma-separated: "#hex,N,N,N,#hex" (5 positions)
  --model <name>    AI model (default: "default")
  --json            Output as JSON instead of table

Spin Options:
  --count <n>       Number of spins (default: 6)
  --step <degrees>  Hue rotation step (default: 30)

Examples:
  colormind-helper.sh generate
  colormind-helper.sh generate --lock "#6366f1"
  colormind-helper.sh generate --lock "#6366f1,N,N,N,#ffffff"
  colormind-helper.sh spin "#6366f1" --count 8
  colormind-helper.sh contrast "#ffffff" "#6366f1"
EOF
	return 0
}

# Convert hex (#RRGGBB or RRGGBB) to RGB array string "[R,G,B]"
hex_to_rgb() {
	local hex="$1"
	hex="${hex#\#}"
	local r g b
	r=$((16#${hex:0:2}))
	g=$((16#${hex:2:2}))
	b=$((16#${hex:4:2}))
	printf '[%d,%d,%d]' "$r" "$g" "$b"
	return 0
}

# Convert RGB values to hex
rgb_to_hex() {
	local r="$1" g="$2" b="$3"
	printf '#%02x%02x%02x' "$r" "$g" "$b"
	return 0
}

# Convert hex to HSL (returns "H S L" space-separated, H=0-360, S/L=0-100)
hex_to_hsl() {
	local hex="$1"
	hex="${hex#\#}"
	local r g b
	r=$((16#${hex:0:2}))
	g=$((16#${hex:2:2}))
	b=$((16#${hex:4:2}))

	# Use awk for floating point
	awk -v r="$r" -v g="$g" -v b="$b" 'BEGIN {
		rf = r/255; gf = g/255; bf = b/255
		max = rf; if (gf > max) max = gf; if (bf > max) max = bf
		min = rf; if (gf < min) min = gf; if (bf < min) min = bf
		l = (max + min) / 2
		if (max == min) { h = 0; s = 0 }
		else {
			d = max - min
			s = (l > 0.5) ? d / (2 - max - min) : d / (max + min)
			if (max == rf) h = (gf - bf) / d + (gf < bf ? 6 : 0)
			else if (max == gf) h = (bf - rf) / d + 2
			else h = (rf - gf) / d + 4
			h = h / 6
		}
		printf "%d %d %d", h*360, s*100, l*100
	}'
	return 0
}

# Convert HSL to hex
hsl_to_hex() {
	local h="$1" s="$2" l="$3"

	awk -v h="$h" -v s="$s" -v l="$l" 'BEGIN {
		h = h / 360; s = s / 100; l = l / 100
		if (s == 0) { r = g = b = l }
		else {
			q = (l < 0.5) ? l * (1 + s) : l + s - l * s
			p = 2 * l - q
			# hue to rgb helper inline
			# Red
			t = h + 1/3; if (t < 0) t += 1; if (t > 1) t -= 1
			if (t < 1/6) r = p + (q-p)*6*t
			else if (t < 1/2) r = q
			else if (t < 2/3) r = p + (q-p)*(2/3-t)*6
			else r = p
			# Green
			t = h; if (t < 0) t += 1; if (t > 1) t -= 1
			if (t < 1/6) g = p + (q-p)*6*t
			else if (t < 1/2) g = q
			else if (t < 2/3) g = p + (q-p)*(2/3-t)*6
			else g = p
			# Blue
			t = h - 1/3; if (t < 0) t += 1; if (t > 1) t -= 1
			if (t < 1/6) b = p + (q-p)*6*t
			else if (t < 1/2) b = q
			else if (t < 2/3) b = p + (q-p)*(2/3-t)*6
			else b = p
		}
		printf "#%02x%02x%02x", int(r*255+0.5), int(g*255+0.5), int(b*255+0.5)
	}'
	return 0
}

# Calculate WCAG contrast ratio between two hex colours
calc_contrast() {
	local fg="$1" bg="$2"
	fg="${fg#\#}"
	bg="${bg#\#}"

	# Use shell to pre-parse hex to decimal (BSD awk lacks strtonum)
	local fr fg_val fb br bg_val bb
	fr=$((16#${fg:0:2}))
	fg_val=$((16#${fg:2:2}))
	fb=$((16#${fg:4:2}))
	br=$((16#${bg:0:2}))
	bg_val=$((16#${bg:2:2}))
	bb=$((16#${bg:4:2}))

	awk -v fr="$fr" -v fgv="$fg_val" -v fb="$fb" -v br="$br" -v bgv="$bg_val" -v bb="$bb" 'BEGIN {
		# Normalise 0-255 to 0-1
		fr = fr/255; fgv = fgv/255; fb = fb/255
		br = br/255; bgv = bgv/255; bb = bb/255
		# Linearise (sRGB gamma)
		fr = (fr <= 0.03928) ? fr/12.92 : ((fr+0.055)/1.055)^2.4
		fgv = (fgv <= 0.03928) ? fgv/12.92 : ((fgv+0.055)/1.055)^2.4
		fb = (fb <= 0.03928) ? fb/12.92 : ((fb+0.055)/1.055)^2.4
		br = (br <= 0.03928) ? br/12.92 : ((br+0.055)/1.055)^2.4
		bgv = (bgv <= 0.03928) ? bgv/12.92 : ((bgv+0.055)/1.055)^2.4
		bb = (bb <= 0.03928) ? bb/12.92 : ((bb+0.055)/1.055)^2.4
		# Luminance
		l1 = 0.2126*fr + 0.7152*fgv + 0.0722*fb
		l2 = 0.2126*br + 0.7152*bgv + 0.0722*bb
		# Contrast
		if (l1 > l2) ratio = (l1 + 0.05) / (l2 + 0.05)
		else ratio = (l2 + 0.05) / (l1 + 0.05)
		printf "%.2f", ratio
	}'
	return 0
}

# Call Colormind API
call_colormind() {
	local input_json="$1"
	local model="${2:-default}"

	local response
	response=$(curl -s -X POST "$API_URL" \
		--data "{\"input\":${input_json},\"model\":\"${model}\"}" \
		--max-time 10 2>/dev/null) || {
		print_error "Colormind API request failed"
		return 1
	}

	# Extract result array
	echo "$response" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for rgb in data['result']:
        print(f'#{rgb[0]:02x}{rgb[1]:02x}{rgb[2]:02x}')
except Exception as e:
    print(f'ERROR: {e}', file=sys.stderr)
    sys.exit(1)
" 2>/dev/null || {
		# Fallback: try jq
		echo "$response" | jq -r '.result[] | "#" + (.[0] | floor | tostring | if length == 1 then "0" + . else . end) + (.[1] | floor | tostring | if length == 1 then "0" + . else . end) + (.[2] | floor | tostring | if length == 1 then "0" + . else . end)' 2>/dev/null || {
			print_error "Failed to parse Colormind response"
			return 1
		}
	}
	return 0
}

# Build Colormind API input array from a lock spec string
# Usage: _build_colormind_input <lock_spec>
# Outputs the JSON input array string to stdout
_build_colormind_input() {
	local lock_spec="$1"
	local arr_items=()
	local parts p rgb

	if [[ -z "$lock_spec" ]]; then
		echo "[\"N\",\"N\",\"N\",\"N\",\"N\"]"
		return 0
	fi

	if [[ "$lock_spec" != *","* ]]; then
		# Single hex: lock position 1 (darkest)
		rgb=$(hex_to_rgb "$lock_spec")
		printf '[%s,"N","N","N","N"]' "$rgb"
		return 0
	fi

	# Comma-separated: parse each position
	IFS=',' read -ra parts <<<"$lock_spec"
	if [[ ${#parts[@]} -gt 5 ]]; then
		print_error "Lock spec has ${#parts[@]} positions; maximum is 5 (got: $lock_spec)"
		return 1
	fi
	for p in "${parts[@]}"; do
		p="$(echo "$p" | xargs)" # trim whitespace
		if [[ "$p" == "N" || "$p" == "n" ]]; then
			arr_items+=("\"N\"")
		else
			arr_items+=("$(hex_to_rgb "$p")")
		fi
	done
	# Pad to 5 items
	while [[ ${#arr_items[@]} -lt 5 ]]; do
		arr_items+=("\"N\"")
	done
	printf '[%s]' "$(IFS=, && echo "${arr_items[*]}")"
	return 0
}

# Output palette as JSON object
# Usage: _output_palette_json <colour_arr[@]>
_output_palette_json() {
	local -a colour_arr=("$@")
	local i role comma

	echo "{"
	for i in "${!colour_arr[@]}"; do
		role="${ROLES[$i]:-colour_$i}"
		comma=","
		[[ $i -eq $((${#colour_arr[@]} - 1)) ]] && comma=""
		echo "  \"$role\": \"${colour_arr[$i]}\"$comma"
	done
	echo "}"
	return 0
}

# Output palette as formatted table with WCAG contrast check
# Usage: _output_palette_table <colour_arr[@]>
_output_palette_table() {
	local -a colour_arr=("$@")
	local i role ratio pass

	echo ""
	echo "  Generated Palette"
	echo "  ─────────────────────────────────"
	for i in "${!colour_arr[@]}"; do
		role="${ROLES[$i]:-colour_$i}"
		printf "  %-12s  %s\n" "$role" "${colour_arr[$i]}"
	done
	echo ""

	# Contrast check: text (position 4) on background (position 0)
	if [[ ${#colour_arr[@]} -ge 5 ]]; then
		ratio=$(calc_contrast "${colour_arr[4]}" "${colour_arr[0]}")
		pass="FAIL"
		if awk "BEGIN { exit !($ratio >= 4.5) }" 2>/dev/null; then
			pass="PASS"
		fi
		echo "  Contrast (text on bg): ${ratio}:1 [WCAG AA: ${pass}]"
	else
		print_warning "Palette has fewer than 5 colours; contrast check skipped"
	fi
	echo ""
	return 0
}

# Generate palette command
cmd_generate() {
	local lock_spec=""
	local model="default"
	local json_output=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--lock)
			if [[ $# -lt 2 || "$2" == --* ]]; then
				print_error "Missing value for --lock"
				return 1
			fi
			lock_spec="$2"
			shift 2
			;;
		--model)
			if [[ $# -lt 2 || "$2" == --* ]]; then
				print_error "Missing value for --model"
				return 1
			fi
			model="$2"
			shift 2
			;;
		--json)
			json_output=true
			shift
			;;
		-h | --help)
			usage
			return 0
			;;
		*)
			print_error "Unknown option: $1"
			usage >&2
			return 1
			;;
		esac
	done

	local input colours
	local colour_arr=()

	input=$(_build_colormind_input "$lock_spec")
	print_info "Generating palette (model: $model)..."
	colours=$(call_colormind "$input" "$model") || return 1

	while IFS= read -r line; do
		colour_arr+=("$line")
	done <<<"$colours"

	if [[ "$json_output" == "true" ]]; then
		_output_palette_json "${colour_arr[@]}"
	else
		_output_palette_table "${colour_arr[@]}"
	fi

	return 0
}

# Spin palette command (hue rotation)
cmd_spin() {
	local base_hex="${1:-}"
	shift 2>/dev/null || true

	local count=6
	local step=30

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--count)
			count="$2"
			shift 2
			;;
		--step)
			step="$2"
			shift 2
			;;
		-h | --help)
			usage
			return 0
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$base_hex" ]]; then
		print_error "Missing base colour hex value"
		usage
		return 1
	fi

	local hsl
	hsl=$(hex_to_hsl "$base_hex")
	local base_h base_s base_l
	read -r base_h base_s base_l <<<"$hsl"

	echo ""
	echo "  Hue Rotation Spins (base: $base_hex, H:${base_h} S:${base_s} L:${base_l})"
	echo "  ───────────────────────────────────────────────"
	printf "  %-8s  %-10s  %-10s  %s\n" "Spin" "Hue" "Hex" "Description"
	echo "  ───────────────────────────────────────────────"

	for ((i = 0; i < count; i++)); do
		local rotation=$((i * step))
		local new_h=$(((base_h + rotation) % 360))
		local new_hex
		new_hex=$(hsl_to_hex "$new_h" "$base_s" "$base_l")

		local desc=""
		case "$rotation" in
		0) desc="Original" ;;
		30) desc="+30 (analogous)" ;;
		60) desc="+60 (warm shift)" ;;
		90) desc="+90 (split)" ;;
		120) desc="+120 (triadic)" ;;
		150) desc="+150 (near-complement)" ;;
		180) desc="+180 (complementary)" ;;
		210) desc="+210 (cool split)" ;;
		240) desc="+240 (triadic)" ;;
		270) desc="+270 (cool shift)" ;;
		300) desc="+300 (near-analogous)" ;;
		330) desc="+330 (warm analogous)" ;;
		*) desc="+${rotation}" ;;
		esac

		printf "  %-8d  %-10d  %-10s  %s\n" "$((i + 1))" "$new_h" "$new_hex" "$desc"
	done
	echo ""

	return 0
}

# List available models
cmd_models() {
	print_info "Fetching available Colormind models..."
	local response
	response=$(curl -s "$API_URL" --data '{"model":"list"}' --max-time 10 2>/dev/null) || {
		# Fallback: list known models
		echo "Known models: default, ui (availability varies)"
		return 0
	}
	echo "$response" | python3 -c "import sys,json; [print(m) for m in json.load(sys.stdin).get('result',['default'])]" 2>/dev/null || echo "default"
	return 0
}

# Contrast check command
cmd_contrast() {
	local fg="${1:-}"
	local bg="${2:-}"

	if [[ -z "$fg" || -z "$bg" ]]; then
		print_error "Usage: colormind-helper.sh contrast <foreground-hex> <background-hex>"
		return 1
	fi

	local ratio
	ratio=$(calc_contrast "$fg" "$bg")

	local aa_normal="FAIL" aa_large="FAIL" aaa_normal="FAIL"
	if awk "BEGIN { exit !($ratio >= 4.5) }" 2>/dev/null; then aa_normal="PASS"; fi
	if awk "BEGIN { exit !($ratio >= 3.0) }" 2>/dev/null; then aa_large="PASS"; fi
	if awk "BEGIN { exit !($ratio >= 7.0) }" 2>/dev/null; then aaa_normal="PASS"; fi

	echo ""
	echo "  Contrast: $fg on $bg"
	echo "  Ratio: ${ratio}:1"
	echo "  WCAG AA (normal text):  $aa_normal (requires 4.5:1)"
	echo "  WCAG AA (large text):   $aa_large (requires 3.0:1)"
	echo "  WCAG AAA (normal text): $aaa_normal (requires 7.0:1)"
	echo ""

	return 0
}

# Main
main() {
	local cmd="${1:-}"
	shift 2>/dev/null || true

	case "$cmd" in
	generate | g) cmd_generate "$@" ;;
	spin | s) cmd_spin "$@" ;;
	models | m) cmd_models "$@" ;;
	contrast | c) cmd_contrast "$@" ;;
	-h | --help | help) usage ;;
	"")
		print_error "No command specified"
		usage
		return 1
		;;
	*)
		print_error "Unknown command: $cmd"
		usage
		return 1
		;;
	esac
}

main "$@"
