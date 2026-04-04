---
description: i18next internationalization - translations, locales, namespaces
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
  context7_*: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# i18next - Internationalization

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Multi-language support for React/Next.js applications
- **Libraries**: `i18next`, `react-i18next`, `next-i18n-router`
- **Docs**: Use Context7 MCP for current documentation

**Common Hazards** (from real sessions):

| Hazard | Problem | Solution |
|--------|---------|----------|
| Missing translation in some locales | Added key to `en` but forgot `de`, `es`, `fr` | Always update ALL locale files together |
| Nested key path wrong | `t("ai.sidebar.title")` returns key | Check JSON structure matches dot notation |
| Namespace not loaded | Translation returns key | Ensure namespace is loaded in component |
| Type safety | No autocomplete for keys | Use typed `useTranslation` hook |
| Missing `"use client"` | `useTranslation` hook fails in server component | Use `getTranslation` for server components |

**File Structure**:

```text
packages/i18n/src/translations/
├── en/
│   ├── common.json      # Shared UI strings
│   ├── marketing.json   # Marketing pages
│   └── dashboard.json   # Dashboard-specific
├── de/
│   └── common.json
├── es/
│   └── common.json
└── fr/
    └── common.json
```

<!-- AI-CONTEXT-END -->

## Adding Translation Keys

Always update ALL locales when adding a key. Find the insertion point, then add to every locale file:

```bash
# Find insertion point across all locales
grep -n '"feedback"' packages/i18n/src/translations/*/common.json
# de/common.json:44:  "feedback": "Feedback",
# en/common.json:44:  "feedback": "Feedback",
# es/common.json:44:  "feedback": "Comentarios",
# fr/common.json:44:  "feedback": "Commentaires",
```

```json
// en/common.json
"feedback": "Feedback",
"social": "Social",

// de/common.json
"feedback": "Feedback",
"social": "Soziale Medien",

// es/common.json
"feedback": "Comentarios",
"social": "Redes sociales",

// fr/common.json
"feedback": "Commentaires",
"social": "Réseaux sociaux"
```

## Usage Patterns

### Client Components

```tsx
import { useTranslation } from "@workspace/i18n";

function Component() {
  const { t } = useTranslation("common");

  return (
    <div>
      <h1>{t("ai.sidebar.title")}</h1>
      <p>{t("ai.sidebar.subtitle")}</p>
      <button aria-label={t("ai.sidebar.open")}>Open</button>
    </div>
  );
}
```

### Nested Keys and JSON Structure

```json
{
  "ai": {
    "sidebar": {
      "title": "Awards AI",
      "subtitle": "Your awards assistant",
      "open": "Open AI assistant",
      "close": "Close AI assistant",
      "placeholder": "Ask me anything...",
      "prompts": {
        "search": "Find relevant awards",
        "help": "Writing tips"
      },
      "welcome": {
        "title": "How can I help?",
        "description": "Ask me about finding awards..."
      }
    }
  }
}
```

Access with dot notation: `t("ai.sidebar.welcome.title")`

### Interpolation and Plurals

```json
{
  "greeting": "Hello, {{name}}!",
  "items": "You have {{count}} item",
  "items_plural": "You have {{count}} items"
}
```

```tsx
t("greeting", { name: "Marcus" })  // "Hello, Marcus!"
t("items", { count: 1 })           // "You have 1 item"
t("items", { count: 5 })           // "You have 5 items"
```

### Multiple Namespaces

```tsx
const { t } = useTranslation(["common", "dashboard"]);
t("common:save")
t("dashboard:stats.title")
```

### Server Components (Next.js App Router)

```tsx
import { getTranslation } from "@workspace/i18n/server";

// Next.js 15+: params is a Promise
export default async function Page({
  params
}: {
  params: { locale: string }
}) {
  const { locale } = params;
  const { t } = await getTranslation(locale, "common");
  return <h1>{t("title")}</h1>;
}

// Next.js 14 and earlier: params is not a Promise
// export default async function Page({ params }: { params: { locale: string } }) {
//   const { t } = await getTranslation(params.locale, "common");
//   return <h1>{t("title")}</h1>;
// }
```

### Type-Safe Translations

```tsx
type TranslationKeys =
  | "ai.sidebar.title"
  | "ai.sidebar.subtitle"
  | "ai.sidebar.open"
  | "ai.sidebar.close";

const { t } = useTranslation<TranslationKeys>("common");
t("ai.sidebar.title"); // Autocomplete works!
```

## Validation Script

```bash
#!/usr/bin/env bash
set -euo pipefail
# Check for missing translation keys across locales. Run from repo root.
command -v jq >/dev/null 2>&1 || { echo "Error: jq is required" >&2; exit 1; }

BASE_LOCALE="en"
TARGET_LOCALES=("de" "es" "fr")
NAMESPACE="common"

cd packages/i18n/src/translations

if [[ ! -f "${BASE_LOCALE}/${NAMESPACE}.json" ]]; then
  echo "Error: Base locale file ${BASE_LOCALE}/${NAMESPACE}.json not found" >&2
  exit 1
fi

for locale in "${TARGET_LOCALES[@]}"; do
  if [[ ! -f "${locale}/${NAMESPACE}.json" ]]; then
    echo "Warning: ${locale}/${NAMESPACE}.json not found, skipping" >&2
    continue
  fi
  echo "=== Missing in ${locale} ==="
  diff <(jq -r 'paths | join(".")' "${BASE_LOCALE}/${NAMESPACE}.json" | sort) \
       <(jq -r 'paths | join(".")' "${locale}/${NAMESPACE}.json" | sort) \
       | grep "^<" | sed 's/^< //' || true
done
```

## Related

- `tools/ui/nextjs-layouts.md` - Locale routing in Next.js
- Context7 MCP for i18next documentation
