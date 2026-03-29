---
name: brand-identity
description: Brand identity bridge -- single source of truth for visual and verbal identity that design, content, and production agents all read
mode: subagent
model: sonnet
---

# Brand Identity Bridge

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Template**: `context/brand-identity.toon` in each project repo
- **8 dimensions**: Visual style, voice & tone, copywriting, imagery, iconography, buttons & forms, media & motion, brand positioning
- **Create**: From scratch or existing site via `tools/design/ui-ux-inspiration.md`
- **Related**: `content/guidelines.md`, `content/platform-personas.md`, `content/production-image.md`, `workflows/ui-verification.md`
- **When to use**: Before any design or content work. If `context/brand-identity.toon` is missing, create one first.

<!-- AI-CONTEXT-END -->

## Template (8 Dimensions)

```toon
[visual_style]
ui_style = ""  ui_style_keywords = []  colour_palette_name = ""  # ui_style from catalogue: Glassmorphism, Neubrutalism, etc.
colours
  primary = ""  secondary = ""  accent = ""  background = ""  surface = ""
  text_primary = ""  text_secondary = ""  success = ""  warning = ""  error = ""
dark_mode = false  dark_mode_strategy = ""
typography
  heading_font = ""  body_font = ""  mono_font = ""
  heading_weight = ""  body_weight = ""  base_size = ""  scale_ratio = ""  line_height = ""  letter_spacing = ""
border_radius = ""  spacing_unit = ""  shadow_style = ""
[voice_and_tone]
register = ""  vocabulary_level = ""  sentence_style = ""  # register: formal|casual|technical|conversational; vocab: simple|intermediate|advanced|technical; sentence: short_punchy|flowing|varied|academic
personality_traits = []  humour = ""  perspective = ""  # humour: none|dry|playful|self-deprecating; perspective: first_person_plural|singular|second_person|third_person
formality_spectrum = 0  emotional_range = ""  jargon_policy = ""  british_english = false  # formality 1-10
brand_voice_examples
  do = []  dont = []
[copywriting_patterns]
headline_style = ""  headline_case = ""  headline_max_words = 0  # style: question|statement|how_to|number|mixed; case: sentence|title|lowercase
subheadline_style = ""  paragraph_length = ""  cta_language = ""  # sub: explanatory|benefit|action; para: one_sentence|two_three_sentences|varied; cta: direct|benefit_led|urgency|conversational
cta_examples = []  power_words = []  words_to_avoid = []
transition_style = ""  list_style = ""  social_proof_style = ""  error_message_tone = ""  empty_state_tone = ""
[imagery]
primary_style = ""  photography_style = ""  illustration_style = ""  # primary: photography|illustration|3d|mixed|abstract; photo: editorial|lifestyle|product|documentary; illust: flat|isometric|hand_drawn|geometric|line_art
mood = ""  colour_treatment = ""  subjects = []  # mood: bright_optimistic|dark_moody|warm_natural|cool_technical; colour: full_colour|muted|duotone|monochrome|brand_tinted
composition_preference = ""  # centered|rule_of_thirds|asymmetric|full_bleed
aspect_ratios
  hero = ""  card = ""  thumbnail = ""  social = ""
stock_vs_custom = ""  filters = ""  people_in_images = ""  diversity_requirements = ""
[iconography]
library = ""  style = ""  stroke_width = ""  # library: lucide|heroicons|phosphor|tabler|custom; style: outline|filled|duotone|solid
size_scale
  xs = ""  sm = ""  md = ""  lg = ""  xl = ""
corner_style = ""  colour_usage = ""  animation = ""  fallback_library = ""  custom_icons = []
[buttons_and_forms]
button_variants
  primary
    background = ""  text_colour = ""  border_radius = ""  padding = ""  font_weight = ""  shadow = ""  hover_effect = ""  transition = ""
  secondary
    style = ""  # outline|ghost|subtle|tonal
  destructive
    style = ""  behaviour = ""
form_fields
  style = ""  border_radius = ""  focus_ring = ""  label_position = ""  validation_style = ""  # style: outlined|filled|underlined|minimal
button_copy_patterns
  primary_cta = []  secondary_cta = []  destructive_cta = []  confirmation_cta = []
label_voice = ""  placeholder_style = ""  success_message_style = ""
label_examples
  do = []  dont = []
error_message_examples
  required = ""  invalid = ""  server = ""
[media_and_motion]
animation_approach = ""  transition_timing = ""  easing = ""  loading_pattern = ""  # approach: subtle|moderate|bold|none; timing: fast(150ms)|normal(300ms)|slow(500ms); easing: ease-out|spring|linear|custom; loading: skeleton|spinner|shimmer|progressive
scroll_behaviour = ""  hover_interactions = ""  page_transitions = ""  micro_interactions = []
video_style = ""  video_pacing = ""  music_mood = ""  # video: talking_head|screen_recording|animated|cinematic|mixed
narration_style = ""  narration_perspective = ""  sound_effects = ""  video_intro_style = ""  video_outro_style = ""
[brand_positioning]  # all spectrums 1-10
premium_vs_accessible = 0  playful_vs_serious = 0  innovative_vs_established = 0  # budget→luxury, casual→corporate, cutting-edge→traditional
minimal_vs_maximal = 0  technical_vs_simple = 0  global_vs_local = 0  # stripped→dense, consumer→expert, local→universal
tagline = ""  value_proposition = ""  competitive_differentiator = ""
target_audience = ""  audience_sophistication = ""  industry = ""  # sophistication: beginner|intermediate|expert|mixed
desired_first_impression = ""  desired_trust_signals = []  brand_archetype = ""  # archetype: creator|sage|explorer|hero
```

