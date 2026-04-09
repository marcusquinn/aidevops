#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
set -euo pipefail

# Email Export Helper for AI DevOps Framework
# Exports email threads for legal case assembly with chain-of-custody manifests.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh"

readonly EMAIL_TO_MD_SCRIPT="${SCRIPT_DIR}/email-to-markdown.py"
readonly MAILBOX_HELPER_SCRIPT="${SCRIPT_DIR}/email-mailbox-helper.sh"
readonly DEFAULT_EXPORT_BASE="${HOME}/.aidevops/.agent-workspace/email-case-exports"

timestamp_utc() {
	date -u +"%Y-%m-%dT%H:%M:%SZ"
	return 0
}

slugify() {
	local input="$1"
	local lower
	lower=$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]')
	local clean
	clean=$(printf '%s' "$lower" | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
	if [[ -z "$clean" ]]; then
		echo "case-export"
		return 0
	fi
	echo "$clean"
	return 0
}

compute_sha256() {
	local file_path="$1"
	if command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$file_path" | cut -d' ' -f1
		return 0
	fi
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$file_path" | cut -d' ' -f1
		return 0
	fi
	print_error "Neither shasum nor sha256sum is available"
	return 1
}

extract_frontmatter_value() {
	local markdown_file="$1"
	local key="$2"
	awk -v k="$key" '
		BEGIN { in_frontmatter = 0 }
		/^---$/ {
			if (in_frontmatter == 0) {
				in_frontmatter = 1
				next
			}
			exit
		}
		in_frontmatter == 1 && $0 ~ "^" k ":" {
			sub("^" k ":[[:space:]]*", "")
			print
			exit
		}
	' "$markdown_file"
	return 0
}

check_dependencies() {
	local export_format="$1"

	if [[ ! -f "$EMAIL_TO_MD_SCRIPT" ]]; then
		print_error "Missing dependency: ${EMAIL_TO_MD_SCRIPT}"
		return 1
	fi

	if ! command -v python3 >/dev/null 2>&1; then
		print_error "python3 is required"
		return 1
	fi

	if [[ "$export_format" == "pdf" ]] && ! command -v pandoc >/dev/null 2>&1; then
		print_error "pandoc is required for --format pdf"
		return 1
	fi

	return 0
}

build_case_directories() {
	local case_root="$1"
	mkdir -p "$case_root/threads"
	mkdir -p "$case_root/attachments"
	mkdir -p "$case_root/source"
	return 0
}

write_manifest_header() {
	local manifest_file="$1"
	local case_name="$2"
	local source_dir="$3"
	local export_format="$4"
	local case_root="$5"

	cat >"$manifest_file" <<EOF
# Legal Case Email Export Manifest

- Case: ${case_name}
- Exported At (UTC): $(timestamp_utc)
- Export Format: ${export_format}
- Source Directory: ${source_dir}
- Case Root: ${case_root}
- Hostname: $(hostname)

## Chain of Custody

All files listed below include SHA-256 hashes computed at export time.
Attachments are copied into case-scoped directories and individually hashed.

## Exported Messages

EOF

	return 0
}

write_plaintext_from_markdown() {
	local markdown_file="$1"
	local output_file="$2"

	python3 - "$markdown_file" "$output_file" <<'PY'
import pathlib
import re
import sys

md_path = pathlib.Path(sys.argv[1])
txt_path = pathlib.Path(sys.argv[2])
content = md_path.read_text(encoding="utf-8")

# Strip YAML frontmatter if present.
if content.startswith("---\n"):
    end = content.find("\n---\n", 4)
    if end != -1:
        content = content[end + 5 :]

# Lightweight markdown cleanup for readable plain text.
content = re.sub(r"^#{1,6}\s+", "", content, flags=re.MULTILINE)
content = re.sub(r"\*\*(.*?)\*\*", r"\1", content)
content = re.sub(r"\*(.*?)\*", r"\1", content)
content = re.sub(r"`([^`]+)`", r"\1", content)

txt_path.write_text(content.strip() + "\n", encoding="utf-8")
PY

	return 0
}

append_attachment_manifest() {
	local attachment_dir="$1"
	local attachment_manifest="$2"
	local manifest_name
	manifest_name="$(basename "$attachment_manifest")"
	local temp_manifest
	temp_manifest="${attachment_manifest}.tmp"

	if [[ ! -d "$attachment_dir" ]]; then
		return 0
	fi

	{
		echo "filename,size_bytes,sha256"
		while IFS= read -r -d '' file_path; do
			local filename
			filename=$(basename "$file_path")
			# RFC 4180: escape embedded double-quotes in filename; quoting of all fields done in printf
			local escaped_filename
			escaped_filename="${filename//\"/\"\"}"
			local size_bytes
			size_bytes=$(wc -c <"$file_path" | tr -d ' ')
			local checksum
			checksum=$(compute_sha256 "$file_path")
			printf '"%s","%s","%s"\n' "$escaped_filename" "$size_bytes" "$checksum"
		done < <(find "$attachment_dir" -type f ! -name "$manifest_name" -print0 | sort -z)
	} >"$temp_manifest"

	mv "$temp_manifest" "$attachment_manifest"

	return 0
}

