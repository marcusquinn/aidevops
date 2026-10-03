<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Docker MCP Gateway

Connect the scoped `MCP_DOCKER` gateway only when the operator requests Docker tooling. Inspect its dynamic tool inventory before each operation and use only tools necessary for the task. Do not start or remove containers, alter volumes, or change Docker state without the applicable authorization. The `docker` binary must already be available. Disconnect after use.
