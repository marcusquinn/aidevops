# State & User Journey Diagrams

State diagrams model state machines and lifecycles. User journey diagrams map user experiences across tasks.

## State Diagrams

### States & Transitions

```mermaid
stateDiagram-v2
    state "Waiting for Payment" as WaitPay
    state "Processing Order" as Process

    [*] --> WaitPay
    WaitPay --> Process : payment_received
    Process --> [*]
```

Transition formats: `A --> B`, `B --> C : event`, `C --> D : event [guard]`, `D --> E : event / action`

Self-transition: `Processing --> Processing : retry`

### Composite States

```mermaid
stateDiagram-v2
    [*] --> Active

    state Active {
        [*] --> Idle
        Idle --> Working : start
        Working --> Idle : stop
    }

    Active --> Suspended : suspend
    Suspended --> Active : resume
    Active --> [*] : terminate
```

### Choice, Fork/Join, Concurrent

```mermaid
stateDiagram-v2
    state check <<choice>>
    state fork_state <<fork>>
    state join_state <<join>>

    [*] --> Validate
    Validate --> check
    check --> Success : valid
    check --> Failure : invalid

    Success --> fork_state
    fork_state --> TaskA
    fork_state --> TaskB
    TaskA --> join_state
    TaskB --> join_state
    join_state --> [*]
```

Concurrent regions (parallel execution within a state):

```mermaid
stateDiagram-v2
    state Processing {
        [*] --> Validating
        Validating --> Valid
        --
        [*] --> Calculating
        Calculating --> Calculated
    }
```

### Notes, Direction, Styling

```mermaid
stateDiagram-v2
    direction LR
    [*] --> Active
    Active --> Error
    Error --> [*]

    note right of Active : User is logged in
    note left of Error : Session expired

    classDef errorState fill:#ff0000,color:white
    class Error errorState
```

Direction options: `TB` (default), `BT`, `LR`, `RL`

### Example: Authentication Flow

```mermaid
stateDiagram-v2
    [*] --> Unauthenticated

    state Unauthenticated {
        [*] --> LoginForm
        LoginForm --> Validating : submit
        Validating --> LoginForm : invalid_credentials
    }

    Unauthenticated --> MFA : credentials_valid

    state MFA {
        [*] --> AwaitingCode
        AwaitingCode --> VerifyingCode : submit_code
        VerifyingCode --> AwaitingCode : code_invalid
    }

    MFA --> Authenticated : mfa_verified

    state Authenticated {
        [*] --> Active
        Active --> SessionWarning : approaching_timeout
        SessionWarning --> Active : user_activity
    }

    Authenticated --> Unauthenticated : logout
    Authenticated --> Unauthenticated : session_expired
```

---

## User Journey Diagrams

### Basic Syntax

```mermaid
journey
    title My Working Day
    section Morning
        Wake up: 5: Me
        Shower: 3: Me
        Breakfast: 4: Me, Family
    section Work
        Commute: 2: Me
        Meetings: 3: Me, Team
        Coding: 5: Me
    section Evening
        Dinner: 4: Me, Family
        Relax: 5: Me
```

Task format: `Task name: score: actor1, actor2, ...` — Score 1–5 (1 = negative, 5 = positive).

### Example: SaaS Onboarding

```mermaid
journey
    title SaaS Product Onboarding
    section Awareness
        See ad: 4: Prospect
        Visit website: 4: Prospect
        Read features: 3: Prospect
    section Signup
        Click signup: 5: Prospect
        Fill form: 2: Prospect
        Verify email: 3: User
    section First Use
        Complete tutorial: 4: User
        Create first project: 5: User
        Invite team member: 3: User
    section Conversion
        Hit free tier limit: 2: User
        View pricing: 3: User
        Enter payment: 2: User
        Upgrade complete: 5: Customer
```

### Use Cases & Tips

**When to use:** UX research, identifying pain points, stakeholder communication, service design.

**Tips:** Keep scores realistic (not all 5s). Include multiple actors. Focus on emotional experience. Low-score points are improvement opportunities.
