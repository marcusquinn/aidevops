#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC1091

# Blender Render Helper - plan, package, submit, monitor, fetch and tear down
# Blender frame-range renders on rented GPUs. Runpod is the first provider
# adapter (functions prefixed _brh_runpod_); add _brh_vast_* / _brh_salad_*
# beside it and extend _brh_provider_call. Job contract:
# tools/design/3d-render-backends.md. Billing contract:
# tools/infrastructure/cloud-gpu.md "Billable deployment contract".
# Submit/status/fetch/teardown print commands only unless --live is given.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
if [[ ! -f "${SCRIPT_DIR}/shared-constants.sh" ]]; then
	printf 'ERROR: shared-constants.sh not found beside blender-render-helper.sh\n' >&2
	exit 1
fi
source "${SCRIPT_DIR}/shared-constants.sh"

readonly BRH_NUMBER_RE='^[0-9]+([.][0-9]+)?$'
readonly BRH_INT_RE='^[0-9]+$'
readonly BRH_RANGE_RE='^(0|[1-9][0-9]*)-(0|[1-9][0-9]*)$'
readonly BRH_DEFAULT_GPU="NVIDIA GeForce RTX 4090"
readonly BRH_REMOTE_DIR="/workspace/job"
readonly BRH_UNPINNED="unpinned"

_brh_usage() {
	cat <<'EOF'
blender-render-helper.sh - Blender renders on rented GPUs (Runpod adapter)

Usage:
  blender-render-helper.sh plan     --frames A-B --workers N --gpu-rate USD_HR --gpu-secs-per-frame S [--setup-hours H] [--api "LABEL=RATE[:asset]"]
  blender-render-helper.sh package  --blend FILE --out DIR --frames A-B [--engine CYCLES] [--device OPTIX] [--samples N] [--resolution WxH] [--blender-version V] [--asset FILE]...
  blender-render-helper.sh submit   --manifest DIR/manifest.json --workers N --gpu-rate USD_HR --budget-usd B --deadline-minutes M --approve-contract TOKEN --image IMG [--gpu-type NAME] [--volume-gb G] [--overhead-minutes M] [--storage-usd USD] [--live]
  blender-render-helper.sh stage    --job DIR --host HOST --port PORT [--live]
  blender-render-helper.sh status   --job DIR [--live]
  blender-render-helper.sh fetch    --job DIR --host HOST --port PORT [--live]
  blender-render-helper.sh teardown --job DIR [--force-discard] [--live]
  blender-render-helper.sh help

Safety:
  - submit refuses without --budget-usd and --deadline-minutes, refuses when
    workers x rate x (deadline + overhead minutes, default 15) + storage
    exceeds the budget, refuses if packaged files changed since package, and
    requires --approve-contract to equal the token printed for that exact
    contract (token covers manifest hash, image, GPU, rate, storage, workers).
  - --image is required (a CUDA-capable headless Blender image you approved).
    --gpu-rate is the quoted rate used for the ceiling; verify it in status.
  - Pods wait for staged inputs (run stage per pod), render under a deadline
    timeout, enforce the pinned Blender version, then remove themselves.
  - teardown refuses live removal while expected frames are missing locally
    unless --force-discard is given.
  - Everything is a dry run (commands printed, no network) unless --live is
    set; live mode needs RUNPOD_API_KEY, e.g.
    aidevops secret RUNPOD_API_KEY -- blender-render-helper.sh submit ... --live
  - teardown --live stops/removes every pod in the job and confirms none remain.

Job directory (from package) holds manifest.json, enable_gpu.py, jobs.tsv
(pod ids, written by live submit) and frames/ (written by fetch).
EOF
	return 0
}

_brh_require_number() {
	local name="$1"
	local value="$2"
	if [[ ! "$value" =~ $BRH_NUMBER_RE ]]; then
		print_error "${name} must be a non-negative number, got: ${value}"
		return 1
	fi
	return 0
}

_brh_require_int() {
	local name="$1"
	local value="$2"
	if [[ ! "$value" =~ $BRH_INT_RE ]] || [[ "$value" -lt 1 ]]; then
		print_error "${name} must be a positive integer, got: ${value}"
		return 1
	fi
	return 0
}

# Validates "A-B" with A <= B.
_brh_require_range() {
	local value="$1"
	if [[ ! "$value" =~ $BRH_RANGE_RE ]]; then
		print_error "--frames must look like START-END (e.g. 1-240), got: ${value}"
		return 1
	fi
	if [[ "${value%-*}" -gt "${value#*-}" ]]; then
		print_error "--frames start must not exceed end: ${value}"
		return 1
	fi
	return 0
}

