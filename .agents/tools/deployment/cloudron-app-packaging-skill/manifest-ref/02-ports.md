<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Manifest Reference — Ports

## Ports

| Field | Type | Description |
|-------|------|-------------|
| `httpPort` | integer | Primary HTTP port |
| `httpPorts` | object | Additional HTTP services on secondary domains. Keys: env var names. Values: `{ title, description, containerPort, defaultValue }` |
| `tcpPorts` | object | Non-HTTP TCP ports. Keys: env var names. Values: `{ title, description, defaultValue, containerPort, portCount, readOnly, enabledByDefault }` |
| `udpPorts` | object | UDP ports. Same structure as `tcpPorts` |

`containerPort`: port inside the container. `defaultValue`: suggested external port shown at install. Disabled ports remove their env var — apps must handle absence.
