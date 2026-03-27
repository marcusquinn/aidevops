# Veo 3.1 Production Workflow

Veo 3.1 excels at cinematic, character-consistent content. **CRITICAL**: Always use ingredients-to-video, NEVER frame-to-video.

## VEO Prompting Framework (7 Components)

```text
[1. TECHNICAL SPECS] Camera: [model/lens], [resolution], [frame rate], [aspect ratio] | Lighting | Movement
[2. SUBJECT] Character: [15+ attributes for consistency] OR Object: [detailed description]
[3. ACTION] Primary: [main movement] | Secondary: [supporting actions] | Timing: [pacing, beats]
[4. CONTEXT] Environment: [location, time, weather] | Props | Atmosphere
[5. CAMERA MOVEMENT] Type | Path: [direction, speed, focal changes] | Motivation
[6. COMPOSITION] Framing: [shot type] | Depth: [foreground/midground/background] | Visual Hierarchy
[7. AUDIO] Dialogue: [exact words, delivery] (NO SUBTITLES in prompt) | Ambient | SFX | Music
```

## Ingredients-to-Video Workflow (MANDATORY)

**CRITICAL**: Frame-to-video produces grainy, yellow-tinted output. Always use ingredients.

**Step 1**: Upload reference assets as "ingredients" (character faces, product images, brand assets, style references).

```bash
# Create ingredient via Higgsfield API
curl -X POST 'https://platform.higgsfield.ai/api/characters' \
  --header 'hf-api-key: {api-key}' --header 'hf-secret: {secret}' \
  --form 'photo=@/path/to/character_face.jpg'
# Returns: {"id": "3eb3ad49-775d-40bd-b5e5-38b105108780", "photo_url": "..."}
```

**Step 2**: Generate with ingredient:

```json
{
  "params": {
    "prompt": "[Full VEO 7-component prompt]",
    "custom_reference_id": "3eb3ad49-775d-40bd-b5e5-38b105108780",
    "custom_reference_strength": 0.9,
    "model": "veo-3.1-pro"
  }
}
```

**Ingredient strength**: 0.7-0.8 = subtle influence; 0.9-1.0 = strong consistency. Character faces: 0.9+, Products: 0.95+, Style references: 0.7-0.8.
