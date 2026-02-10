---
description: "AI video generation - Sora 2, Veo 3.1, Higgsfield, seed bracketing, and production workflows"
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

# AI Video Production

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Generate professional AI video content using Sora 2, Veo 3.1, and Higgsfield
- **Primary Models**: Sora 2 Pro (UGC/authentic), Veo 3.1 (cinematic/character-consistent)
- **Key Technique**: Seed bracketing (15% → 70%+ success rate)
- **Production Value Threshold**: <$10k = Sora 2, >$100k = Veo 3.1

**When to Use**: Read this when generating AI video content, planning video production workflows, or optimizing video generation quality.

**Model Selection Decision Tree**:

```text
Content Type?
├─ UGC/Authentic/Social (<$10k production value)
│  └─ Sora 2 Pro
├─ Cinematic/Commercial (>$100k production value)
│  └─ Veo 3.1
└─ Character-Consistent Series
   └─ Veo 3.1 (with Ingredients)
```

**Critical Techniques**:
- Seed bracketing: Test seeds 1000-1010, score outputs, iterate
- Content-type seed ranges: people 1000-1999, action 2000-2999, landscape 3000-3999, product 4000-4999, YouTube 2000-3000
- 2-Track production: objects/environments (Midjourney→VEO) vs characters (Freepik→Seedream→VEO)
- Veo 3.1: ALWAYS use ingredients-to-video, NEVER frame-to-video (produces grainy yellow output)

<!-- AI-CONTEXT-END -->

## Sora 2 Pro Master Template

Sora 2 excels at UGC-style, authentic content with <$10k production value. Use the 6-section master template for professional results.

### Template Structure

```text
[1. HEADER - Style Definition (7 parameters)]
Style: [aesthetic], [mood], [color palette], [lighting], [texture], [era/period], [cultural context]

[2. SHOT-BY-SHOT BREAKDOWN - Cinematography Spec (5 points each)]
Shot 1 (0-2s):
- Type: [ECU/CU/MCU/MS/MWS/WS/EWS]
- Angle: [eye-level/high/low/dutch/overhead/POV]
- Movement: [static/dolly/pan/tracking/handheld/crane]
- Focus: [subject/background/rack focus]
- Composition: [rule of thirds/centered/leading lines/symmetry]

Shot 2 (2-4s):
[repeat 5-point spec]

[3. TIMESTAMPED ACTIONS - 0.5s intervals]
0.0s: [precise action description]
0.5s: [micro-movement or expression change]
1.0s: [next action beat]
1.5s: [continuation or transition]
2.0s: [new action or camera shift]
[continue through full duration]

[4. DIALOGUE - Delivery Style]
Character: "Exact dialogue text"
Delivery: [tone, pacing, emotion, emphasis]
Duration: [8-second rule: 12-15 words, 20-25 syllables max]

[5. BACKGROUND SOUND - 4-Layer Audio Design]
Layer 1 (Dialogue): [voice characteristics, clarity]
Layer 2 (Ambient): [environment noise at -25 LUFS]
Layer 3 (SFX): [specific sound effects with timing]
Layer 4 (Music): [score/diegetic, mood, volume]

[6. TECHNICAL SPECS FOOTER]
Duration: [total seconds]
Aspect Ratio: [16:9/9:16/1:1]
Resolution: [1080p/4K/8K]
Frame Rate: [24fps/30fps/60fps - 60fps for action only]
Camera Model: [RED Komodo 6K / ARRI Alexa LF / Sony Venice 8K]
Negative Prompt: subtitles, captions, watermark, text overlays, poor lighting, blurry footage, artifacts, distorted hands
```

### Example: Product Demo (UGC Style)

