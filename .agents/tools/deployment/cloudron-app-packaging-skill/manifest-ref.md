<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Manifest Reference

`CloudronManifest.json` field reference. See the [Cloudron docs](https://docs.cloudron.io/packaging/manifest/) for examples.

## Chapters

| Chapter | Description |
|---------|-------------|
| [Overview](manifest-ref/01-overview.md) | Required fields: `manifestVersion`, `version`, `healthCheckPath`, `httpPort` |
| [Ports](manifest-ref/02-ports.md) | HTTP, TCP, UDP port configuration and environment variables |
| [Addons](manifest-ref/03-addons.md) | Available addons: email, LDAP, databases, OIDC, TLS, etc. |
| [Metadata](manifest-ref/04-metadata.md) | App Store fields: title, description, icon, tags, author, links |
| [Behavior](manifest-ref/05-behavior.md) | Runtime configuration: memory, domains, SSO, logging, capabilities, backup/restore |
| [Post-Install](manifest-ref/06-post-install.md) | Post-install messages and checklists |
| [Versioning](manifest-ref/07-versioning.md) | Platform version constraints: `minBoxVersion`, `maxBoxVersion`, `targetBoxVersion` |