append_manifest_entry() {
	local manifest_file="$1"
	local source_file="$2"
	local markdown_file="$3"
	local export_file="$4"
	local attachment_dir="$5"

	local message_id
	message_id=$(extract_frontmatter_value "$markdown_file" "message_id")
	local sender
	sender=$(extract_frontmatter_value "$markdown_file" "from")
	local date_sent
	date_sent=$(extract_frontmatter_value "$markdown_file" "date_sent")
	local date_received
	date_received=$(extract_frontmatter_value "$markdown_file" "date_received")
	local subject
	subject=$(extract_frontmatter_value "$markdown_file" "subject")

	local source_hash
	source_hash=$(compute_sha256 "$source_file")
	local markdown_hash
	markdown_hash=$(compute_sha256 "$markdown_file")
	local export_hash
	export_hash=$(compute_sha256 "$export_file")

	local attachment_count=0
	local manifest_name
	manifest_name="attachment-manifest.csv"
	local attachment_manifest_hash=""
	if [[ -d "$attachment_dir" ]]; then
		attachment_count=$(find "$attachment_dir" -type f ! -name "$manifest_name" | wc -l | tr -d ' ')
		if [[ -f "$attachment_dir/$manifest_name" ]]; then
			attachment_manifest_hash=$(compute_sha256 "$attachment_dir/$manifest_name")
		fi
	fi

	cat >>"$manifest_file" <<EOF
### $(basename "$export_file")

- Subject: ${subject}
- Message-ID: ${message_id}
- Sender: ${sender}
- Date Sent: ${date_sent}
- Date Received: ${date_received}
- Source File: ${source_file}
- Source SHA-256: ${source_hash}
- Markdown SHA-256: ${markdown_hash}
- Export SHA-256: ${export_hash}
- Attachment Count: ${attachment_count}
EOF

	if [[ "$attachment_count" -gt 0 ]]; then
		cat >>"$manifest_file" <<EOF
- Attachment Manifest: ${attachment_dir}/${manifest_name}
- Attachment Manifest SHA-256: ${attachment_manifest_hash}
EOF
	fi

	# Blank line separator between manifest entries
	echo "" >>"$manifest_file"

	return 0
}

copy_source_email() {
	local source_file="$1"
	local case_root="$2"
	local prefixed_name="$3"

	cp "$source_file" "$case_root/source/${prefixed_name}"
	return 0
}

export_single_message() {
	local source_file="$1"
	local case_root="$2"
	local prefixed_name="$3"
	local export_format="$4"
	local manifest_file="$5"

	local stem
	stem="${prefixed_name%.*}"
	local markdown_file="$case_root/threads/${stem}.md"
	local attachment_dir="$case_root/attachments/${stem}"

	python3 "$EMAIL_TO_MD_SCRIPT" "$source_file" \
		--output "$markdown_file" \
		--attachments-dir "$attachment_dir" || return 1

	local export_file="$markdown_file"
	if [[ "$export_format" == "pdf" ]]; then
		export_file="$case_root/threads/${stem}.pdf"
		pandoc "$markdown_file" -o "$export_file" || return 1
	elif [[ "$export_format" == "text" ]]; then
		export_file="$case_root/threads/${stem}.txt"
		write_plaintext_from_markdown "$markdown_file" "$export_file" || return 1
	fi

	append_attachment_manifest "$attachment_dir" "$attachment_dir/attachment-manifest.csv" || return 1
	append_manifest_entry "$manifest_file" "$source_file" "$markdown_file" "$export_file" "$attachment_dir" || return 1

	return 0
}