# Shared option parser: --opt value pairs into BRH_O_<name> via _brh_set_opt.
# Usage: _brh_parse "allowed opts" args...  (multi-value --asset collected in BRH_ASSETS)
BRH_ASSETS=""
_brh_parse() {
	local allowed="$1"
	shift
	local opt="" val=""
	while [[ $# -gt 0 ]]; do
		opt="${1}"
		case "$opt" in
		--live)
			BRH_LIVE=1
			shift
			continue
			;;
		--dry-run)
			BRH_LIVE=0
			shift
			continue
			;;
		--force-discard)
			BRH_FORCE=1
			shift
			continue
			;;
		esac
		case " ${allowed} " in
		*" ${opt} "*) ;;
		*)
			print_error "Unknown option: ${opt}"
			return 1
			;;
		esac
		if [[ $# -lt 2 ]]; then
			print_error "${opt} requires a value"
			return 1
		fi
		val="${2}"
		case "$opt" in
		--asset) BRH_ASSETS="${BRH_ASSETS}${val}"$'\n' ;;
		*) _brh_set_opt "$opt" "$val" ;;
		esac
		shift 2
	done
	return 0
}

_brh_set_opt() {
	local opt="$1"
	local val="$2"
	local name="${opt#--}"
	name="$(printf '%s' "$name" | tr '[:lower:]-' '[:upper:]_')"
	printf -v "BRH_O_${name}" '%s' "$val"
	return 0
}

_brh_reset_opts() {
	local v=""
	for v in FRAMES WORKERS GPU_RATE GPU_SECS_PER_FRAME SETUP_HOURS API BLEND OUT ENGINE DEVICE SAMPLES RESOLUTION BLENDER_VERSION MANIFEST BUDGET_USD DEADLINE_MINUTES APPROVE_CONTRACT GPU_TYPE IMAGE VOLUME_GB OVERHEAD_MINUTES STORAGE_USD JOB HOST PORT; do
		printf -v "BRH_O_${v}" '%s' ""
	done
	BRH_ASSETS=""
	BRH_LIVE=0
	BRH_FORCE=0
	return 0
}

_brh_sha256() {
	local file="$1"
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$file" | awk '{print $1}'
	else
		shasum -a 256 "$file" | awk '{print $1}'
	fi
	return 0
}

_brh_sha256_stdin() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum | awk '{print $1}'
	else
		shasum -a 256 | awk '{print $1}'
	fi
	return 0
}

# Splits START-END into N contiguous ranges; prints "INDEX START END" lines.
_brh_split_ranges() {
	local range="$1"
	local workers="$2"
	awk -v s="${range%-*}" -v e="${range#*-}" -v w="$workers" 'BEGIN {
		total = e - s + 1
		if (w > total) w = total
		base = int(total / w); extra = total % w; cur = s
		for (i = 1; i <= w; i++) {
			len = base + (i <= extra ? 1 : 0)
			printf "%d %d %d\n", i, cur, cur + len - 1
			cur += len
		}
	}'
	return 0
}

# Minimal JSON string escape for manifest values.
_brh_json_escape() {
	local s="$1"
	s="${s//\\/\\\\}"
	s="${s//\"/\\\"}"
	printf '%s' "$s"
	return 0
}

# Reads a top-level string/number value from our own flat-ish manifest.
_brh_manifest_get() {
	local file="$1"
	local key="$2"
	sed -n "s/^[[:space:]]*\"${key}\":[[:space:]]*\"\{0,1\}\([^\",]*\)\"\{0,1\},\{0,1\}$/\1/p" "$file"
	return 0
}

# ---------------------------------------------------------------- plan