## Agent Integration

Every agent producing design or content output MUST check `context/brand-identity.toon` — constraint, not suggestion.

| Agent type | Reads |
|------------|-------|
| All | `brand_positioning` |
| Design | `visual_style`, `iconography`, `buttons_and_forms`, `media_and_motion` |
| Content | `voice_and_tone`, `copywriting_patterns`, `imagery` |
| Production | `imagery`, `iconography`, `media_and_motion`, `visual_style` |

- `content/humanise.md`: Pass `voice_and_tone` to preserve brand personality during AI pattern removal
- `workflows/ui-verification.md`: Brand identity adds constraints but never relaxes verification gates

## Workflow

**From scratch** — via `tools/design/ui-ux-inspiration.md`:
1. Visual interview → UI style, palette, typography
2. Verbal interview → voice, tone spectrums, CTAs, words to avoid
3. Imagery & motion → image style, icon library, animation level
4. Brand positioning → walk each spectrum
5. Synthesise into `context/brand-identity.toon`, flag contradictions, iterate

**From existing site** — via `tools/design/ui-ux-inspiration.md`:
1. URL study → extract colours, typography, UI patterns
2. Read 5-10 pages → identify voice, CTAs, error messages
3. Present as filled template
4. Refine — what stays/changes/is missing
5. Merge kept elements with new directions, flag breaking changes

## Relationship Map

`context/brand-identity.toon` readers: `tools/design/ui-ux-inspiration.md` (writes it), `content/guidelines.md` (structural rules), `content/platform-personas.md` (voice shifts), `content/production-image.md` (image gen params), `content/production-characters.md` (character personality), `content/humanise.md` (preserve personality), `workflows/ui-verification.md` (adds constraints), `tools/design/ui-ux-catalogue.toon` (records choices).

## Example: Launchpad (developer deploy tool)

```toon
[visual_style]
ui_style = "Clean Minimal"  colour_palette_name = "Developer Calm"
colours
  primary = "#6366F1"  secondary = "#0EA5E9"  accent = "#F59E0B"  background = "#FAFAFA"  surface = "#FFFFFF"
  text_primary = "#18181B"  text_secondary = "#71717A"  success = "#22C55E"  warning = "#F59E0B"  error = "#EF4444"
dark_mode = true  dark_mode_strategy = "separate_palette"
typography
  heading_font = "Inter"  mono_font = "JetBrains Mono"  heading_weight = "600"  base_size = "16px"
border_radius = "8px"  spacing_unit = "4px"  shadow_style = "subtle"
[voice_and_tone]
register = "conversational"  vocabulary_level = "technical"  sentence_style = "short_punchy"
personality_traits = ["confident", "direct", "slightly_irreverent", "helpful"]
humour = "dry"  perspective = "first_person_plural"  formality_spectrum = 4  jargon_policy = "assume_knowledge"
brand_voice_examples
  do = ["Ship it.", "Your deploy is live. Took 11 seconds.", "Zero config. Seriously."]
  dont = ["We are delighted to inform you...", "Leverage our cutting-edge platform..."]
[copywriting_patterns]
headline_style = "statement"  headline_case = "sentence"  cta_language = "direct"
cta_examples = ["Deploy now", "Start building", "Try free"]
power_words = ["ship", "deploy", "build", "fast", "zero-config"]
words_to_avoid = ["leverage", "synergy", "cutting-edge", "streamline"]
[brand_positioning]
premium_vs_accessible = 4  playful_vs_serious = 4  technical_vs_simple = 7  global_vs_local = 8
tagline = "Ship your side project. Tonight."
value_proposition = "Deploy any framework to production in under a minute. No config files, no DevOps degree required."
competitive_differentiator = "Zero-config deploys that actually work. No YAML, no Dockerfiles, no 47-step tutorials."
target_audience = "Independent developers and small teams shipping side projects, MVPs, and internal tools"
audience_sophistication = "intermediate"  industry = "developer_tools"  brand_archetype = "creator"
```

## File Locations

| File | Purpose |
|------|---------|
| `.agents/tools/design/brand-identity.md` | This template |
| `context/brand-identity.toon` | Per-project identity |
| `context/inspiration/*.toon` | Per-project inspiration |
| `.agents/tools/design/ui-ux-catalogue.toon` | Style catalogue |
| `.agents/tools/design/ui-ux-inspiration.md` | Interview workflow |