cmd_export() {
	local source_dir="$1"
	local case_name="$2"
	local export_format="${3:-pdf}"
	local output_dir="${4:-}"

	if [[ -z "$source_dir" || -z "$case_name" ]]; then
		print_error "Usage: email-export-helper.sh export <source_dir> <case_name> [pdf|text|markdown] [output_dir]"
		return 1
	fi

	if [[ ! -d "$source_dir" ]]; then
		print_error "Source directory not found: $source_dir"
		return 1
	fi

	if [[ "$export_format" != "pdf" && "$export_format" != "text" && "$export_format" != "markdown" ]]; then
		print_error "Invalid export format: $export_format"
		return 1
	fi

	check_dependencies "$export_format" || return 1

	local case_slug
	case_slug=$(slugify "$case_name")
	local ts
	ts=$(date -u +"%Y%m%dT%H%M%SZ")
	local case_root
	if [[ -n "$output_dir" ]]; then
		case_root="$output_dir"
		if [[ -d "$case_root" ]] && find "$case_root" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
			print_error "Output directory must be empty: $case_root"
			return 1
		fi
	else
		case_root="$DEFAULT_EXPORT_BASE/${case_slug}-${ts}"
	fi

	build_case_directories "$case_root"

	local manifest_file="$case_root/manifest.md"
	write_manifest_header "$manifest_file" "$case_name" "$source_dir" "$export_format" "$case_root"

	local total=0
	local success=0
	local failed=0

	while IFS= read -r -d '' source_file; do
		total=$((total + 1))
		local source_base
		source_base=$(basename "$source_file")
		local source_stem
		source_stem="${source_base%.*}"
		local source_ext
		source_ext="${source_base##*.}"
		local prefixed_name
		prefixed_name=$(printf '%04d-%s.%s' "$total" "$(slugify "$source_stem")" "$source_ext")

		copy_source_email "$source_file" "$case_root" "$prefixed_name"

		if export_single_message "$source_file" "$case_root" "$prefixed_name" "$export_format" "$manifest_file"; then
			success=$((success + 1))
			print_success "Exported: $source_base"
		else
			failed=$((failed + 1))
			print_warning "Failed export: $source_base"
			rm -f "$case_root/source/${prefixed_name}"
		fi
	done < <(find "$source_dir" -type f \( -name "*.eml" -o -name "*.msg" \) -print0 | sort -z)

	if [[ "$total" -eq 0 ]]; then
		print_error "No .eml or .msg files found in: $source_dir"
		return 1
	fi

	if [[ "$success" -eq 0 ]]; then
		print_error "All exports failed"
		return 1
	fi

	{
		echo "## Export Summary"
		echo
		echo "- Messages processed: ${total}"
		echo "- Messages exported: ${success}"
		echo "- Messages failed: ${failed}"
		echo "- Completed At (UTC): $(timestamp_utc)"
	} >>"$manifest_file"

	print_success "Case export complete"
	print_info "Case root: $case_root"
	print_info "Manifest: $manifest_file"
	return 0
}

cmd_archive_folders() {
	local account_name="$1"
	local case_name="$2"
	local parent_folder="${3:-Legal}"

	if [[ -z "$account_name" || -z "$case_name" ]]; then
		print_error "Usage: email-export-helper.sh archive-folders <account_name> <case_name> [parent_folder]"
		return 1
	fi

	if [[ ! -x "$MAILBOX_HELPER_SCRIPT" ]]; then
		print_error "Missing dependency: ${MAILBOX_HELPER_SCRIPT}"
		print_info "Run this command after t1493 is implemented"
		return 1
	fi

	local case_slug
	case_slug=$(slugify "$case_name")
	local root_folder="${parent_folder}/${case_slug}"

	"$MAILBOX_HELPER_SCRIPT" folders "$account_name" create "$root_folder"
	"$MAILBOX_HELPER_SCRIPT" folders "$account_name" create "${root_folder}/incoming"
	"$MAILBOX_HELPER_SCRIPT" folders "$account_name" create "${root_folder}/evidence"
	"$MAILBOX_HELPER_SCRIPT" folders "$account_name" create "${root_folder}/exported"

	print_success "Archive folders created under: $root_folder"
	return 0
}

show_help() {
	cat <<'HELP'
Email Export Helper - AI DevOps Framework

Usage: email-export-helper.sh <command> [options]

Commands:
  export <source_dir> <case_name> [format] [output_dir]
      Export .eml/.msg messages into legal-matter structure.
      format: pdf (default), text, markdown

  archive-folders <account_name> <case_name> [parent_folder]
      Create IMAP archive folders (legal case).
      Requires email-mailbox-helper.sh (t1493 dependency).

  help
      Show this help text.

Output Structure:
  case-root/
    threads/          # per-message markdown + exported output format
    attachments/      # per-message attachment directories + hash manifests
    source/           # copied source .eml/.msg files
    manifest.md       # chain-of-custody and index

Examples:
  email-export-helper.sh export ./emails "Case ACME v Example" pdf
  email-export-helper.sh export ./emails "Case ACME v Example" text ./exports/case-acme
  email-export-helper.sh archive-folders work-account "Case ACME v Example"
HELP
	return 0
}

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	export)
		local source_dir="${1:-}"
		local case_name="${2:-}"
		local export_format="${3:-pdf}"
		local output_dir="${4:-}"
		cmd_export "$source_dir" "$case_name" "$export_format" "$output_dir"
		;;
	archive-folders)
		local account_name="${1:-}"
		local case_name="${2:-}"
		local parent_folder="${3:-Legal}"
		cmd_archive_folders "$account_name" "$case_name" "$parent_folder"
		;;
	help | --help | -h)
		show_help
		;;
	*)
		print_error "${ERROR_UNKNOWN_COMMAND}: $command"
		show_help
		return 1
		;;
	esac

	return 0
}

main "$@"
