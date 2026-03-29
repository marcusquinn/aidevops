---
name: avatars
description: Listing avatars, avatar styles, and avatar_id selection for HeyGen
metadata:
  tags: avatars, avatar-id, styles, listing, selection
---

# HeyGen Avatars

Avatars are AI-generated presenters. Use public or custom avatars.

## Workflow: Preview → Select → Generate

1. List avatars → get names, genders, preview URLs
2. Preview in browser — `open <preview_image_url>` (macOS) / `xdg-open` (Linux) — no auth needed
3. User selects avatar by name or ID
4. Get avatar details for `default_voice_id`
5. Generate video with `avatar_id` + `default_voice_id`

## Listing Avatars (v2)

**Endpoint:** `GET /v2/avatars`

```bash
curl -X GET "https://api.heygen.com/v2/avatars" \
  -H "X-Api-Key: $HEYGEN_API_KEY"
```

**Response:**

```json
{
  "error": null,
  "data": {
    "avatars": [
      {
        "avatar_id": "josh_lite3_20230714",
        "avatar_name": "Josh",
        "gender": "male",
        "preview_image_url": "https://files.heygen.ai/...",
        "preview_video_url": "https://files.heygen.ai/..."
      }
    ]
  }
}
```

```typescript
interface Avatar {
  avatar_id: string;
  avatar_name: string;
  gender: "male" | "female";
  preview_image_url: string;
  preview_video_url: string;
}
```

## Avatar Types

| Type | Identification | API |
|------|---------------|-----|
| Public | `avatar_id` without `custom_` prefix | `/v2/avatars` |
| Custom | `avatar_id` starts with `custom_` | `/v2/avatars` |
| Instant | Created from single photo/short video | `/v1/instant_avatar.list` |

## Avatar Groups (v3 — Recommended for Search)

Paginated listing and search via v3:

```bash
# List groups (include public)
curl -X GET "https://api.heygen.com/v3/avatar_group.list?page=1&page_size=20&include_public=true" \
  -H "X-Api-Key: $HEYGEN_API_KEY"

# Search public avatars
curl -X GET "https://api.heygen.com/v3/avatar_groups/search?page=1&page_size=20&query=professional" \
  -H "X-Api-Key: $HEYGEN_API_KEY"

# Get avatars in a group (v2)
curl -X GET "https://api.heygen.com/v2/avatar_group/{group_id}/avatars" \
  -H "X-Api-Key: $HEYGEN_API_KEY"
```

**`avatar_group.list` params:** `page` (1–10000), `page_size` (1–1000), `query`, `include_public` (bool)

**`avatar_groups/search` params:** `page`, `page_size`, `query`, `search_tags` (comma-separated), `list_filter`

```typescript
interface AvatarGroupItem {
  id: string;
  name: string;
  created_at: number;
  num_looks: number;
  preview_image: string;
  group_type: string;
  train_status: string;
  default_voice_id: string | null;
}
```

## Avatar Styles

| Style | Description | Use case |
|-------|-------------|----------|
| `normal` | Full body, standard framing | Full-screen presenter, corporate |
| `closeUp` | Face close-up, more expressive | Personal/intimate content |
| `circle` | Circular talking-head frame | Picture-in-picture, corner widget |
| `voice_only` | Audio only, no video | Podcast/audio content |

```typescript
// In video_inputs[].character:
{
  type: "avatar",
  avatar_id: "josh_lite3_20230714",
  avatar_style: "normal",  // "normal" | "closeUp" | "circle" | "voice_only"
}

// Circle style: use green background for chroma key
{
  character: { type: "avatar", avatar_id: "josh_lite3_20230714", avatar_style: "circle" },
  background: { type: "color", value: "#00FF00" },
}
```

## Default Voice (Recommended)

**Always use `default_voice_id`** — pre-matched for gender and lip sync.

**Flow:** `GET /v2/avatars` → `GET /v2/avatar/{id}/details` → `POST /v2/video/generate`

```bash
curl -X GET "https://api.heygen.com/v2/avatar/{avatar_id}/details" \
  -H "X-Api-Key: $HEYGEN_API_KEY"
```

```typescript
interface AvatarDetails {
  id: string;
  name: string;
  gender: "male" | "female";
  preview_image_url: string;
  preview_video_url: string;
  premium: boolean;
  is_public: boolean;
  default_voice_id: string | null;
  tags: string[];
}
```

## Common Mistakes

- Using themed/seasonal avatars for business content — looks unprofessional
- Not previewing before generation — always `open <preview_image_url>`
- Mismatched voice gender — use `default_voice_id` or match genders manually
- Using `circle` style for full-screen presentations — wrong framing

## Common Avatar IDs

| Avatar ID | Name | Gender |
|-----------|------|--------|
| `josh_lite3_20230714` | Josh | Male |
| `angela_expressive_20231010` | Angela | Female |
| `wayne_20240422` | Wayne | Male |
| `lily_20230614` | Lily | Female |

Always verify availability via the list endpoint — IDs may change.
