# State & User Journey Diagrams

State diagrams model state machines and lifecycles. User journey diagrams map user experiences across tasks.

---

# State Diagrams

## Basic Syntax

```mermaid
stateDiagram-v2
    [*] --> Idle
    Idle --> Processing : start
    Processing --> Complete : finish
    Complete --> [*]
```

---

## States

### Simple States

```mermaid
stateDiagram-v2
    [*] --> Draft
    Draft --> Review
    Review --> Published
    Published --> [*]
```

### State with Description

```mermaid
stateDiagram-v2
    state "Waiting for Payment" as WaitPay
    state "Processing Order" as Process

    [*] --> WaitPay
    WaitPay --> Process : payment_received
    Process --> [*]
```

---

## Transitions

### Basic Transitions

```mermaid
stateDiagram-v2
    A --> B
    B --> C : event
    C --> D : event [guard]
    D --> E : event / action
```

### Self-Transitions

```mermaid
stateDiagram-v2
    Processing --> Processing : retry
```

---

## Composite States

Nested states for complex behaviors:

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

### Deeply Nested

```mermaid
stateDiagram-v2
    [*] --> First

    state First {
        [*] --> Second

        state Second {
            [*] --> Third
            Third --> Third : loop
        }
    }
```

---

## Choice (Decision Points)

```mermaid
stateDiagram-v2
    state check <<choice>>

    [*] --> Validate
    Validate --> check
    check --> Success : valid
    check --> Failure : invalid
    Success --> [*]
    Failure --> [*]
```

---

## Fork and Join (Parallel States)

```mermaid
stateDiagram-v2
    state fork_state <<fork>>
    state join_state <<join>>

    [*] --> fork_state
    fork_state --> TaskA
    fork_state --> TaskB
    fork_state --> TaskC
    TaskA --> join_state
    TaskB --> join_state
    TaskC --> join_state
    join_state --> Complete
    Complete --> [*]
```

---

## Concurrent States

States that execute in parallel:

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

---

## Notes

```mermaid
stateDiagram-v2
    [*] --> Active
    Active --> Inactive

    note right of Active
        User is currently logged in
        and has an active session
    end note

    note left of Inactive : Session expired
```

---

## Direction

Control layout direction:

```mermaid
stateDiagram-v2
    direction LR
    [*] --> A
    A --> B
    B --> C
    C --> [*]
```

Options: `TB`, `BT`, `LR`, `RL`

---

## Styling

```mermaid
stateDiagram-v2
    [*] --> Active
    Active --> Error
    Error --> [*]

    classDef errorState fill:#ff0000,color:white
    class Error errorState
```

---

## Example: Order Lifecycle

```mermaid
stateDiagram-v2
    [*] --> Draft

    Draft --> PendingPayment : checkout
    PendingPayment --> PaymentFailed : payment_failed
    PendingPayment --> Confirmed : payment_success
    PaymentFailed --> Draft : retry
    PaymentFailed --> Cancelled : abandon

    Confirmed --> Processing : start_fulfillment

    state Processing {
        [*] --> Picking
        Picking --> Packing : items_picked
        Packing --> ReadyToShip : packed
    }

    Processing --> Shipped : ship
    Shipped --> Delivered : delivery_confirmed
    Delivered --> [*]

    Draft --> Cancelled : cancel
    PendingPayment --> Cancelled : cancel
    Confirmed --> Cancelled : cancel
    Cancelled --> [*]
```

---

## Example: Connection State Machine

```mermaid
stateDiagram-v2
    [*] --> Disconnected

    Disconnected --> Connecting : connect()
    Connecting --> Connected : connection_established
    Connecting --> Disconnected : connection_failed

    state Connected {
        [*] --> Idle
        Idle --> Sending : send()
        Sending --> Idle : send_complete
        Idle --> Receiving : data_received
        Receiving --> Idle : receive_complete
    }

    Connected --> Reconnecting : connection_lost
    Reconnecting --> Connected : reconnected
    Reconnecting --> Disconnected : max_retries_exceeded

    Connected --> Disconnecting : disconnect()
    Disconnecting --> Disconnected : disconnected
```

---

## Example: Authentication Flow

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

# User Journey Diagrams

## Basic Syntax

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

---

## Structure

### Title

```mermaid
journey
    title User Onboarding Experience
```

### Sections

Group related tasks:

```mermaid
journey
    title E-commerce Checkout
    section Discovery
        Browse products: 5: Customer
    section Selection
        Add to cart: 4: Customer
    section Checkout
        Enter payment: 3: Customer
    section Completion
        Receive confirmation: 5: Customer
```

### Tasks

Format: `Task name: score: actor1, actor2, ...`

- **Score**: 1-5 (1 = negative, 5 = positive)
- **Actors**: Participants involved

---

## Example: SaaS Onboarding

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

---

## Example: Support Ticket Journey

```mermaid
journey
    title Customer Support Experience
    section Issue Discovery
        Encounter problem: 1: Customer
        Search help docs: 3: Customer
        Cannot find solution: 2: Customer
    section Contact Support
        Find contact form: 3: Customer
        Describe issue: 4: Customer
        Submit ticket: 4: Customer
    section Resolution
        Receive acknowledgment: 4: Customer, Support
        First response: 5: Customer, Support
        Follow-up questions: 3: Customer, Support
        Issue resolved: 5: Customer, Support
    section Post-Resolution
        Receive survey: 3: Customer
        Leave feedback: 4: Customer
```

---

## Example: Mobile App First Launch

```mermaid
journey
    title Mobile App First Launch Experience
    section Download
        Discover app: 4: User
        Read reviews: 4: User
        Download app: 5: User
    section Onboarding
        Open app: 5: User
        View splash screen: 3: User
        Skip/watch intro: 4: User
        Grant permissions: 2: User
    section Account Setup
        Choose signup method: 4: User
        Complete profile: 3: User
        Set preferences: 4: User
    section First Session
        View main screen: 5: User
        Complete first action: 5: User
        Receive achievement: 5: User
    section Retention
        Receive push notification: 3: User
        Return next day: 4: User
```

---

## Use Cases

### When to Use User Journey

1. **UX Research** - Map current user experience
2. **Identify Pain Points** - Find low-score areas
3. **Design Improvements** - Plan better experiences
4. **Stakeholder Communication** - Visualize user perspective
5. **Service Design** - Map multi-touchpoint experiences

### Tips

- Keep scores realistic (not all 5s)
- Include multiple actors when relevant
- Use sections to group related activities
- Focus on emotional experience, not just tasks
- Identify opportunities at low-score points