_brh_plan() {
	_brh_reset_opts
	_brh_parse "--frames --workers --gpu-rate --gpu-secs-per-frame --setup-hours --api" "$@" || return 1
	[[ -n "$BRH_O_FRAMES" ]] || {
		print_error "--frames is required"
		return 1
	}
	_brh_require_range "$BRH_O_FRAMES" || return 1
	local workers="${BRH_O_WORKERS:-1}"
	local setup="${BRH_O_SETUP_HOURS:-0}"
	_brh_require_int "--workers" "$workers" || return 1
	_brh_require_number "--setup-hours" "$setup" || return 1
	if [[ -z "$BRH_O_GPU_RATE" || -z "$BRH_O_GPU_SECS_PER_FRAME" ]]; then
		print_error "--gpu-rate and --gpu-secs-per-frame are required (benchmark one frame first)"
		return 1
	fi
	_brh_require_number "--gpu-rate" "$BRH_O_GPU_RATE" || return 1
	_brh_require_number "--gpu-secs-per-frame" "$BRH_O_GPU_SECS_PER_FRAME" || return 1

	local frames=$((${BRH_O_FRAMES#*-} - ${BRH_O_FRAMES%-*} + 1))
	printf 'Frames %s (%d total), %s worker(s):\n' "$BRH_O_FRAMES" "$frames" "$workers"
	local idx="" s="" e=""
	_brh_split_ranges "$BRH_O_FRAMES" "$workers" | while read -r idx s e; do
		printf '  worker %s: frames %s-%s (%d)\n' "$idx" "$s" "$e" $((e - s + 1))
	done
	local eff_workers="$workers"
	[[ "$eff_workers" -gt "$frames" ]] && eff_workers="$frames"
	local total_setup=""
	total_setup="$(awk -v h="$setup" -v w="$eff_workers" 'BEGIN { printf "%.4f", h * w }')"
	printf '\n'
	local -a cmd=("${SCRIPT_DIR}/media-gen-cost-helper.sh" compare --clips "$frames"
		--gpu "runpod=${BRH_O_GPU_RATE}" --gpu-secs-per-clip "$BRH_O_GPU_SECS_PER_FRAME"
		--setup-hours "$total_setup")
	if [[ -n "$BRH_O_API" ]]; then
		cmd+=(--api "$BRH_O_API")
	fi
	"${cmd[@]}" || return 1
	return 0
}

# ---------------------------------------------------------------- package

_brh_write_gpu_script() {
	local out="$1"
	local device="$2"
	cat >"$out" <<EOF
# enable_gpu.py - run with: blender -b scene.blend -Y -P enable_gpu.py
import bpy

prefs = bpy.context.preferences.addons["cycles"].preferences
prefs.compute_device_type = "${device}"
prefs.get_devices()
found = False
for dev in prefs.devices:
    dev.use = dev.type != "CPU"
    found = found or dev.use
if not found:
    raise SystemExit("enable_gpu.py: no GPU device found for ${device}")
bpy.context.scene.cycles.device = "GPU"
EOF
	return 0
}

# Applies the approved render settings on the worker and enforces the Blender pin.
_brh_write_overrides_script() {
	local out="$1"
	local bver="$2"
	local samples="$3"
	local res="$4"
	cat >"$out" <<EOF
# scene_overrides.py - run with: blender -b scene.blend -Y -P scene_overrides.py
import bpy

pinned = "${bver}"
if pinned != "${BRH_UNPINNED}" and not bpy.app.version_string.startswith(pinned):
    raise SystemExit("Blender %s does not match pinned %s" % (bpy.app.version_string, pinned))
scene = bpy.context.scene
scene.cycles.samples = ${samples}
scene.render.resolution_x = ${res%x*}
scene.render.resolution_y = ${res#*x}
scene.render.resolution_percentage = 100
EOF
	return 0
}

_brh_package() {
	_brh_reset_opts
	_brh_parse "--blend --out --frames --engine --device --samples --resolution --blender-version --asset" "$@" || return 1
	if [[ -z "$BRH_O_BLEND" || -z "$BRH_O_OUT" || -z "$BRH_O_FRAMES" ]]; then
		print_error "--blend, --out and --frames are required"
		return 1
	fi
	[[ -f "$BRH_O_BLEND" ]] || {
		print_error "Blend file not found: ${BRH_O_BLEND}"
		return 1
	}
	_brh_require_range "$BRH_O_FRAMES" || return 1
	local engine="${BRH_O_ENGINE:-CYCLES}"
	local device="${BRH_O_DEVICE:-OPTIX}"
	local samples="${BRH_O_SAMPLES:-128}"
	local res="${BRH_O_RESOLUTION:-1920x1080}"
	local bver="${BRH_O_BLENDER_VERSION:-}"
	_brh_require_int "--samples" "$samples" || return 1
	if [[ ! "$res" =~ ^[0-9]+x[0-9]+$ ]]; then
		print_error "--resolution must look like 1920x1080, got: ${res}"
		return 1
	fi
	if [[ -z "$bver" ]]; then
		print_warning "--blender-version not set; pin it so every worker renders identically"
		bver="$BRH_UNPINNED"
	fi
	mkdir -p "$BRH_O_OUT"
	_brh_write_gpu_script "${BRH_O_OUT}/enable_gpu.py" "$device"
	_brh_write_overrides_script "${BRH_O_OUT}/scene_overrides.py" "$bver" "$samples" "$res"

	local blend_sha=""
	blend_sha="$(_brh_sha256 "$BRH_O_BLEND")"
	local assets_json="" asset="" sha="" sep=""
	while IFS= read -r asset; do
		[[ -n "$asset" ]] || continue
		if [[ ! -f "$asset" ]]; then
			print_error "Asset not found: ${asset}"
			return 1
		fi
		sha="$(_brh_sha256 "$asset")"
		assets_json="${assets_json}${sep}    {\"path\": \"$(_brh_json_escape "$asset")\", \"sha256\": \"${sha}\"}"
		sep=$',\n'
	done <<<"$BRH_ASSETS"

	cat >"${BRH_O_OUT}/manifest.json" <<EOF
{
  "schema": 1,
  "blender_version": "$(_brh_json_escape "$bver")",
  "engine": "$(_brh_json_escape "$engine")",
  "device": "$(_brh_json_escape "$device")",
  "samples": ${samples},
  "resolution": "${res}",
  "frames": "${BRH_O_FRAMES}",
  "blend": "$(_brh_json_escape "$BRH_O_BLEND")",
  "blend_sha256": "${blend_sha}",
  "gpu_script": "enable_gpu.py",
  "overrides_script": "scene_overrides.py",
  "packed_assets": [
${assets_json}
  ]
}
EOF
	print_success "Packaged job in ${BRH_O_OUT} (manifest.json, enable_gpu.py, scene_overrides.py)"
	printf 'After submit, run stage per pod to upload the blend, assets and scripts to %s.\n' "$BRH_REMOTE_DIR"
	return 0
}

# ---------------------------------------------------------------- provider adapter (Runpod)

# Prints or runs a command. Dry run prints "+ cmd"; live executes.
_brh_exec() {
	if [[ "$BRH_LIVE" -eq 1 ]]; then
		"$@"
		return $?
	fi
	local out="+"
	local a=""
	for a in "$@"; do
		out="${out} $(printf '%q' "$a")"
	done
	printf '%s\n' "$out"
	return 0
}

_brh_require_live_credentials() {
	if [[ "$BRH_LIVE" -ne 1 ]]; then
		return 0
	fi
	if [[ -z "${RUNPOD_API_KEY:-}" ]]; then
		print_error "RUNPOD_API_KEY is not set. Run: aidevops secret RUNPOD_API_KEY -- blender-render-helper.sh <command> --live"
		return 1
	fi
	if ! command -v runpodctl >/dev/null 2>&1; then
		print_error "runpodctl not found (brew install runpod/runpodctl/runpodctl)"
		return 1
	fi
	return 0
}

# The command executed inside the pod for one frame range.
_brh_render_command() {
	local start="$1"
	local end="$2"
	local deadline="$3"
	local engine="$4"
	local blend_base="$5"
	# Waits for the staged-inputs marker (see stage), renders, then removes the pod.
	# The deadline timeout covers the wait too. Settings and the Blender pin are
	# applied by scene_overrides.py. No single quotes: the caller wraps in bash -c '...'.
	# shellcheck disable=SC2016
	printf 'mkdir -p %s && cd %s && timeout %sm bash -c "until [ -f .staged ]; do sleep 10; done; blender -b %s -Y -P enable_gpu.py -P scene_overrides.py -E %s -o //frames/frame_#### -s %s -e %s -a"; runpodctl remove pod $RUNPOD_POD_ID' \
		"$BRH_REMOTE_DIR" "$BRH_REMOTE_DIR" "$deadline" "$blend_base" "$engine" "$start" "$end"
	return 0
}

_brh_runpod_create() {
	local name="$1"
	local gpu_type="$2"
	local image="$3"
	local volume="$4"
	local remote_cmd="$5"
	_brh_exec runpodctl create pod --name "$name" --gpuType "$gpu_type" --gpuCount 1 \
		--imageName "$image" --volumeSize "$volume" --ports "22/tcp" \
		--args "bash -c '${remote_cmd}'"
	return $?
}

_brh_runpod_status() {
	_brh_exec runpodctl get pod
	return $?
}

_brh_runpod_teardown_one() {
	local pod_id="$1"
	_brh_exec runpodctl stop pod "$pod_id" || true
	_brh_exec runpodctl remove pod "$pod_id"
	return $?
}

# Single dispatch point so Vast.ai/SaladCloud adapters can be added later.
_brh_provider_call() {
	local action="$1"
	shift
	case "${BRH_PROVIDER:-runpod}" in
	runpod)
		case "$action" in
		create) _brh_runpod_create "$@" ;;
		status) _brh_runpod_status "$@" ;;
		teardown) _brh_runpod_teardown_one "$@" ;;
		*)
			print_error "Unknown provider action: ${action}"
			return 1
			;;
		esac
		return $?
		;;
	*)
		print_error "Unsupported provider: ${BRH_PROVIDER}"
		return 1
		;;
	esac
}

