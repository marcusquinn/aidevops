---
name: avatars
description: Listing avatars, avatar styles, and avatar_id selection for HeyGen
metadata:
  tags: avatars, avatar-id, styles, listing, selection
---

# HeyGen Avatars

Avatars are AI-generated presenters. Use public HeyGen avatars or custom avatars.

## Workflow: Preview → Select → Generate

1. List avatars — get names, genders, preview URLs
2. Open preview in browser — `open <preview_image_url>` (macOS) / `xdg-open` (Linux)
3. User selects avatar by name or ID
4. Get avatar details for `default_voice_id`
5. Generate video with `avatar_id` + `default_voice_id`

**Preview URLs are publicly accessible — no auth needed. Pass the URL directly to `open`; it opens in the browser without downloading.**

```bash
# macOS: open URL in browser (no download)
open "https://files.heygen.ai/avatar/preview/josh.jpg"
open "https://files.heygen.ai/avatar/preview/josh.mp4"

# Linux
xdg-open "https://files.heygen.ai/avatar/preview/josh.jpg"
```

## Listing Avatars

**Endpoint:** `GET /v2/avatars`

```bash
curl -X GET "https://api.heygen.com/v2/avatars" \
  -H "X-Api-Key: $HEYGEN_API_KEY"
```

```typescript
interface Avatar {
  avatar_id: string;
  avatar_name: string;
  gender: "male" | "female";
  preview_image_url: string;  // open in browser — no auth needed
  preview_video_url: string;
}

async function listAvatars(): Promise<Avatar[]> {
  const response = await fetch("https://api.heygen.com/v2/avatars", {
    headers: { "X-Api-Key": process.env.HEYGEN_API_KEY! },
  });
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  const json = await response.json();
  if (json.error) throw new Error(json.error);
  return json.data.avatars;
}

// Filter helpers
const byGender = (avatars: Avatar[], g: "male" | "female") =>
  avatars.filter((a) => a.gender === g);
const byName = (avatars: Avatar[], q: string) =>
  avatars.filter((a) => a.avatar_name.toLowerCase().includes(q.toLowerCase()));
```

**Response shape:**

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
    ],
    "talking_photos": []
  }
}
```

## Avatar Types

| Type | How to identify | API |
|------|----------------|-----|
| Public | `avatar_id` does not start with `custom_` | `/v2/avatars` |
| Custom | `avatar_id` starts with `custom_` | `/v2/avatars` |
| Instant | Created from a single photo/short video | `/v1/instant_avatar.list` |

## Avatar Groups (v3 — Recommended)

Use v3 for paginated listing and search:

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

**v3 `avatar_group.list` params:** `page` (1–10000), `page_size` (1–1000), `query` (text search), `include_public` (bool)

**v3 `avatar_groups/search` params:** `page`, `page_size`, `query`, `search_tags` (comma-separated), `list_filter`

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

async function listAvatarGroups(
  page = 1, pageSize = 20, includePublic = true, query?: string
): Promise<{ avatar_group_list: AvatarGroupItem[]; total_count: number }> {
  const params = new URLSearchParams({
    page: page.toString(),
    page_size: pageSize.toString(),
    include_public: includePublic.toString(),
    ...(query ? { query } : {}),
  });
  const response = await fetch(
    `https://api.heygen.com/v3/avatar_group.list?${params}`,
    { headers: { "X-Api-Key": process.env.HEYGEN_API_KEY! } }
  );
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  const json = await response.json();
  if (json.error) throw new Error(json.error);
  return json.data;
}
```

## Avatar Styles

| Style | Description | Best for |
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

## Using Avatar's Default Voice (Recommended)

**Always use `default_voice_id`** — it's pre-matched for gender and lip sync.

**Flow:** `GET /v2/avatars` → `GET /v2/avatar/{id}/details` → `POST /v2/video/generate`

```bash
curl -X GET "https://api.heygen.com/v2/avatar/{avatar_id}/details" \
  -H "X-Api-Key: $HEYGEN_API_KEY"
```

```typescript
interface AvatarDetails {
  type: "avatar";
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

async function getAvatarDetails(avatarId: string): Promise<AvatarDetails> {
  const response = await fetch(
    `https://api.heygen.com/v2/avatar/${avatarId}/details`,
    { headers: { "X-Api-Key": process.env.HEYGEN_API_KEY! } }
  );
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  const json = await response.json();
  if (json.error) throw new Error(json.error);
  return json.data;
}

async function generateWithDefaultVoice(avatarId: string, script: string): Promise<string> {
  const avatar = await getAvatarDetails(avatarId);
  if (!avatar.default_voice_id) throw new Error(`${avatar.name} has no default voice`);

  return generateVideo({
    video_inputs: [{
      character: { type: "avatar", avatar_id: avatar.id, avatar_style: "normal" },
      voice: { type: "text", input_text: script, voice_id: avatar.default_voice_id },
    }],
    dimension: { width: 1920, height: 1080 },
  });
}
```

## Selecting the Right Avatar

| Category | Examples | Best for |
|----------|----------|----------|
| Business/Professional | Josh, Angela, Wayne | Corporate, product demos, training |
| Casual/Friendly | Lily, lifestyle avatars | Social media, informal content |
| Expressive | Avatars with "expressive" in name | Storytelling, dynamic content |
| Themed/Seasonal | Holiday, costume avatars | Specific campaigns only |

**Common mistakes:**
- Using themed avatars for business content (looks unprofessional)
- Not previewing before generation — always `open <preview_image_url>`
- Mismatched voice gender — use `default_voice_id` or match genders manually
- Wrong style — `circle` doesn't work for full-screen presentations

**Pre-generation checklist:**
- [ ] Previewed avatar image/video in browser
- [ ] Appearance matches content tone
- [ ] Style fits video format
- [ ] Using `default_voice_id` when available

## Common Avatar IDs

| Avatar ID | Name | Gender |
|-----------|------|--------|
| `josh_lite3_20230714` | Josh | Male |
| `angela_expressive_20231010` | Angela | Female |
| `wayne_20240422` | Wayne | Male |
| `lily_20230614` | Lily | Female |

Always verify availability via the list endpoint before use.