```text
[1. HEADER]
Style: authentic, energetic, warm natural tones, soft window lighting, organic texture, contemporary 2024, creator economy aesthetic

[2. SHOT-BY-SHOT]
Shot 1 (0-3s):
- Type: MCU (medium close-up)
- Angle: Eye-level, slightly off-center
- Movement: Handheld with subtle natural shake
- Focus: Subject's face, shallow depth of field
- Composition: Rule of thirds, subject left, product right

Shot 2 (3-6s):
- Type: CU (close-up) on product
- Angle: Overhead, 45-degree tilt
- Movement: Slow dolly in
- Focus: Product details, rack focus to hands
- Composition: Centered with leading lines from hands

[3. TIMESTAMPED ACTIONS]
0.0s: Creator looks directly at camera, genuine smile forming
0.5s: Picks up product from desk with right hand
1.0s: Holds product at chest level, slight rotation to show features
1.5s: Left hand gestures toward product feature
2.0s: Camera shifts to overhead view
2.5s: Hands demonstrate product use with natural movements
3.0s: Close-up of product in action
3.5s: Hands adjust product position
4.0s: Camera pulls back slightly
4.5s: Creator's face re-enters frame, nodding
5.0s: Final product showcase position
5.5s: Creator maintains eye contact with camera

[4. DIALOGUE]
Creator: "This completely changed how I work. The build quality is incredible, and it just works."
Delivery: Conversational, authentic enthusiasm, slight emphasis on "completely" and "incredible", natural pacing with brief pause after "work"
Duration: 6 seconds (14 words, 22 syllables)

[5. BACKGROUND SOUND]
Layer 1 (Dialogue): Clear voice, warm tone, -15 LUFS
Layer 2 (Ambient): Quiet home office, distant keyboard typing, soft room tone, -25 LUFS
Layer 3 (SFX): Product pickup sound (0.5s), subtle handling sounds (2.5s-4.0s)
Layer 4 (Music): None (UGC authenticity)

[6. TECHNICAL SPECS]
Duration: 6 seconds
Aspect Ratio: 9:16 (vertical for social)
Resolution: 1080p
Frame Rate: 30fps
Camera Model: iPhone 15 Pro aesthetic (UGC authenticity)
Negative Prompt: subtitles, captions, watermark, text overlays, professional studio lighting, overly polished, corporate aesthetic, artificial movements, poor lighting, blurry footage, artifacts, distorted hands
```

## Veo 3.1 Production Workflow

Veo 3.1 excels at cinematic, character-consistent content with >$100k production value. CRITICAL: Always use ingredients-to-video workflow, NEVER frame-to-video.

### VEO Prompting Framework (7 Components)

```text
[1. TECHNICAL SPECS]
Camera: [model/lens], [resolution], [frame rate], [aspect ratio]
Lighting: [setup], [color temperature], [mood]
Movement: [type], [speed], [direction]

[2. SUBJECT]
Character: [15+ attributes for consistency - see Character Bible]
OR
Object: [detailed physical description]

[3. ACTION]
Primary: [main movement/activity]
Secondary: [supporting actions, micro-expressions]
Timing: [pacing, beats, transitions]

[4. CONTEXT]
Environment: [location, time of day, weather]
Props: [relevant objects, their placement]
Atmosphere: [mood, energy, tone]

[5. CAMERA MOVEMENT]
Type: [static/dolly/pan/tracking/crane/handheld]
Path: [direction, speed, focal changes]
Motivation: [why this movement serves the story]

[6. COMPOSITION]
Framing: [shot type, rule of thirds, symmetry]
Depth: [foreground/midground/background elements]
Visual Hierarchy: [what draws the eye first]

[7. AUDIO]
Dialogue: [exact words, delivery style] (NO SUBTITLES in prompt)
Ambient: [environment sounds, specific to location]
SFX: [action-specific sounds with timing]
Music: [score/diegetic, mood, instrumentation]
```

### Ingredients-to-Video Workflow (MANDATORY)

**CRITICAL**: Frame-to-video produces grainy, yellow-tinted output. Always use ingredients.

**Step 1: Prepare Ingredients**

Upload reference assets as "ingredients" (not as frame-to-video input):
- Character faces (for consistency across scenes)
- Product images (for accurate representation)
- Brand assets (logos, colors, textures)
- Style references (lighting, composition examples)

**Step 2: Create Ingredient Library**