# ---------------------------------------------------------------- submit

# Deterministic text of the billable contract; its hash is the approval token.
# manifest_sha256 covers the scene hash, packed asset set, settings and scripts list.
_brh_contract_text() {
	local manifest="$1"
	local workers="$2"
	local gpu_type="$3"
	local rate="$4"
	local image="$5"
	local volume="$6"
	local deadline="$7"
	local budget="$8"
	local overhead="$9"
	local storage="${10}"
	local msha=""
	msha="$(_brh_sha256 "$manifest")"
	printf 'provider=runpod\nblender=%s\nengine=%s\ndevice=%s\nsamples=%s\nresolution=%s\nframes=%s\nmanifest_sha256=%s\nimage=%s\ngpu=%s\nrate_usd_hr=%s (quoted; verify in status)\nstorage_gb=%s\nstorage_usd=%s\nworkers_min=0\nworkers_max=%s\nidle_timeout=0 (self-removes after render)\ndeadline_minutes=%s\noverhead_minutes=%s\nbudget_usd=%s\n' \
		"$(_brh_manifest_get "$manifest" blender_version)" "$(_brh_manifest_get "$manifest" engine)" \
		"$(_brh_manifest_get "$manifest" device)" "$(_brh_manifest_get "$manifest" samples)" \
		"$(_brh_manifest_get "$manifest" resolution)" "$(_brh_manifest_get "$manifest" frames)" \
		"$msha" "$image" "$gpu_type" "$rate" "$volume" "$storage" "$workers" "$deadline" "$overhead" "$budget"
	return 0
}

