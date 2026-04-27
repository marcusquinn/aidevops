# Markdoc Tag Namespace — AI DevOps Knowledge Plane

This directory defines the 7 Markdoc tag schemas used by the knowledge plane
(t2874). The validator (`markdoc-validate.sh`), extractor (Phase 3), and
migration tooling (Phase 4) all parse against these schemas as the single source
of truth.

## Namespace Convention

Tags follow the [Markdoc tag grammar](https://markdoc.dev/docs/tags):

- **Block tag** (opens/closes around content):
  ```
  {% tag_name attr="value" %}
  content
  {% /tag_name %}
  ```
- **Self-closing tag** (no body content):
  ```
  {% tag_name attr="value" /%}
  ```

Attribute values: strings use `"double quotes"`, numbers are bare (`confidence=0.95`).
Attribute names with hyphens are valid (`source-id`, `case-id`, `redacted-by`).

## Tag Index

| Tag | Scope | Description |
|-----|-------|-------------|
| `sensitivity` | file / section / inline | Data classification tier (public → redacted) |
| `provenance` | file / section | Source document origin and extraction metadata |
| `case-attach` | section / inline | Links content to a legal or business case record |
| `citation` | inline | Inline source citation with optional page + confidence |
| `redaction` | section / inline | Marks content for redaction in output renders |
| `draft-status` | file / section | Editorial lifecycle status (draft → archived) |
| `link` | inline | Typed link to an external or internal resource |

## Schema Structure

Each `.json` file contains:

```jsonc
{
  "name": "<tag-name>",
  "description": "...",
  "attributes": {
    "<attr-name>": {
      "type": "string|number",
      "required": true|false,
      "enum": ["val1", "val2"],   // present when value is constrained
      "description": "..."
    }
  },
  "scope_rules": {
    "allowed": ["file", "section", "inline"],
    "description": "..."
  },
  "example": "..."
}
```

## Scope Definitions

- **file** — tag wraps the entire document (appears at the top level before any headings, or spans the full file)
- **section** — tag wraps a heading block (between two headings, or from a heading to end of file)
- **inline** — tag annotates a phrase or value within a paragraph
