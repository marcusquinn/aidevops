---
name: brand-identity
description: Brand identity bridge -- single source of truth for visual and verbal identity that design, content, and production agents all read
mode: subagent
model: sonnet
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

# Brand Identity Bridge

Per-project brand identity bridging design and content agents. A designer picks "Glassmorphism + Trust Blue" — this file ensures the copywriter knows that means "confident, technical, concise."

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Template**: `context/brand-identity.toon` in each project repo
- **Dimensions**: Visual style, voice & tone, copywriting patterns, imagery, iconography, buttons & forms, media & motion, brand positioning
- **Create**: Style interview (scratch) or URL study (existing site) via `tools/design/ui-ux-inspiration.md`
- **Related**: `content/guidelines.md`, `content/platform-personas.md`, `content/production/image.md`, `workflows/ui-verification.md`

**When to use**: Before any design or content work. Check `context/brand-identity.toon` — if missing, create one first.

<!-- AI-CONTEXT-END -->

Without a shared brand definition, designers and copywriters produce mismatched output. `context/brand-identity.toon` is the single source of truth, persisting across sessions.

## Brand Identity Template

```toon
[visual_style]
ui_style = ""              # From catalogue: Glassmorphism, Neubrutalism, etc.
ui_style_keywords = []
colour_palette_name = ""
colours
  primary = ""
  secondary = ""
  accent = ""
  background = ""
  surface = ""
  text_primary = ""
  text_secondary = ""
  success = ""
  warning = ""
  error = ""
dark_mode = false
dark_mode_strategy = ""    # "invert" | "separate_palette" | "dimmed"
typography
  heading_font = ""
  body_font = ""
  mono_font = ""
  heading_weight = ""
  body_weight = ""
  base_size = ""
  scale_ratio = ""
  line_height = ""
  letter_spacing = ""
border_radius = ""
spacing_unit = ""
shadow_style = ""          # "subtle" | "elevated" | "flat" | "layered"

[voice_and_tone]
register = ""              # "formal" | "casual" | "technical" | "conversational"
vocabulary_level = ""      # "simple" | "intermediate" | "advanced" | "technical"
sentence_style = ""        # "short_punchy" | "flowing" | "varied" | "academic"
personality_traits = []
humour = ""                # "none" | "dry" | "playful" | "self-deprecating"
perspective = ""           # "first_person_plural" | "first_person_singular" | "second_person" | "third_person"
formality_spectrum = 0     # 1=very casual, 10=very formal
emotional_range = ""       # "restrained" | "moderate" | "expressive"
jargon_policy = ""         # "avoid" | "define_on_first_use" | "assume_knowledge"
british_english = false
brand_voice_examples
  do = []  dont = []

[copywriting_patterns]
headline_style = ""        # "question" | "statement" | "how_to" | "number" | "mixed"
headline_case = ""         # "sentence" | "title" | "lowercase"
headline_max_words = 0
subheadline_style = ""     # "explanatory" | "benefit" | "action"
paragraph_length = ""      # "one_sentence" | "two_three_sentences" | "varied"
cta_language = ""          # "direct" | "benefit_led" | "urgency" | "conversational"
cta_examples = []
power_words = []
words_to_avoid = []
transition_style = ""      # "none" | "subtle" | "explicit"
list_style = ""            # "bullets" | "numbers" | "prose" | "mixed"
social_proof_style = ""    # "testimonial_quotes" | "stats" | "logos" | "case_studies"
error_message_tone = ""    # "apologetic" | "helpful" | "casual" | "technical"
empty_state_tone = ""      # "encouraging" | "instructional" | "playful"

[imagery]
primary_style = ""         # "photography" | "illustration" | "3d" | "mixed" | "abstract"
photography_style = ""     # "editorial" | "lifestyle" | "product" | "documentary"
illustration_style = ""    # "flat" | "isometric" | "hand_drawn" | "geometric" | "line_art"
mood = ""                  # "bright_optimistic" | "dark_moody" | "warm_natural" | "cool_technical"
colour_treatment = ""      # "full_colour" | "muted" | "duotone" | "monochrome" | "brand_tinted"
subjects = []
composition_preference = "" # "centered" | "rule_of_thirds" | "asymmetric" | "full_bleed"
aspect_ratios
  hero = ""  card = ""  thumbnail = ""  social = ""
stock_vs_custom = ""       # "stock_only" | "custom_only" | "mixed" | "ai_generated"
filters = ""               # "none" | "warm_overlay" | "desaturated" | "high_contrast"
people_in_images = ""      # "always" | "sometimes" | "never" | "abstract_only"
diversity_requirements = ""

[iconography]
library = ""               # "lucide" | "heroicons" | "phosphor" | "tabler" | "custom"
style = ""                 # "outline" | "filled" | "duotone" | "solid"
stroke_width = ""
size_scale
  xs = ""  sm = ""  md = ""  lg = ""  xl = ""
corner_style = ""          # "rounded" | "sharp" | "mixed"
colour_usage = ""          # "monochrome" | "brand_colours" | "contextual"
animation = ""             # "none" | "hover_only" | "transition" | "micro_interaction"
fallback_library = ""
custom_icons = []

[buttons_and_forms]
button_variants
  primary
    background = ""  text_colour = ""  border_radius = ""  padding = ""
    font_weight = ""  shadow = ""  transition = ""
    hover_effect = ""  # "darken" | "lighten" | "scale" | "shadow" | "glow"
  secondary
    style = ""       # "outline" | "ghost" | "subtle" | "tonal"
  destructive
    style = ""  behaviour = ""
form_fields
  style = ""         # "outlined" | "filled" | "underlined" | "minimal"
  border_radius = ""  focus_ring = ""
  label_position = "" # "above" | "floating" | "inline" | "placeholder_only"
  validation_style = "" # "inline" | "tooltip" | "below_field" | "summary"
button_copy_patterns
  primary_cta = []  secondary_cta = []  destructive_cta = []  confirmation_cta = []
label_voice = ""   # "instructional" | "conversational" | "minimal"
label_examples
  do = []  dont = []
placeholder_style = "" # "example_data" | "instruction" | "none"
error_message_examples
  required = ""  invalid = ""  server = ""
success_message_style = "" # "celebratory" | "matter_of_fact" | "next_steps"

[media_and_motion]
animation_approach = ""    # "subtle" | "moderate" | "bold" | "none"
transition_timing = ""     # "fast" (150ms) | "normal" (300ms) | "slow" (500ms)
easing = ""                # "ease-out" | "spring" | "linear" | "custom"
loading_pattern = ""       # "skeleton" | "spinner" | "shimmer" | "progressive"
scroll_behaviour = ""      # "smooth" | "snap" | "parallax" | "none"
hover_interactions = ""    # "subtle_lift" | "colour_shift" | "scale" | "none"
page_transitions = ""      # "fade" | "slide" | "none" | "morph"
micro_interactions = []
video_style = ""           # "talking_head" | "screen_recording" | "animated" | "cinematic" | "mixed"
video_pacing = ""          # "fast_cuts" | "measured" | "documentary" | "energetic"
music_mood = ""            # "upbeat" | "ambient" | "corporate" | "none"
narration_style = ""       # "conversational" | "authoritative" | "storytelling" | "none"
narration_perspective = "" # "first_person" | "second_person" | "third_person"
sound_effects = ""         # "none" | "subtle" | "prominent"
video_intro_style = ""     # "logo_sting" | "cold_open" | "title_card" | "none"
video_outro_style = ""     # "cta_card" | "subscribe_prompt" | "fade_out" | "loop"

[brand_positioning]
# Spectrums 1-10
premium_vs_accessible = 0      # 1=budget, 10=luxury
playful_vs_serious = 0         # 1=casual, 10=corporate
innovative_vs_established = 0  # 1=cutting-edge, 10=traditional
minimal_vs_maximal = 0         # 1=stripped back, 10=feature-dense
technical_vs_simple = 0        # 1=consumer, 10=expert
global_vs_local = 0            # 1=hyper-local, 10=universal
tagline = ""
value_proposition = ""
competitive_differentiator = ""
target_audience = ""
audience_sophistication = ""   # "beginner" | "intermediate" | "expert" | "mixed"
industry = ""
desired_first_impression = ""
desired_trust_signals = []
brand_archetype = ""           # "creator" | "sage" | "explorer" | "hero"
```

