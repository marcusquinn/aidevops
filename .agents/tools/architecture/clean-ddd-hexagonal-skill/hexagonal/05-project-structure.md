<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Project Structure

```
src/
├── application/
│   ├── ports/
│   │   ├── driver/          # place_order_port.ts, get_order_port.ts, cancel_order_port.ts
│   │   └── driven/          # order_repository_port.ts, event_publisher_port.ts, payment_gateway_port.ts
│   └── use_cases/
│       ├── place_order/handler.ts   # implements driver port
│       └── get_order/handler.ts
├── infrastructure/adapters/
│   ├── driver/              # rest/, grpc/, cli/
│   └── driven/              # postgres/, rabbitmq/, stripe/, in_memory/
└── domain/
```