```bash
# Via Higgsfield API
curl -X POST 'https://platform.higgsfield.ai/api/characters' \
  --header 'hf-api-key: {api-key}' \
  --header 'hf-secret: {secret}' \
  --form 'photo=@/path/to/character_face.jpg'

# Response includes ingredient ID
{
  "id": "3eb3ad49-775d-40bd-b5e5-38b105108780",
  "photo_url": "https://cdn.higgsfield.ai/characters/photo_123.jpg"
}
```

**Step 3: Generate with Ingredients**

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

**Ingredient Strength Guidelines**:
- 0.7-0.8: Subtle influence, allows creative variation
- 0.9-1.0: Strong consistency, minimal deviation
- Character faces: 0.9+
- Products: 0.95+
- Style references: 0.7-0.8

### Example: Cinematic Commercial

```text
[1. TECHNICAL SPECS]
Camera: ARRI Alexa LF, 35mm anamorphic lens, 8K, 24fps, 2.39:1 aspect ratio
Lighting: Golden hour natural light, 3200K color temperature, warm cinematic mood
Movement: Slow dolly in (2 seconds), smooth gimbal stabilization

[2. SUBJECT]
Character: [Reference ingredient ID: 3eb3ad49-775d-40bd-b5e5-38b105108780]
Woman, late 20s, Mediterranean features, shoulder-length dark brown hair with natural wave, hazel eyes, confident posture, wearing tailored charcoal blazer, minimal jewelry (small gold earrings), professional yet approachable demeanor

[3. ACTION]
Primary: Character walks slowly toward camera through modern office lobby, maintaining eye contact
Secondary: Slight smile forming at 2-second mark, natural arm swing, confident stride
Timing: Deliberate pacing, 3 steps total over 5 seconds, pause at 4-second mark

[4. CONTEXT]
Environment: Contemporary glass-walled office lobby, floor-to-ceiling windows, city skyline visible, golden hour sunlight streaming through, polished concrete floors reflecting light
Props: Minimalist reception desk (background), potted plants (midground), architectural columns (framing)
Atmosphere: Aspirational, professional, warm, inviting

[5. CAMERA MOVEMENT]
Type: Dolly in
Path: Starts at medium shot (MS), ends at medium close-up (MCU), smooth 0.5m forward movement over 5 seconds
Motivation: Creates intimacy, draws viewer into character's confidence

[6. COMPOSITION]
Framing: Rule of thirds, character positioned on right third, leading lines from floor tiles guide eye to subject
Depth: Foreground (character), midground (lobby elements), background (windows/skyline with bokeh)
Visual Hierarchy: Character's face (primary), blazer details (secondary), environment (tertiary)

[7. AUDIO]
Dialogue: None (visual storytelling)
Ambient: Quiet office atmosphere, distant keyboard typing, soft HVAC hum, -25 LUFS
SFX: Footsteps on polished concrete (subtle, 0.5s intervals), clothing rustle, -20 LUFS
Music: Minimal piano score, hopeful progression, 80 BPM, strings enter at 3s, -18 LUFS
```

## Seed Bracketing Method

Seed bracketing increases success rate from 15% to 70%+ by systematically testing seed ranges and scoring outputs.

### Process

**Step 1: Define Content Type**

Select seed range based on content:
- **People/Characters**: 1000-1999
- **Action/Movement**: 2000-2999
- **Landscape/Environment**: 3000-3999
- **Product/Object**: 4000-4999
- **YouTube-Optimized**: 2000-3000 (hybrid action/people)

**Step 2: Generate Test Batch**

Generate 10-15 variations with sequential seeds:

```bash
# Example: Product video (seed range 4000-4999)
for seed in {4000..4010}; do
  # Generate with identical prompt, varying only seed
  curl -X POST 'https://platform.higgsfield.ai/v1/image2video/dop' \
    --header 'hf-api-key: {api-key}' \
    --header 'hf-secret: {secret}' \
    --data "{
      \"params\": {
        \"prompt\": \"[your prompt]\",
        \"seed\": $seed,
        \"model\": \"dop-turbo\"
      }
    }"
done
```

**Step 3: Score Outputs**

Evaluate each output on 5 criteria (1-10 scale):