## Agent Integration

Check `context/brand-identity.toon` before generating. All output must align — constraint, not suggestion.

| Agent type | Reads |
|---|---|
| Design | `visual_style`, `iconography`, `buttons_and_forms`, `media_and_motion`, `brand_positioning` |
| Content | `voice_and_tone`, `copywriting_patterns`, `buttons_and_forms`, `brand_positioning`, `imagery` |
| Production | `imagery`, `iconography`, `media_and_motion`, `brand_positioning`, `visual_style` |
| All | `brand_positioning` — shared axis keeping design and content aligned |

- **`content/humanise.md`**: Pass `voice_and_tone` to preserve brand personality during AI pattern removal.
- **`workflows/ui-verification.md`**: Brand identity adds constraints but never relaxes verification gates.

## Workflow: Create Brand Identity

**From scratch**: (1) Visual interview (`ui-ux-inspiration.md`) → UI style, palette, typography, patterns → `context/inspiration/`. (2) Verbal interview — voice adjectives, tone spectrums (1-10), CTA pairs, error tone, words to avoid. (3) Imagery/media — image style, people policy, icon library, animation, video style. (4) Brand positioning — walk each spectrum, derive positioning statement. (5) Synthesise into `context/brand-identity.toon`. Flag contradictions (e.g., "playful" voice + "corporate" positioning). Iterate until approved.

**From existing site**: (1) URL study (`ui-ux-inspiration.md`) → palette, typography, UI patterns, button/form styling, icon library. (2) Content analysis — read 5-10 pages, identify voice, CTA language, error messages, imagery. (3) Present findings as filled-in template. (4) Refine — what stays, what changes, what's missing. (5) Merge kept elements with new directions. Flag breaking changes (e.g., switching icon libraries).

## Relationship Map

`context/brand-identity.toon` is read by: `ui-ux-inspiration.md` (interview writes it), `content/guidelines.md` (structural rules; brand-identity provides voice), `content/platform-personas.md` (base voice + platform shifts), `content/production/image.md` (imagery → Nanobanana Pro params), `content/production/characters.md` (brand_positioning → character personality), `content/humanise.md` (voice_and_tone → preserve personality), `workflows/ui-verification.md` (adds constraints, never relaxes gates), `ui-ux-catalogue.toon` (catalogue provides options; identity records choices).

## File Locations

- **Template**: `.agents/tools/design/brand-identity.md` (this file — shared framework)
- **Per-project**: `context/brand-identity.toon`
- **Inspiration**: `context/inspiration/*.toon`
- **Style catalogue**: `.agents/tools/design/ui-ux-catalogue.toon`
- **Interview workflow**: `.agents/tools/design/ui-ux-inspiration.md`