# Fails when the scene or any packed asset changed since package.
_brh_verify_packaged_files() {
	local manifest="$1"
	local want="" path="" got=""
	while read -r want path; do
		[[ -n "$path" ]] || continue
		if [[ ! -f "$path" ]]; then
			print_error "Packaged file missing: ${path}"
			return 1
		fi
		got="$(_brh_sha256 "$path")"
		if [[ "$got" != "$want" ]]; then
			print_error "${path} changed since package (re-run package and re-approve)"
			return 1
		fi
	done < <(
		printf '%s %s\n' "$(_brh_manifest_get "$manifest" blend_sha256)" "$(_brh_manifest_get "$manifest" blend)"
		sed -n 's/^.*"path": "\(.*\)", "sha256": "\([0-9a-f]*\)"}.*$/\2 \1/p' "$manifest"
	)
	return 0
}

_brh_submit() {
	_brh_reset_opts
	_brh_parse "--manifest --workers --gpu-rate --budget-usd --deadline-minutes --approve-contract --gpu-type --image --volume-gb --overhead-minutes --storage-usd" "$@" || return 1
	if [[ -z "$BRH_O_BUDGET_USD" || -z "$BRH_O_DEADLINE_MINUTES" ]]; then
		print_error "submit requires --budget-usd and --deadline-minutes (spend ceiling and hard stop)"
		return 1
	fi
	if [[ -z "$BRH_O_MANIFEST" || -z "$BRH_O_GPU_RATE" || -z "$BRH_O_IMAGE" ]]; then
		print_error "--manifest, --gpu-rate (quoted USD/hour) and --image (approved CUDA Blender image) are required"
		return 1
	fi
	[[ -f "$BRH_O_MANIFEST" ]] || {
		print_error "Manifest not found: ${BRH_O_MANIFEST}"
		return 1
	}
	local workers="${BRH_O_WORKERS:-1}"
	local gpu_type="${BRH_O_GPU_TYPE:-$BRH_DEFAULT_GPU}"
	local image="$BRH_O_IMAGE"
	local volume="${BRH_O_VOLUME_GB:-50}"
	local overhead="${BRH_O_OVERHEAD_MINUTES:-15}"
	local storage="${BRH_O_STORAGE_USD:-0}"
	_brh_require_int "--workers" "$workers" || return 1
	_brh_require_int "--deadline-minutes" "$BRH_O_DEADLINE_MINUTES" || return 1
	_brh_require_int "--volume-gb" "$volume" || return 1
	_brh_require_number "--overhead-minutes" "$overhead" || return 1
	_brh_require_number "--storage-usd" "$storage" || return 1
	_brh_require_number "--budget-usd" "$BRH_O_BUDGET_USD" || return 1
	_brh_require_number "--gpu-rate" "$BRH_O_GPU_RATE" || return 1

	local frames="" blend="" engine="" bver=""
	frames="$(_brh_manifest_get "$BRH_O_MANIFEST" frames)"
	blend="$(_brh_manifest_get "$BRH_O_MANIFEST" blend)"
	engine="$(_brh_manifest_get "$BRH_O_MANIFEST" engine)"
	bver="$(_brh_manifest_get "$BRH_O_MANIFEST" blender_version)"
	_brh_require_range "$frames" || return 1
	if [[ "$bver" == "$BRH_UNPINNED" ]]; then
		print_error "Manifest has no pinned Blender version; re-run package with --blender-version"
		return 1
	fi
	_brh_verify_packaged_files "$BRH_O_MANIFEST" || return 1

	local worst=""
	worst="$(awk -v w="$workers" -v r="$BRH_O_GPU_RATE" -v m="$BRH_O_DEADLINE_MINUTES" -v o="$overhead" -v s="$storage" 'BEGIN { printf "%.2f", w * r * (m + o) / 60 + s }')"
	if awk -v a="$worst" -v b="$BRH_O_BUDGET_USD" 'BEGIN { exit !(a > b) }'; then
		print_error "Worst-case spend \$${worst} (${workers} x \$${BRH_O_GPU_RATE}/hr x (${BRH_O_DEADLINE_MINUTES}+${overhead}) min + \$${storage} storage) exceeds --budget-usd \$${BRH_O_BUDGET_USD}"
		return 1
	fi

	local contract="" token=""
	contract="$(_brh_contract_text "$BRH_O_MANIFEST" "$workers" "$gpu_type" "$BRH_O_GPU_RATE" "$image" "$volume" "$BRH_O_DEADLINE_MINUTES" "$BRH_O_BUDGET_USD" "$overhead" "$storage")"
	token="APPROVE-$(printf '%s' "$contract" | _brh_sha256_stdin | cut -c1-8 | tr '[:lower:]' '[:upper:]')"
	printf 'Billable deployment contract (worst-case spend $%s):\n%s\n\nApproval token: %s\n\n' "$worst" "$contract" "$token"
	if [[ "$BRH_O_APPROVE_CONTRACT" != "$token" ]]; then
		print_error "--approve-contract must equal the token above after the user approves this exact contract"
		return 1
	fi
	_brh_require_live_credentials || return 1

	local job_dir=""
	job_dir="$(cd "$(dirname "$BRH_O_MANIFEST")" && pwd)" || return 1
	local blend_base=""
	blend_base="$(basename "$blend")"
	local idx="" s="" e="" remote_cmd="" name="" pod_out="" pod_id=""
	while read -r idx s e; do
		remote_cmd="$(_brh_render_command "$s" "$e" "$BRH_O_DEADLINE_MINUTES" "$engine" "$blend_base")"
		name="blender-render-${idx}-$(printf '%s' "$token" | cut -c9-14)"
		printf '# worker %s: frames %s-%s\n' "$idx" "$s" "$e"
		pod_out="$(_brh_provider_call create "$name" "$gpu_type" "$image" "$volume" "$remote_cmd")" || return 1
		printf '%s\n' "$pod_out"
		if [[ "$BRH_LIVE" -eq 1 ]]; then
			pod_id="$(printf '%s\n' "$pod_out" | sed -n 's/.*pod "\{0,1\}\([A-Za-z0-9]*\)"\{0,1\} created.*/\1/p')"
			if [[ -z "$pod_id" ]]; then
				print_error "Could not read the pod id from runpodctl output; run status and teardown manually"
				return 1
			fi
			printf '%s\t%s\t%s\t%s\n' "$idx" "$s" "$e" "$pod_id" >>"${job_dir}/jobs.tsv"
		fi
	done < <(_brh_split_ranges "$frames" "$workers")
	if [[ "$BRH_LIVE" -eq 1 ]]; then
		print_info "Pod ids recorded in ${job_dir}/jobs.tsv. Pods wait for staging: run stage per pod (host/port from status), then fetch and teardown."
	else
		print_info "Dry run: nothing created. Re-run with --live after approval; then stage inputs per pod."
	fi
	return 0
}

