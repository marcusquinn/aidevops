<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Manifest Reference — Overview

`CloudronManifest.json` field reference. See the [Cloudron docs](https://docs.cloudron.io/packaging/manifest/) for examples.

## Required fields

| Field | Type | Description |
|-------|------|-------------|
| `manifestVersion` | integer | Always `2` |
| `version` | semver string | Package version (e.g. `"1.0.0"`) |
| `healthCheckPath` | URL path | Path returning 2xx when healthy (e.g. `"/"`) |
| `httpPort` | integer | HTTP port the app listens on (e.g. `8000`) |