| Criterion | Weight | Description |
|-----------|--------|-------------|
| Composition | 25% | Framing, balance, visual hierarchy |
| Quality | 25% | Resolution, artifacts, smoothness |
| Style Adherence | 20% | Matches intended aesthetic |
| Motion Realism | 20% | Natural movement, physics |
| Subject Accuracy | 10% | Prompt adherence, details |

**Scoring Formula**:

```text
Total Score = (Composition × 0.25) + (Quality × 0.25) + (Style × 0.20) + (Motion × 0.20) + (Accuracy × 0.10)
```

**Step 4: Identify Winners**

- **Score 8.0+**: Production-ready, use immediately
- **Score 6.5-7.9**: Acceptable, minor tweaks needed
- **Score <6.5**: Discard, try different seed range

**Step 5: Iterate**

If no winners in initial range:
1. Shift to adjacent range (+/- 100)
2. Test 10 more seeds
3. If still no winners, revise prompt (likely prompt issue, not seed)

### Automation

Use `seed-bracket-helper.sh` for the full automation workflow:

```bash
# Generate 11 product video variants with seed bracketing
seed-bracket-helper.sh generate --type product --prompt "Product rotating on white background"

# Check job status
seed-bracket-helper.sh status

# Score completed outputs (composition, quality, style, motion, accuracy — each 1-10)
seed-bracket-helper.sh score 4005 8 9 7 8 9

# View report with winners and recommendations
seed-bracket-helper.sh report

# List content-type presets and scoring weights
seed-bracket-helper.sh presets
```

The helper manages bracket runs, tracks job status via the Higgsfield API, calculates weighted scores, and identifies production-ready winners (80+/100) vs acceptable outputs (65-80) vs rejects.

## 8K Camera Model Prompting

Append professional camera models to prompts for cinematic quality and specific aesthetic characteristics.

### Camera Model Library

| Camera | Aesthetic | Use Case | Color Science |
|--------|-----------|----------|---------------|
| **RED Komodo 6K** | Digital cinema, sharp | Action, sports, high-motion | Vibrant, punchy reds |
| **ARRI Alexa LF** | Film-like, organic | Drama, narrative, skin tones | Warm, natural, forgiving |
| **Sony Venice 8K** | Clean, clinical | Commercial, product, precision | Neutral, accurate |
| **Blackmagic URSA 12K** | Raw, flexible | Indie, experimental | Flat, gradable |
| **Canon C500 Mark II** | Smooth, polished | Corporate, documentary | Warm, Canon color |
| **Panasonic Varicam LT** | Broadcast, reliable | News, live, fast turnaround | Neutral, broadcast-safe |

### Lens Characteristics

| Lens Type | Effect | Prompt Addition |
|-----------|--------|-----------------|
| **35mm Anamorphic** | Cinematic, oval bokeh, lens flares | "35mm anamorphic lens, 2.39:1 aspect ratio, horizontal lens flares" |
| **50mm Prime** | Natural perspective, sharp | "50mm prime lens, shallow depth of field, sharp focus" |
| **24mm Wide** | Expansive, environmental | "24mm wide-angle lens, environmental context, slight distortion" |
| **85mm Portrait** | Flattering, compressed | "85mm portrait lens, compressed perspective, creamy bokeh" |
| **14mm Ultra-Wide** | Dramatic, immersive | "14mm ultra-wide lens, dramatic perspective, deep focus" |

### Example Prompts

**Cinematic Drama**:

```text
Shot on ARRI Alexa LF with 35mm anamorphic lens, 8K resolution, 24fps, 2.39:1 aspect ratio. 
Warm color grading, film grain texture, natural lighting with practical sources.
[rest of prompt]
```

**High-Action Sports**:

```text
Shot on RED Komodo 6K with 24mm wide-angle lens, 6K resolution, 60fps, 16:9 aspect ratio.
Vibrant color grading, sharp detail, high shutter speed for motion clarity.
[rest of prompt]
```

**Commercial Product**:

```text
Shot on Sony Venice 8K with 50mm prime lens, 8K resolution, 30fps, 16:9 aspect ratio.
Neutral color grading, clinical precision, controlled studio lighting.
[rest of prompt]
```

## 2-Track Production Workflow

Separate workflows for objects/environments vs characters optimize quality and efficiency.

### Track 1: Objects & Environments

**Pipeline**: Midjourney → Veo 3.1

**Step 1: Generate Base Image (Midjourney)**

```text
/imagine [object/environment description] --ar 16:9 --style raw --v 6
```

Midjourney excels at:
- Product renders
- Architectural spaces
- Landscapes
- Abstract concepts
- Inanimate objects

**Step 2: Animate with Veo 3.1**

Upload Midjourney output as ingredient, apply VEO prompting framework for animation.

### Track 2: Characters & People

**Pipeline**: Freepik → Seedream 4 → Veo 3.1

**Step 1: Generate Character (Freepik)**

Freepik AI excels at character-driven scenes with consistent facial features.

**Step 2: Refine to 4K (Seedream 4)**

```bash
# Via Higgsfield API
curl -X POST 'https://platform.higgsfield.ai/bytedance/seedream/v4/upscale' \
  --header 'Authorization: Key {api_key}:{api_secret}' \
  --data '{
    "image_url": "https://freepik-output.jpg",
    "target_resolution": "4K"
  }'
```

**Step 3: Animate with Veo 3.1**

Upload refined character as ingredient, generate video with character consistency.

### When to Use Each Track

| Content Type | Track | Reason |
|--------------|-------|--------|
| Product demo | Track 1 | Objects, no facial consistency needed |
| Landscape flythrough | Track 1 | Environment, no characters |
| Talking head | Track 2 | Facial expressions, character consistency |
| Character narrative | Track 2 | Emotional range, consistent identity |
| Mixed (character + product) | Both | Generate separately, composite in post |

## Content Type Presets

Pre-configured settings for common video formats.

### UGC (User-Generated Content)

```yaml
aspect_ratio: 9:16
duration: 3-10s
cuts: 1-3s per shot
camera: Handheld, natural shake
lighting: Available light, authentic
audio: All diegetic (no score)
model: Sora 2 Pro
seed_range: 2000-3000
```

**Use Cases**: TikTok, Instagram Reels, YouTube Shorts, authentic testimonials

### Commercial

```yaml
aspect_ratio: 16:9
duration: 15-30s
cuts: 2-5s per shot
camera: Gimbal-stabilized, smooth
lighting: Controlled, 3-point setup
audio: Mixed diegetic + score
model: Veo 3.1
seed_range: 4000-4999 (product) or 1000-1999 (people)
```

**Use Cases**: Brand ads, product launches, corporate videos

### Cinematic

```yaml
aspect_ratio: 2.39:1 (anamorphic)
duration: 10-30s
cuts: 4-10s per shot
camera: Dolly/crane, deliberate movement
lighting: Motivated, cinematic color grading
audio: Score-driven, minimal diegetic
model: Veo 3.1
seed_range: 3000-3999 (landscape) or 1000-1999 (character)
```

**Use Cases**: Film trailers, high-end commercials, narrative content

### Documentary

```yaml
aspect_ratio: 16:9
duration: 15-60s
cuts: 5-15s per shot
camera: Tripod/handheld mix, observational
lighting: Natural, minimal intervention
audio: Diegetic priority, subtle score
model: Sora 2 Pro (authentic) or Veo 3.1 (polished)
seed_range: 2000-2999 (action) or 3000-3999 (environment)
```

**Use Cases**: Educational content, explainers, journalistic pieces

## Post-Production Guidelines

### Upscaling

**Topaz Video AI** is the industry standard for AI upscaling.

**Rules**:
- Maximum 1.25-1.75x upscale (beyond this introduces artifacts)
- 1080p → 1440p: 1.33x (safe)
- 1080p → 4K: 2x (risky, only for high-quality source)
- 4K → 8K: NOT RECOMMENDED (diminishing returns, high artifact risk)

**Settings**:

```yaml
model: Artemis High Quality
noise_reduction: Low (preserve texture)
sharpening: Minimal (avoid over-sharpening)
grain_preservation: On
```