# Uploads scene, assets and scripts, then releases the pod's wait loop.
_brh_stage() {
	_brh_reset_opts
	_brh_parse "--job --host --port" "$@" || return 1
	if [[ -z "$BRH_O_JOB" || -z "$BRH_O_HOST" || -z "$BRH_O_PORT" ]]; then
		print_error "--job, --host and --port (pod SSH endpoint from status) are required"
		return 1
	fi
	local manifest="${BRH_O_JOB}/manifest.json"
	[[ -f "$manifest" ]] || {
		print_error "No manifest.json in ${BRH_O_JOB}"
		return 1
	}
	_brh_verify_packaged_files "$manifest" || return 1
	local ssh_cmd="ssh -p ${BRH_O_PORT} -o StrictHostKeyChecking=accept-new"
	local dest="root@${BRH_O_HOST}"
	local path="" want=""
	while read -r want path; do
		[[ -n "$path" ]] || continue
		_brh_exec rsync -av -e "$ssh_cmd" "$path" "${dest}:${BRH_REMOTE_DIR}/$(basename "$path")" || return 1
	done < <(
		printf '%s %s\n' "x" "$(_brh_manifest_get "$manifest" blend)"
		sed -n 's/^.*"path": "\(.*\)", "sha256": "\([0-9a-f]*\)"}.*$/\2 \1/p' "$manifest"
	)
	_brh_exec rsync -av -e "$ssh_cmd" "${BRH_O_JOB}/enable_gpu.py" "${BRH_O_JOB}/scene_overrides.py" "${dest}:${BRH_REMOTE_DIR}/" || return 1
	_brh_exec ssh -p "$BRH_O_PORT" -o StrictHostKeyChecking=accept-new "$dest" "touch ${BRH_REMOTE_DIR}/.staged" || return 1
	return 0
}

