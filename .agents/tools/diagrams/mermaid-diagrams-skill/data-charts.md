# Data Charts & Timelines

## Gantt Charts

```mermaid
gantt
    title Project Timeline
    dateFormat YYYY-MM-DD
    axisFormat %b %d
    excludes weekends

    section Phase 1
    Completed task    :done, t1, 2024-01-01, 7d
    Active task       :active, t2, after t1, 7d
    Critical task     :crit, t3, after t2, 5d
    Future task       :t4, after t3, 7d
    Milestone         :milestone, m1, after t4, 0d
```

### Task Syntax

```text
Task name : [tags], [id], [start], [end/duration]
```

Tags: `done` (completed/grayed), `active` (in progress), `crit` (critical path/red), `milestone` (marker).

Dependencies: `after a b` waits for both `a` and `b`. Excludes: `weekends`, specific dates (`2024-12-25`), or weekday names.

Date formats: `YYYY-MM-DD`, `DD/MM/YYYY`, `MM-DD-YYYY`. Axis codes: `%Y` year, `%m` month, `%b` month abbr, `%d` day, `%a` weekday abbr.

## Pie Charts

```mermaid
pie showData
    title Q1 Budget Allocation
    "Engineering" : 45
    "Marketing" : 20
    "Sales" : 15
    "Operations" : 12
    "R&D" : 8
```

`showData` displays values alongside the chart. Omit for labels-only.

## Timeline Diagrams

```mermaid
timeline
    title Product Roadmap
    section Q1
        January : MVP Release : Core Features Complete
        March : Public Beta
    section Q2
        April : Mobile App Beta
        June : Enterprise Features
```

Multiple events per period: add `: Event` entries on the same date line.

## Quadrant Charts

```mermaid
quadrantChart
    title Technology Evaluation
    x-axis Low Risk --> High Risk
    y-axis Low Value --> High Value
    quadrant-1 Adopt Now
    quadrant-2 Evaluate Carefully
    quadrant-3 Avoid
    quadrant-4 Reassess
    Kubernetes: [0.3, 0.9]
    Serverless: [0.4, 0.8]
    GraphQL: [0.5, 0.7]
    Blockchain: [0.9, 0.4]
    AI/ML: [0.6, 0.85]
```

Coordinates: `[x, y]` from 0-1. Quadrants: 1=upper-right, 2=upper-left, 3=lower-left, 4=lower-right.

## XY Charts

```mermaid
xychart-beta
    title "Revenue vs Costs"
    x-axis [Jan, Feb, Mar, Apr, May, Jun]
    y-axis "Amount ($K)" 0 --> 150
    bar "Revenue" [80, 95, 105, 120, 135, 150]
    line "Costs" [60, 65, 70, 75, 80, 85]
```

Use `bar` for bar charts, `line` for line charts, or combine both.

## Sankey Diagrams

```mermaid
sankey-beta

Revenue, Engineering, 450
Revenue, Marketing, 200
Revenue, Sales, 150

Engineering, Salaries, 350
Engineering, Tools, 50
Engineering, Cloud, 50
```

Format: `Source, Destination, Value` (one per line). Multi-level flows chain source nodes.

## Treemap Diagrams

```mermaid
treemap-beta

"src"
    "components": 45
    "pages": 30
    "utils": 15
"tests"
    "unit": 20
    "integration": 15
```

## Mindmaps

```mermaid
mindmap
    root((System Design))
        Frontend
            React
            Vue
        Backend
            Node.js
            PostgreSQL
        Infrastructure
            Docker
            Kubernetes
```

Node shapes: `((Circle))`, `[Square]`, `(Rounded)`, `))Bang((`, `)Cloud(`, `{{Hexagon}}`. Hierarchy via indentation.

## Git Graphs

```mermaid
gitGraph
    commit id: "v1.0.0" tag: "v1.0.0"
    branch feature/auth
    commit id: "Add login"
    commit id: "Add logout"
    checkout main
    merge feature/auth id: "Merge auth"
    commit id: "v1.1.0" tag: "v1.1.0"
```

Commit types: `commit` (normal), `commit type: HIGHLIGHT`, `commit type: REVERSE`.
