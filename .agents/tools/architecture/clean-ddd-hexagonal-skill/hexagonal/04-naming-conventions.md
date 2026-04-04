<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Naming Conventions

| Pattern | Port | Adapter |
|---------|------|---------|
| **Cockburn** (recommended) | `ForPlacingOrders` | `CliCommandForPlacingOrders` |
| Interface/Impl | `IOrderRepository` | `PostgresOrderRepository` |
| Port suffix | `OrderRepositoryPort` | `PostgresOrderAdapter` |
| Using prefix | `IOrderStorage` | `OrderStorageUsingPostgres` |