# ---------------------------------------------------------------- status / fetch / teardown

_brh_status() {
	_brh_reset_opts
	_brh_parse "--job" "$@" || return 1
	[[ -n "$BRH_O_JOB" ]] || {
		print_error "--job DIR is required"
		return 1
	}
	_brh_require_live_credentials || return 1
	if [[ -f "${BRH_O_JOB}/jobs.tsv" ]]; then
		printf 'Workers (index start end pod):\n'
		cat "${BRH_O_JOB}/jobs.tsv"
	fi
	_brh_provider_call status
	return $?
}

_brh_fetch() {
	_brh_reset_opts
	_brh_parse "--job --host --port" "$@" || return 1
	if [[ -z "$BRH_O_JOB" || -z "$BRH_O_HOST" || -z "$BRH_O_PORT" ]]; then
		print_error "--job, --host and --port (pod SSH endpoint from status) are required"
		return 1
	fi
	[[ -f "${BRH_O_JOB}/manifest.json" ]] || {
		print_error "No manifest.json in ${BRH_O_JOB}"
		return 1
	}
	mkdir -p "${BRH_O_JOB}/frames"
	# Run once per pod (each pod holds only its own range). --checksum makes re-runs
	# resumable: identical frames are skipped, partial or changed ones are re-fetched;
	# rsync only publishes a file after its transfer completes.
	_brh_exec rsync -av --checksum -e "ssh -p ${BRH_O_PORT} -o StrictHostKeyChecking=accept-new" \
		"root@${BRH_O_HOST}:${BRH_REMOTE_DIR}/frames/" "${BRH_O_JOB}/frames/" || return 1
	if [[ "$BRH_LIVE" -ne 1 ]]; then
		return 0
	fi
	local frames="" expected=0 missing=""
	frames="$(_brh_manifest_get "${BRH_O_JOB}/manifest.json" frames)"
	expected=$((${frames#*-} - ${frames%-*} + 1))
	missing="$(_brh_missing_frames "$BRH_O_JOB")"
	(cd "${BRH_O_JOB}/frames" && find . -type f ! -name 'SHA256SUMS' | LC_ALL=C sort | while read -r f; do
		printf '%s  %s\n' "$(_brh_sha256 "$f")" "$f"
	done >SHA256SUMS)
	if [[ -n "$missing" ]]; then
		print_warning "Missing frames (of ${expected}): $(printf '%s' "$missing" | tr '\n' ' ')"
		print_warning "Fetch from the remaining pods once they finish, then re-check"
	else
		print_success "All ${expected} expected frames present (hashes in frames/SHA256SUMS)"
	fi
	return 0
}

# Prints each expected frame number with no matching frame_NNNN.* file (empty = complete).
_brh_missing_frames() {
	local job="$1"
	local frames=""
	if [[ ! -f "${job}/manifest.json" ]]; then
		return 0
	fi
	frames="$(_brh_manifest_get "${job}/manifest.json" frames)"
	if [[ ! "$frames" =~ $BRH_RANGE_RE ]]; then
		return 0
	fi
	local n="${frames%-*}"
	local end="${frames#*-}"
	local padded=""
	while [[ "$n" -le "$end" ]]; do
		padded="$(printf '%04d' "$n")"
		if ! compgen -G "${job}/frames/frame_${padded}.*" >/dev/null; then
			printf '%s\n' "$n"
		fi
		n=$((n + 1))
	done
	return 0
}

_brh_teardown() {
	_brh_reset_opts
	_brh_parse "--job" "$@" || return 1
	[[ -n "$BRH_O_JOB" ]] || {
		print_error "--job DIR is required"
		return 1
	}
	_brh_require_live_credentials || return 1
	if [[ ! -f "${BRH_O_JOB}/jobs.tsv" ]]; then
		print_warning "No jobs.tsv in ${BRH_O_JOB}; nothing recorded to tear down"
		if [[ "$BRH_LIVE" -eq 1 ]]; then
			print_warning "Check the provider dashboard for stray pods and network volumes"
		fi
		return 0
	fi
	local idx="" s="" e="" pod="" failed=0 missing=""
	missing="$(_brh_missing_frames "$BRH_O_JOB")"
	if [[ -n "$missing" ]]; then
		if [[ "$BRH_LIVE" -eq 1 && "$BRH_FORCE" -ne 1 ]]; then
			print_error "Refusing to remove pods: frames not fetched locally: $(printf '%s' "$missing" | tr '\n' ' ')"
			print_error "Fetch them from each pod first, or pass --force-discard to accept losing them"
			return 1
		fi
		print_warning "Frames still missing locally: $(printf '%s' "$missing" | tr '\n' ' ')"
	fi
	while IFS=$'\t' read -r idx s e pod; do
		[[ -n "$pod" ]] || continue
		_brh_provider_call teardown "$pod" || failed=1
	done <"${BRH_O_JOB}/jobs.tsv"
	if [[ "$BRH_LIVE" -ne 1 ]]; then
		printf '+ runpodctl get pod   # then confirm none of the job pod ids are listed\n'
		return 0
	fi
	local remaining=""
	if ! remaining="$(runpodctl get pod)"; then
		print_error "Could not list pods to confirm removal: check the provider dashboard before assuming billing stopped"
		return 1
	fi
	while IFS=$'\t' read -r idx s e pod; do
		[[ -n "$pod" ]] || continue
		if printf '%s' "$remaining" | grep -qF "$pod"; then
			print_error "Pod ${pod} still listed: billing may continue"
			failed=1
		fi
	done <"${BRH_O_JOB}/jobs.tsv"
	if [[ "$failed" -ne 0 ]]; then
		return 1
	fi
	print_success "All job pods removed and none listed. Check the dashboard for any network volumes you created separately."
	return 0
}

main() {
	local command="${1:-help}"
	if [[ $# -gt 0 ]]; then
		shift
	fi
	BRH_LIVE=0
	BRH_PROVIDER="${BRH_PROVIDER:-runpod}"
	case "$command" in
	plan) _brh_plan "$@" ;;
	package) _brh_package "$@" ;;
	submit) _brh_submit "$@" ;;
	stage) _brh_stage "$@" ;;
	status) _brh_status "$@" ;;
	fetch) _brh_fetch "$@" ;;
	teardown) _brh_teardown "$@" ;;
	help | -h | --help)
		_brh_usage
		return 0
		;;
	*)
		print_error "Unknown command: ${command}"
		_brh_usage
		return 1
		;;
	esac
	return $?
}

main "$@"
