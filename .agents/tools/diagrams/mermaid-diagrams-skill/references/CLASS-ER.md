# Class & Entity Relationship Diagrams

Class diagrams model object-oriented structures. ER diagrams model database schemas and data relationships.

---

# Class Diagrams

## Basic Syntax

```mermaid
classDiagram
    class Animal {
        +String name
        +int age
        +makeSound()
    }
```

---

## Class Definition

### Attributes and Methods

```mermaid
classDiagram
    class User {
        +String id
        +String email
        -String passwordHash
        +login() bool
        +logout() void
        #validatePassword(pwd) bool
        -hashPassword(pwd) String
    }
```

### Visibility Modifiers

| Symbol | Visibility |
|--------|------------|
| `+` | Public |
| `-` | Private |
| `#` | Protected |
| `~` | Package/Internal |

### Return Types

```mermaid
classDiagram
    class Repository {
        +findById(id) Entity
        +findAll() List~Entity~
        +save(entity) void
        +delete(id) bool
    }
```

---

## Relationships

### Relationship Types

| Syntax | Relationship |
|--------|--------------|
| `<\|--` | Inheritance (extends) |
| `*--` | Composition (owns) |
| `o--` | Aggregation (has) |
| `-->` | Association |
| `..>` | Dependency |
| `..\|>` | Realization (implements) |
| `--` | Link (solid) |
| `..` | Link (dashed) |

```mermaid
classDiagram
    Animal <|-- Dog : extends
    Animal <|-- Cat : extends
    Dog *-- Leg : composition
    Dog o-- Collar : aggregation
    Dog --> Food : association
    Dog ..> Vet : dependency
```

### Cardinality

```mermaid
classDiagram
    Customer "1" --> "*" Order : places
    Order "1" --> "1..*" LineItem : contains
    Order "0..1" --> "1" ShippingAddress : ships to
```

| Notation | Meaning |
|----------|---------|
| `1` | Exactly one |
| `0..1` | Zero or one |
| `1..*` | One or more |
| `*` | Many (zero or more) |
| `n` | Specific number |
| `0..n` | Zero to n |

---

## Annotations

```mermaid
classDiagram
    class IRepository {
        <<interface>>
        +find(id)
        +save(entity)
    }

    class OrderStatus {
        <<enumeration>>
        PENDING
        CONFIRMED
        SHIPPED
        DELIVERED
    }

    class UserService {
        <<service>>
        +createUser()
    }

    class BaseEntity {
        <<abstract>>
        +id
    }
```

---

## Generic Types

```mermaid
classDiagram
    class Repository~T~ {
        +find(id) T
        +findAll() List~T~
        +save(entity: T) void
    }

    class UserRepository {
        +findByEmail(email) User
    }

    Repository~User~ <|-- UserRepository
```

---

## Namespaces

```mermaid
classDiagram
    namespace Domain {
        class User
        class Order
        class Product
    }

    namespace Infrastructure {
        class UserRepository
        class OrderRepository
    }

    User "1" --> "*" Order
    UserRepository ..|> IUserRepository
```

---

## Notes

```mermaid
classDiagram
    class Order
    note for Order "Aggregate root for order management"

    class OrderItem
    note for OrderItem "Value object - immutable"
```

---

## Styling

```mermaid
classDiagram
    class Important
    class Normal

    style Important fill:#f9f,stroke:#333,stroke-width:4px
```

---

## Example: Domain Model

```mermaid
classDiagram
    class Order {
        +OrderId id
        +CustomerId customerId
        +OrderStatus status
        +Money total
        +addItem(product, quantity)
        +removeItem(itemId)
        +submit()
        +cancel()
    }

    class OrderItem {
        +OrderItemId id
        +ProductId productId
        +Quantity quantity
        +Money unitPrice
        +getSubtotal() Money
    }

    class Customer {
        +CustomerId id
        +Email email
        +Name name
        +getOrders() Order[]
    }

    class OrderStatus {
        <<enumeration>>
        DRAFT
        SUBMITTED
        CONFIRMED
        SHIPPED
        DELIVERED
        CANCELLED
    }

    class Money {
        <<value object>>
        +Decimal amount
        +String currency
        +add(other) Money
        +subtract(other) Money
    }

    Customer "1" --> "*" Order : places
    Order "1" *-- "1..*" OrderItem : contains
    Order --> OrderStatus
    Order --> Money : total
    OrderItem --> Money : unitPrice
```

---

# Entity Relationship Diagrams

## Basic Syntax

```mermaid
erDiagram
    CUSTOMER ||--o{ ORDER : places
    ORDER ||--|{ LINE_ITEM : contains
```

---

## Relationship Notation (Crow's Foot)

### Cardinality Symbols

| Left | Right | Meaning |
|------|-------|---------|
| `\|o` | `o\|` | Zero or one |
| `\|\|` | `\|\|` | Exactly one |
| `}o` | `o{` | Zero or more |
| `}\|` | `\|{` | One or more |

