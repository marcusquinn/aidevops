# Design System: Startup Minimal — Agent Prompt Guide

## Quick Colour Reference

| CSS Variable | Hex | Role |
|-------------|-----|------|
| `--color-primary` | `#2563eb` | Blue — the only accent |
| `--color-primary-hover` | `#1d4ed8` | Primary hover |
| `--color-primary-light` | `#dbeafe` | Selection, badges |
| `--color-bg` | `#fafafa` | Page background |
| `--color-surface` | `#ffffff` | Cards, inputs |
| `--color-surface-alt` | `#f4f4f5` | Alt rows, code blocks |
| `--color-text` | `#18181b` | Primary text |
| `--color-text-secondary` | `#71717a` | Secondary text |
| `--color-text-tertiary` | `#a1a1aa` | Placeholders |
| `--color-border` | `#e5e7eb` | All borders |
| `--color-border-strong` | `#d4d4d8` | Emphasised borders |
| `--color-success` | `#16a34a` | Success |
| `--color-warning` | `#ca8a04` | Warning |
| `--color-error` | `#dc2626` | Error |
| `--font-sans` | `'Inter', system-ui, sans-serif` | All text |
| `--font-mono` | `'Geist Mono', 'JetBrains Mono', monospace` | Code |
| `--radius-default` | `6px` | Standard radius |
| `--radius-card` | `8px` | Card radius |

## Ready-to-Use Prompts

**Prompt 1 — Dashboard layout:**
> Build a dashboard on #fafafa background. Left sidebar: #ffffff, 240px width, 1px #e5e7eb right border. Sidebar nav items: 14px Inter 500 #71717a, active item #18181b on #f4f4f5 background with 6px radius. Main content area: 24px padding. Stats row: 4 cards in a grid, #ffffff with 1px #e5e7eb border and 8px radius, 24px padding. Stat value: 28px/600 #18181b. Label: 13px/400 #71717a.

**Prompt 2 — Settings form:**
> Create a settings page. Max-width 680px, centred. Section title: 22px Inter 600 #18181b. Description: 15px #71717a. Form groups: 24px gap. Labels: 13px/500 #18181b above inputs. Inputs: #ffffff, 1px #e5e7eb border, 6px radius, 14px Inter, 8px 12px padding. Focus: #2563eb border with 0 0 0 3px rgba(37,99,235,0.1). Submit: #2563eb primary button right-aligned. Dividers: 1px #e5e7eb between sections.

**Prompt 3 — Data table:**
> Build a data table on #ffffff surface with 1px #e5e7eb border and 8px radius. Header row: #f4f4f5 background, 13px Inter 500 #71717a. Body rows: 14px Inter 400 #18181b, 1px #e5e7eb border-bottom. Row hover: #fafafa background. Selected row: #dbeafe background. Actions column: ghost button icons in #71717a, hover #18181b. Pagination: 13px, bottom-right, small secondary buttons.

**Prompt 4 — Empty state:**
> Design an empty state centred in a #ffffff card with 8px radius and 1px #e5e7eb border. Grey illustration placeholder (64px icon in #a1a1aa). Title: 18px/600 #18181b. Description: 15px/400 #71717a, max 400px. Primary CTA: #2563eb button below. 48px vertical padding.
