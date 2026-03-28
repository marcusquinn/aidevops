# Sequence Diagrams

Sequence diagrams show interactions between participants over time. Ideal for API flows, protocols, and service communication.

## Participants

Participants appear in order of first mention, or declare explicitly with aliases. Use `actor` for stick figures, `create`/`destroy` for dynamic lifecycle:

```mermaid
sequenceDiagram
    actor User
    participant C as Client
    participant S as Service
    participant D as Database

    User->>C: Click
    C->>S: Request
    S->>D: Query
    create participant Cache
    S->>Cache: Store
    destroy Cache
    Cache->>S: Expired
```

## Message Types

| Syntax | Description |
|--------|-------------|
| `->>` | Solid line with arrow (sync call) |
| `-->>` | Dotted line with arrow (response/async return) |
| `-x` / `--x` | Solid/dotted line with cross (failed) |
| `-)` / `--)` | Solid/dotted line with open arrow (async fire-and-forget) |
| `->` / `-->` | Solid/dotted line without arrow (rare) |

## Activation (Lifeline)

Use `+`/`-` suffixes on arrows for compact activation. Nesting supported. Equivalent explicit form: `activate`/`deactivate` on separate lines.

```mermaid
sequenceDiagram
    Client->>+Server: Request
    Server->>+Server: Validate
    Server-->>-Server: Valid
    Server->>+DB: Query
    DB-->>-Server: Data
    Server-->>-Client: Response
```

## Control Flow

Six constructs: `alt`/`else` (if/else), `opt` (optional), `loop`, `par`/`and` (parallel), `critical`/`option` (error handling), `break` (early exit).

```mermaid
sequenceDiagram
    Client->>API: POST /login
    API->>DB: Validate credentials

    alt Valid credentials
        API-->>Client: 200 OK + Token
    else Invalid credentials
        API-->>Client: 401 Unauthorized
    end

    opt Cache result
        API->>Cache: Store response
    end
```

```mermaid
sequenceDiagram
    par Fetch user data
        API->>UserService: Get user
    and Fetch orders
        API->>OrderService: Get orders
    end

    critical Establish connection
        Client->>Server: Connect
    option Network timeout
        Client->>Client: Retry
    option Server unavailable
        Client->>Client: Use fallback
    end
```

```mermaid
sequenceDiagram
    Client->>API: Request
    API->>Auth: Validate token

    break Invalid token
        Auth-->>API: Invalid
        API-->>Client: 401 Unauthorized
    end

    loop Every 30 seconds
        Client->>Server: Heartbeat
        Server-->>Client: ACK
    end
```

## Styling and Layout

**Notes:** `Note left of A`, `Note right of B`, `Note over A`, `Note over A,B` (spanning).

**Autonumbering:** Add `autonumber` after `sequenceDiagram`.

**Background highlighting** with `rect rgb(R, G, B)` and **participant boxes** with `box Color Label`:

```mermaid
sequenceDiagram
    box Blue Frontend
        participant U as User
        participant C as Client
    end
    box Green Backend
        participant A as API
        participant D as Database
    end

    rect rgb(200, 220, 255)
        Note over U,C: User interaction
        U->>C: Click
        C->>A: Request
    end

    rect rgb(220, 255, 200)
        Note over A,D: Backend processing
        A->>D: Query
        D-->>A: Data
    end

    A-->>C: Response
    C-->>U: Display
```

## Examples

### OAuth 2.0 Authorization Code Flow

```mermaid
sequenceDiagram
    autonumber
    actor User
    participant Client as Client App
    participant Auth as Auth Server
    participant API as Resource API

    User->>Client: Click Login
    Client->>Auth: Authorization request
    Auth->>User: Login page
    User->>Auth: Credentials
    Auth-->>Client: Authorization code

    Client->>+Auth: Exchange code for token
    Note right of Auth: Validate code
    Auth-->>-Client: Access + Refresh tokens

    Client->>+API: Request + Access token
    API->>API: Validate token
    API-->>-Client: Protected resource
    Client-->>User: Display data
```

### WebSocket Connection

```mermaid
sequenceDiagram
    participant C as Client
    participant S as Server

    C->>S: HTTP Upgrade request
    S-->>C: 101 Switching Protocols

    rect rgb(230, 245, 255)
        Note over C,S: WebSocket established
        loop Bidirectional messaging
            C-)S: Send message
            S-)C: Push update
        end
    end

    C->>S: Close frame
    S-->>C: Close ACK
```

### Saga Pattern (Distributed Transaction)

```mermaid
sequenceDiagram
    autonumber
    participant O as Order Service
    participant P as Payment Service
    participant I as Inventory Service
    participant S as Shipping Service

    O->>P: Reserve payment
    P-->>O: Payment reserved
    O->>I: Reserve inventory
    I-->>O: Inventory reserved
    O->>S: Schedule shipping
    S--xO: Shipping failed

    rect rgb(255, 220, 220)
        Note over O,S: Compensating transactions
        O->>I: Release inventory
        I-->>O: Released
        O->>P: Refund payment
        P-->>O: Refunded
    end
```

### gRPC Streaming

```mermaid
sequenceDiagram
    participant C as Client
    participant S as Server

    Note over C,S: Unary RPC
    C->>S: Request
    S-->>C: Response

    Note over C,S: Server streaming
    C->>S: Request
    loop Stream responses
        S-)C: Response chunk
    end

    Note over C,S: Bidirectional streaming
    par Client sends
        loop
            C-)S: Request
        end
    and Server sends
        loop
            S-)C: Response
        end
    end
```
