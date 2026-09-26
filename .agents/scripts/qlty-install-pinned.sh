#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Install the reviewed Linux runner binary rather than the install action's moving latest.
set -euo pipefail

version='0.643.0'
digest='40500d150001b8389f2eb5dd089d07a9da70292a7c0bca3bdf72fb6c16fa20e5'
asset='qlty-x86_64-unknown-linux-gnu.tar.xz'
url="https://github.com/qltysh/qlty/releases/download/v${version}/${asset}"

[[ "${QLTY_VERSION:-$version}" == "$version" && "${QLTY_CLI_VERSION:-$version}" == "$version" ]] || {
	printf 'Qlty workflow version disagrees with pinned release\n' >&2
	exit 1
}
[[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] || {
	printf 'Pinned Qlty installer supports Linux x86_64 runners only\n' >&2
	exit 1
}
[[ -n "${RUNNER_TEMP:-}" && -n "${GITHUB_PATH:-}" ]] || {
	printf 'Pinned Qlty installer requires GitHub Actions runner paths\n' >&2
	exit 1
}
download_dir=$(mktemp -d "${RUNNER_TEMP}/qlty-download.XXXXXXXX")
trap 'rm -rf "$download_dir"' EXIT
curl --fail --location --silent --show-error --retry 2 --connect-timeout 10 --max-time 120 \
	"$url" --output "${download_dir}/${asset}"
printf '%s  %s\n' "$digest" "${download_dir}/${asset}" | sha256sum --check --status || {
	printf 'Qlty release digest mismatch\n' >&2
	exit 1
}
install_dir="${RUNNER_TEMP}/qlty-${version}/bin"
mkdir -p "$install_dir"
tar -xJf "${download_dir}/${asset}" -C "$install_dir" --strip-components=1 \
	'qlty-x86_64-unknown-linux-gnu/qlty'
[[ "$("${install_dir}/qlty" version)" == "qlty ${version} "* ]] || {
	printf 'Qlty release version mismatch\n' >&2
	exit 1
}
printf '%s\n' "$install_dir" >>"$GITHUB_PATH"
printf 'Installed pinned Qlty %s\n' "$version"