### Line Types

| Type | Syntax | Meaning |
|------|--------|---------|
| Identifying | `--` | Strong relationship |
| Non-identifying | `..` | Weak relationship |

### Common Patterns

```mermaid
erDiagram
    A ||--|| B : "one to one"
    C ||--o{ D : "one to many"
    E }o--o{ F : "many to many (optional)"
    G }|--|{ H : "many to many (required)"
```

---

## Entity Attributes

### Basic Attributes

```mermaid
erDiagram
    USER {
        uuid id
        string email
        string name
        timestamp created_at
    }
```

### Attribute Modifiers

| Modifier | Meaning |
|----------|---------|
| `PK` | Primary Key |
| `FK` | Foreign Key |
| `UK` | Unique Key |

```mermaid
erDiagram
    USER {
        uuid id PK
        string email UK
        string name
        timestamp created_at
    }

    ORDER {
        uuid id PK
        uuid user_id FK
        decimal total
        string status
    }

    USER ||--o{ ORDER : places
```

### Attribute Comments

```mermaid
erDiagram
    USER {
        uuid id PK "Primary identifier"
        string email UK "Must be unique"
        string password_hash "BCrypt hashed"
        timestamp created_at "Auto-generated"
    }
```

---

## Relationship Labels

```mermaid
erDiagram
    CUSTOMER ||--o{ ORDER : "places"
    ORDER ||--|{ LINE_ITEM : "contains"
    PRODUCT ||--o{ LINE_ITEM : "appears in"
    EMPLOYEE ||--o{ ORDER : "processes"
```

---

## Example: E-Commerce Schema

```mermaid
erDiagram
    USER ||--o{ ORDER : places
    USER ||--o{ ADDRESS : has
    USER ||--o{ CART : has
    ORDER ||--|{ ORDER_ITEM : contains
    ORDER ||--o| SHIPPING : "shipped via"
    ORDER }o--|| ADDRESS : "ships to"
    PRODUCT ||--o{ ORDER_ITEM : "ordered as"
    PRODUCT ||--o{ CART_ITEM : "added to"
    PRODUCT }o--|| CATEGORY : "belongs to"
    CART ||--|{ CART_ITEM : contains

    USER {
        uuid id PK
        string email UK
        string password_hash
        string name
        boolean is_active
        timestamp created_at
        timestamp updated_at
    }

    ADDRESS {
        uuid id PK
        uuid user_id FK
        string street
        string city
        string state
        string postal_code
        string country
        boolean is_default
    }

    PRODUCT {
        uuid id PK
        uuid category_id FK
        string sku UK
        string name
        text description
        decimal price
        integer stock_quantity
        boolean is_active
    }

    CATEGORY {
        uuid id PK
        uuid parent_id FK
        string name
        string slug UK
    }

    ORDER {
        uuid id PK
        uuid user_id FK
        uuid shipping_address_id FK
        string status
        decimal subtotal
        decimal tax
        decimal shipping_cost
        decimal total
        timestamp created_at
    }

    ORDER_ITEM {
        uuid id PK
        uuid order_id FK
        uuid product_id FK
        integer quantity
        decimal unit_price
        decimal subtotal
    }

    CART {
        uuid id PK
        uuid user_id FK UK
        timestamp updated_at
    }

    CART_ITEM {
        uuid id PK
        uuid cart_id FK
        uuid product_id FK
        integer quantity
    }

    SHIPPING {
        uuid id PK
        uuid order_id FK UK
        string carrier
        string tracking_number
        string status
        timestamp shipped_at
        timestamp delivered_at
    }
```

---

## Example: Multi-Tenant SaaS

```mermaid
erDiagram
    ORGANIZATION ||--|{ TEAM : has
    ORGANIZATION ||--|{ USER_ORG : members
    USER ||--|{ USER_ORG : "belongs to"
    TEAM ||--|{ TEAM_MEMBER : members
    USER ||--|{ TEAM_MEMBER : "member of"
    ORGANIZATION ||--|{ PROJECT : owns
    PROJECT ||--|{ TASK : contains
    USER ||--o{ TASK : "assigned to"

    ORGANIZATION {
        uuid id PK
        string name
        string slug UK
        string plan
        timestamp created_at
    }

    USER {
        uuid id PK
        string email UK
        string name
        timestamp created_at
    }

    USER_ORG {
        uuid id PK
        uuid user_id FK
        uuid org_id FK
        string role
    }

    TEAM {
        uuid id PK
        uuid org_id FK
        string name
    }

    TEAM_MEMBER {
        uuid id PK
        uuid team_id FK
        uuid user_id FK
        string role
    }

    PROJECT {
        uuid id PK
        uuid org_id FK
        string name
        string status
    }

    TASK {
        uuid id PK
        uuid project_id FK
        uuid assignee_id FK
        string title
        string status
        timestamp due_date
    }
```