### Film Grain

Add subtle film grain for organic, less-AI-detected aesthetic.

**Recommended Settings** (DaVinci Resolve):

```yaml
grain_size: 0.5-0.8
grain_intensity: 5-10%
color_variation: 2-5%
```

**When to Apply**:
- Cinematic content: Always
- UGC content: Optional (can reduce authenticity)
- Commercial: Selective (brand-dependent)

### Frame Rate Conversion

**60fps**: ONLY for high-action content (sports, fast motion)

**24fps**: Cinematic standard, use for narrative/commercial
**30fps**: Broadcast/web standard, use for UGC/documentary

**Conversion Tools**:
- DaVinci Resolve: Optical Flow (best quality)
- Adobe Premiere: Frame Blending (fast, lower quality)
- Topaz Video AI: Chronos (AI-based, good for complex motion)

**CRITICAL**: Never upconvert 24fps → 60fps for non-action content (creates soap opera effect)

## Shot Type Reference

### Framing

| Abbreviation | Name | Framing | Use Case |
|--------------|------|---------|----------|
| **EWS** | Extreme Wide Shot | Full environment, subject tiny | Establishing, scale, context |
| **WS** | Wide Shot | Full body, environment visible | Subject in context, movement |
| **MWS** | Medium Wide Shot | Knees up, some environment | Group shots, interaction |
| **MS** | Medium Shot | Waist up | Standard conversation, presentation |
| **MCU** | Medium Close-Up | Chest up | Emotional connection, detail |
| **CU** | Close-Up | Head and shoulders | Emotion, intimacy |
| **ECU** | Extreme Close-Up | Eyes, mouth, hands | Intense emotion, detail |

### Camera Angles

| Angle | Effect | Use Case |
|-------|--------|----------|
| **Eye-Level** | Neutral, relatable | Standard dialogue, natural perspective |
| **High Angle** | Vulnerability, weakness | Subject looking up, diminished power |
| **Low Angle** | Power, dominance | Subject looking down, authority |
| **Dutch Angle** | Unease, tension | Disorientation, psychological thriller |
| **Overhead** | Observation, isolation | God's-eye view, planning, maps |
| **POV** | Immersion, subjectivity | First-person perspective, empathy |

### Camera Movements

| Movement | Description | Effect | Use Case |
|----------|-------------|--------|----------|
| **Static** | No camera movement | Stability, observation | Dialogue, contemplation |
| **Pan** | Horizontal rotation | Reveal, follow | Landscape reveal, subject tracking |
| **Tilt** | Vertical rotation | Scale, reveal | Building height, subject reveal |
| **Dolly In** | Move toward subject | Intimacy, focus | Emotional intensification |
| **Dolly Out** | Move away from subject | Context, isolation | Reveal environment, distance |
| **Tracking** | Follow subject laterally | Energy, continuity | Walking, running, vehicles |
| **Crane** | Vertical movement | Drama, scale | Establishing, dramatic reveal |
| **Handheld** | Natural shake | Authenticity, energy | UGC, documentary, action |
| **Gimbal** | Smooth stabilization | Cinematic, polished | Commercial, narrative |

## Model Comparison

### Sora 2 Pro

**Strengths**:
- Authentic, UGC aesthetic
- Fast generation (<2 min)
- Lower cost per generation
- Excellent for social media content
- Natural, organic movement

**Limitations**:
- Maximum 10 seconds per generation
- Less control over cinematography
- Character consistency across shots is challenging
- Lower resolution (1080p native)

**Best For**: TikTok, Reels, Shorts, testimonials, authentic content, <$10k production value

### Veo 3.1

**Strengths**:
- Cinematic quality
- Character consistency (with ingredients)
- Precise control over all parameters
- 8K output capability
- Professional-grade results

**Limitations**:
- Slower generation (5-10 min)
- Higher cost per generation
- Requires more detailed prompting
- Ingredients workflow adds complexity

**Best For**: Commercials, brand content, narrative, character-driven series, >$100k production value

