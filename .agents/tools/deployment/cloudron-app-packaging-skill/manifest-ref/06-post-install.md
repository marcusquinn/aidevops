<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Manifest Reference — Post-Install

## Post-install

| Field | Type | Description |
|-------|------|-------------|
| `postInstallMessage` | markdown string | Shown after install. Supports `file://POSTINSTALL.md`. Tags: `<sso>`, `<nosso>`. Variables: `$CLOUDRON-APP-DOMAIN`, `$CLOUDRON-APP-FQDN`, `$CLOUDRON-APP-ORIGIN`, `$CLOUDRON-USERNAME`, `$CLOUDRON-APP-ID` |
| `checklist` | object | Post-install todo items. Keys: item IDs. Values: `{ message, sso }`. `sso: true` = auth only, `sso: false` = no-auth only |