### Higgsfield (Multi-Model)

**Strengths**:
- Access to 100+ models via single API
- Kling, Seedance, DOP models available
- Unified workflow across models
- Webhook support for async pipelines

**Limitations**:
- API-based (no UI for quick tests)
- Requires technical integration
- Model availability varies

**Best For**: Automated pipelines, batch generation, A/B testing, production workflows

## Related Tools & Resources

### Internal References

- `tools/video/video-prompt-design.md` - Veo 3 Meta Framework (7-component prompting)
- `tools/video/higgsfield.md` - Higgsfield API integration
- `tools/video/remotion.md` - Programmatic video editing
- `content/production/image.md` - Image generation (Nanobanana Pro, Midjourney, Freepik)
- `content/production/audio.md` - Voice pipeline (CapCut cleanup + ElevenLabs)
- `content/production/characters.md` - Character consistency (Facial Engineering, Character Bibles)
- `content/optimization.md` - A/B testing, seed bracketing automation
- `scripts/seed-bracket-helper.sh` - Seed bracketing CLI (generate, score, report)

### External Resources

- [Sora 2 Documentation](https://openai.com/sora)
- [Veo 3.1 Documentation](https://deepmind.google/technologies/veo/)
- [Higgsfield Platform](https://platform.higgsfield.ai)
- [Topaz Video AI](https://www.topazlabs.com/topaz-video-ai)

### Helper Scripts

```bash
# Seed bracketing automation
seed-bracket-helper.sh generate --type product --prompt "Product rotating on white background"
seed-bracket-helper.sh status
seed-bracket-helper.sh score 4005 8 9 7 8 9
seed-bracket-helper.sh report

# Unified video generation CLI (Sora 2, Veo 3.1, Nanobanana Pro)
video-gen-helper.sh generate sora "A cat reading a book" sora-2-pro 8 1280x720
video-gen-helper.sh generate veo "Cinematic mountain sunset" veo-3.1-generate-001 16:9
video-gen-helper.sh generate nanobanana "Cat walks through garden" https://example.com/cat.jpg dop-turbo

# Image generation (Nanobanana Pro / Soul model)
video-gen-helper.sh image "Product on desk, studio lighting" 1696x960 1080p

# Character creation for consistency
video-gen-helper.sh character /path/to/face.jpg

# Seed bracketing automation
video-gen-helper.sh bracket "Product demo" https://example.com/product.jpg 4000 4010 dop-turbo

# Check status and download
video-gen-helper.sh status sora vid_abc123
video-gen-helper.sh download sora vid_abc123 ./output

# Show all available models
video-gen-helper.sh models

# Batch upscaling (planned)
topaz-upscale-helper.sh --input ./raw/ --output ./upscaled/ --scale 1.5
```

## Quick Start Checklist

**For UGC/Social Content (Sora 2)**:
- [ ] Use 6-section master template
- [ ] Set aspect ratio to 9:16
- [ ] Keep duration 3-10 seconds
- [ ] Use seed range 2000-3000
- [ ] Specify handheld camera movement
- [ ] Include authentic, natural lighting
- [ ] Test 10 seeds, score outputs
- [ ] Add subtle film grain in post

**For Cinematic/Commercial (Veo 3.1)**:
- [ ] Prepare character/product ingredients
- [ ] Use 7-component VEO framework
- [ ] Set aspect ratio to 16:9 or 2.39:1
- [ ] Specify professional camera model (ARRI/RED/Sony)
- [ ] Use seed range based on content type
- [ ] Test ingredients-to-video workflow (NEVER frame-to-video)
- [ ] Score outputs, iterate on winners
- [ ] Upscale with Topaz (max 1.75x)
- [ ] Add film grain for organic aesthetic

**For Character-Consistent Series**:
- [ ] Create character ingredient library
- [ ] Document character bible (15+ attributes)
- [ ] Use Veo 3.1 with ingredient strength 0.9+
- [ ] Test seed range 1000-1999
- [ ] Maintain identical character description across all prompts
- [ ] Store winning seeds for reuse
- [ ] Verify consistency across all outputs before finalizing
