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

Per-project brand identity that bridges design agents and content agents. A designer picks "Glassmorphism + Trust Blue" — this file ensures the copywriter knows that means "confident, technical, concise."

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Define per-project brand identity covering visual and verbal dimensions
- **Template**: `context/brand-identity.toon` in each project repo
- **Dimensions**: Visual style, voice & tone, copywriting patterns, imagery, iconography, buttons & forms, media & motion, brand positioning
- **Create from scratch**: Run style interview via `tools/design/ui-ux-inspiration.md`
- **Create from existing site**: Run URL study via `tools/design/ui-ux-inspiration.md`
- **Related**: `content/guidelines.md` (structural rules), `content/platform-personas.md` (channel adaptation), `content/production/image.md` (imagery params), `workflows/ui-verification.md` (quality gates)

**When to use**: Before any design or content work on a project. Check `context/brand-identity.toon` — if missing, create one before proceeding.

<!-- AI-CONTEXT-END -->

## The Problem This Solves

Without a shared brand definition: designers and copywriters produce mismatched output; button styling says "premium" but CTA copy says "GRAB IT NOW!!!"; image generation uses photorealistic style while the site uses flat illustrations; icon libraries get mixed; brand decisions scatter across conversation history. The brand identity file is the single source of truth, persisting across sessions in `context/brand-identity.toon`.

## Brand Identity Template

Each project gets a `context/brand-identity.toon` file covering 8 dimensions.

### Dimension 1: Visual Style

```toon
[visual_style]
ui_style = ""              # From catalogue: Glassmorphism, Neubrutalism, etc.
ui_style_keywords = []     # CSS/design keywords for implementation
colour_palette_name = ""
colours
  primary = ""             # Hex, primary actions and brand elements
  secondary = ""           # Hex, supporting colour
  accent = ""              # Hex, highlights and interactive elements
  background = ""          # Hex, page/section backgrounds
  surface = ""             # Hex, cards, modals, elevated surfaces
  text_primary = ""        # Hex, body text
  text_secondary = ""      # Hex, secondary/muted text
  success = ""             # Hex, positive states
  warning = ""             # Hex, caution states
  error = ""               # Hex, error states
dark_mode = false
dark_mode_strategy = ""    # "invert" | "separate_palette" | "dimmed"
typography
  heading_font = ""
  body_font = ""
  mono_font = ""
  heading_weight = ""      # e.g., "700"
  body_weight = ""         # e.g., "400"
  base_size = ""           # e.g., "16px"
  scale_ratio = ""         # e.g., "1.25" (Major Third)
  line_height = ""         # e.g., "1.6"
  letter_spacing = ""      # e.g., "normal" or "-0.02em"
border_radius = ""         # e.g., "8px", "full", "none"
spacing_unit = ""          # e.g., "4px"
shadow_style = ""          # e.g., "subtle", "elevated", "flat", "layered"
```

### Dimension 2: Voice & Tone

```toon
[voice_and_tone]
register = ""              # "formal" | "casual" | "technical" | "conversational"
vocabulary_level = ""      # "simple" | "intermediate" | "advanced" | "technical"
sentence_style = ""        # "short_punchy" | "flowing" | "varied" | "academic"
personality_traits = []    # e.g., ["confident", "warm", "witty", "direct"]
humour = ""                # "none" | "dry" | "playful" | "self-deprecating"
perspective = ""           # "first_person_plural" | "first_person_singular" | "second_person" | "third_person"
formality_spectrum = 0     # 1-10 scale, 1=very casual, 10=very formal
emotional_range = ""       # "restrained" | "moderate" | "expressive"
jargon_policy = ""         # "avoid" | "define_on_first_use" | "assume_knowledge"
british_english = false
brand_voice_examples
  do = []                  # Example phrases that sound like this brand
  dont = []                # Example phrases that do NOT sound like this brand
```

### Dimension 3: Copywriting Patterns

```toon
[copywriting_patterns]
headline_style = ""        # "question" | "statement" | "how_to" | "number" | "mixed"
headline_case = ""         # "sentence" | "title" | "lowercase"
headline_max_words = 0
subheadline_style = ""     # "explanatory" | "benefit" | "action"
paragraph_length = ""      # "one_sentence" | "two_three_sentences" | "varied"
cta_language = ""          # "direct" | "benefit_led" | "urgency" | "conversational"
cta_examples = []          # e.g., ["Start building", "See how it works", "Try free"]
power_words = []
words_to_avoid = []
transition_style = ""      # "none" | "subtle" | "explicit"
list_style = ""            # "bullets" | "numbers" | "prose" | "mixed"
social_proof_style = ""    # "testimonial_quotes" | "stats" | "logos" | "case_studies"
error_message_tone = ""    # "apologetic" | "helpful" | "casual" | "technical"
empty_state_tone = ""      # "encouraging" | "instructional" | "playful"
```

### Dimension 4: Imagery

```toon
[imagery]
primary_style = ""         # "photography" | "illustration" | "3d" | "mixed" | "abstract"
photography_style = ""     # "editorial" | "lifestyle" | "product" | "documentary"
illustration_style = ""    # "flat" | "isometric" | "hand_drawn" | "geometric" | "line_art"
mood = ""                  # "bright_optimistic" | "dark_moody" | "warm_natural" | "cool_technical"
colour_treatment = ""      # "full_colour" | "muted" | "duotone" | "monochrome" | "brand_tinted"
subjects = []
composition_preference = "" # "centered" | "rule_of_thirds" | "asymmetric" | "full_bleed"
aspect_ratios
  hero = ""                # e.g., "16:9"
  card = ""                # e.g., "4:3"
  thumbnail = ""           # e.g., "1:1"
  social = ""              # e.g., "1.91:1"
stock_vs_custom = ""       # "stock_only" | "custom_only" | "mixed" | "ai_generated"
filters = ""               # "none" | "warm_overlay" | "desaturated" | "high_contrast"
people_in_images = ""      # "always" | "sometimes" | "never" | "abstract_only"
diversity_requirements = "" # "representative" | "industry_specific" | "not_applicable"
```

### Dimension 5: Iconography

```toon
[iconography]
library = ""               # "lucide" | "heroicons" | "phosphor" | "tabler" | "custom"
style = ""                 # "outline" | "filled" | "duotone" | "solid"
stroke_width = ""          # e.g., "1.5px", "2px"
size_scale
  xs = ""                  # e.g., "12px"
  sm = ""                  # e.g., "16px"
  md = ""                  # e.g., "20px"
  lg = ""                  # e.g., "24px"
  xl = ""                  # e.g., "32px"
corner_style = ""          # "rounded" | "sharp" | "mixed"
colour_usage = ""          # "monochrome" | "brand_colours" | "contextual"
animation = ""             # "none" | "hover_only" | "transition" | "micro_interaction"
fallback_library = ""
custom_icons = []
```

### Dimension 6: Buttons & Forms

```toon
[buttons_and_forms]
button_variants
  primary
    background = ""        # Hex or gradient
    text_colour = ""
    border_radius = ""     # e.g., "8px", "full"
    padding = ""           # e.g., "12px 24px"
    font_weight = ""       # e.g., "600"
    shadow = ""
    hover_effect = ""      # "darken" | "lighten" | "scale" | "shadow" | "glow"
    transition = ""        # e.g., "all 150ms ease"
  secondary
    style = ""             # "outline" | "ghost" | "subtle" | "tonal"
  destructive
    style = ""
    behaviour = ""         # e.g., "confirm before action"
form_fields
  style = ""               # "outlined" | "filled" | "underlined" | "minimal"
  border_radius = ""
  focus_ring = ""          # e.g., "2px solid primary"
  label_position = ""      # "above" | "floating" | "inline" | "placeholder_only"
  validation_style = ""    # "inline" | "tooltip" | "below_field" | "summary"
button_copy_patterns
  primary_cta = []         # e.g., ["Get started", "Start free trial"]
  secondary_cta = []       # e.g., ["Learn more", "See pricing"]
  destructive_cta = []     # e.g., ["Delete account", "Remove"]
  confirmation_cta = []    # e.g., ["Yes, delete", "Confirm"]
label_voice = ""           # "instructional" | "conversational" | "minimal"
label_examples
  do = []                  # e.g., ["Your email", "Company name"]
  dont = []                # e.g., ["Enter your email address here"]
placeholder_style = ""     # "example_data" | "instruction" | "none"
error_message_examples
  required = ""
  invalid = ""
  server = ""
success_message_style = "" # "celebratory" | "matter_of_fact" | "next_steps"
```

### Dimension 7: Media & Motion

```toon
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
```

### Dimension 8: Brand Positioning

```toon
[brand_positioning]
# Each value is a position on a spectrum (1-10)
premium_vs_accessible = 0      # 1=budget-friendly, 10=luxury
playful_vs_serious = 0         # 1=fun and casual, 10=corporate and serious
innovative_vs_established = 0  # 1=cutting-edge, 10=trusted and traditional
minimal_vs_maximal = 0         # 1=stripped back, 10=feature-rich and dense
technical_vs_simple = 0        # 1=consumer-friendly, 10=developer/expert
global_vs_local = 0            # 1=hyper-local, 10=global/universal
tagline = ""
value_proposition = ""
competitive_differentiator = ""
target_audience = ""
audience_sophistication = ""   # "beginner" | "intermediate" | "expert" | "mixed"
industry = ""
desired_first_impression = ""
desired_trust_signals = []
brand_archetype = ""           # e.g., "creator", "sage", "explorer", "hero"
```

## Agent Integration

Every agent that produces design or content output must check for `context/brand-identity.toon` before generating. If present, all output must align. This is not optional guidance — it is a constraint.

### Design Agents

Read `visual_style`, `iconography`, `buttons_and_forms`, `media_and_motion`, `brand_positioning`. Apply as hard constraints — not suggestions. If `border_radius = "full"`, every button and input uses full rounding. Also check `context/inspiration/` for project-specific design patterns.

### Content Agents

Read `voice_and_tone`, `copywriting_patterns`, `buttons_and_forms`, `brand_positioning`, `imagery`. These override defaults in `content/guidelines.md`. When brand identity is present, `guidelines.md` provides structural rules; `brand-identity.toon` provides the voice.

### Production Agents

Read `imagery`, `iconography`, `media_and_motion`, `brand_positioning`, `visual_style`. Pass colour palette as constraints to image generation tools (see `content/production/image.md` for Nanobanana Pro JSON schema). For character design, read `brand_positioning` to align character personality with brand archetype.

### All Agents

Every agent reads `brand_positioning` — it is the shared axis that keeps design and content aligned. A brand at `premium_vs_accessible = 9` and `playful_vs_serious = 8` demands both restrained visual design AND formal, confident copy.

**Relationship to `content/humanise.md`**: Pass `voice_and_tone` as context. Preserves brand personality traits during AI pattern removal instead of flattening to neutral.

**Relationship to `workflows/ui-verification.md`**: Brand identity adds constraints (colour consistency, icon library, typography) but never relaxes verification requirements.

## Workflow: Create Brand Identity

### From Scratch

1. **Visual identity interview** — Run style interview from `tools/design/ui-ux-inspiration.md`. Produces: preferred UI style, colour palette, typography pairing, imagery direction, extracted patterns from reference sites (saved to `context/inspiration/`).

2. **Verbal identity interview** — Ask: voice adjectives (3-5), tone spectrum (1-10 scales for casual/formal, playful/serious, simple/technical), CTA style pairs ("Get started" vs "Begin your journey"), error message tone (casual/neutral/technical), words to avoid.

3. **Imagery and media interview** — Image style (photography/illustration/3D/abstract), people in images, icon library (show visual samples of Lucide/Heroicons/Phosphor/Tabler), animation level, video style.

4. **Brand positioning** — Walk through each spectrum with examples at each end. Derive positioning statement from answers.

5. **Generate and review** — Synthesise into `context/brand-identity.toon`. Highlight internal contradictions (e.g., "playful" voice with "corporate" positioning). Iterate until approved.

### From Existing Site

1. **URL study** — Run URL study from `tools/design/ui-ux-inspiration.md`. Extracts: colour palette, typography, UI patterns, button/form styling, icon library, animation patterns.

2. **Content analysis** — Read 5-10 pages. Identify voice patterns, CTA language, error messages, imagery style.

3. **Present findings** — Show current brand identity as a filled-in template: "Here's your current visual identity / how your copy sounds / patterns in your CTAs."

4. **Refine** — Ask: what should stay, what should change, what's missing, new directions?

5. **Generate updated identity** — Merge kept elements with new directions. Flag breaking changes (e.g., switching icon libraries means updating every icon).

## Relationship Map

```text
context/brand-identity.toon (per-project)
    |-- read by: tools/design/ui-ux-inspiration.md (interview WRITES, design work READS)
    |-- read by: content/guidelines.md (structural rules; brand-identity.toon provides voice)
    |-- read by: content/platform-personas.md (base voice + platform-specific shifts)
    |-- read by: content/production/image.md (imagery + visual_style → Nanobanana Pro params)
    |-- read by: content/production/characters.md (brand_positioning → character personality)
    |-- read by: content/humanise.md (voice_and_tone → preserve personality, not flatten)
    |-- read by: workflows/ui-verification.md (brand identity adds constraints, never relaxes gates)
    |-- read by: tools/design/ui-ux-catalogue.toon (catalogue provides options; identity records choices)
```

## Example: Complete Brand Identity

A fictional SaaS product — "Launchpad" — a developer tool for deploying side projects.

```toon
# Brand Identity: Launchpad
# Developer tool for deploying side projects

[visual_style]
ui_style = "Clean Minimal"
ui_style_keywords = ["whitespace", "clear-hierarchy", "functional", "modern"]
colour_palette_name = "Developer Calm"
colours
  primary = "#6366F1"          # Indigo
  secondary = "#0EA5E9"        # Sky blue
  accent = "#F59E0B"           # Amber
  background = "#FAFAFA"
  surface = "#FFFFFF"
  text_primary = "#18181B"
  text_secondary = "#71717A"
  success = "#22C55E"
  warning = "#F59E0B"
  error = "#EF4444"
dark_mode = true
dark_mode_strategy = "separate_palette"
typography
  heading_font = "Inter"
  body_font = "Inter"
  mono_font = "JetBrains Mono"
  heading_weight = "600"
  body_weight = "400"
  base_size = "16px"
  scale_ratio = "1.25"
  line_height = "1.6"
  letter_spacing = "-0.01em"
border_radius = "8px"
spacing_unit = "4px"
shadow_style = "subtle"

[voice_and_tone]
register = "conversational"
vocabulary_level = "technical"
sentence_style = "short_punchy"
personality_traits = ["confident", "direct", "slightly_irreverent", "helpful"]
humour = "dry"
perspective = "first_person_plural"
formality_spectrum = 4
emotional_range = "moderate"
jargon_policy = "assume_knowledge"
british_english = false
brand_voice_examples
  do = ["Ship it.", "Your deploy is live. Took 11 seconds.", "Something broke. Here's what happened.", "Zero config. Seriously."]
  dont = ["We are delighted to inform you that your deployment has been successfully completed.", "Oopsie! Looks like something went wrong!", "Leverage our cutting-edge platform to streamline your workflow."]

[copywriting_patterns]
headline_style = "statement"
headline_case = "sentence"
headline_max_words = 8
subheadline_style = "benefit"
paragraph_length = "one_sentence"
cta_language = "direct"
cta_examples = ["Deploy now", "Start building", "View logs", "Try free"]
power_words = ["ship", "deploy", "build", "launch", "fast", "simple", "zero-config"]
words_to_avoid = ["leverage", "synergy", "cutting-edge", "revolutionary", "delighted", "excited to announce", "streamline"]
transition_style = "none"
list_style = "bullets"
social_proof_style = "stats"
error_message_tone = "helpful"
empty_state_tone = "encouraging"

[imagery]
primary_style = "mixed"
photography_style = "editorial"
illustration_style = "geometric"
mood = "cool_technical"
colour_treatment = "brand_tinted"
subjects = ["terminal_screenshots", "code_snippets", "abstract_geometry", "developer_workspaces"]
composition_preference = "asymmetric"
aspect_ratios
  hero = "16:9"
  card = "4:3"
  thumbnail = "1:1"
  social = "1.91:1"
stock_vs_custom = "ai_generated"
filters = "none"
people_in_images = "sometimes"
diversity_requirements = "representative"

[iconography]
library = "lucide"
style = "outline"
stroke_width = "1.5px"
size_scale
  xs = "14px"
  sm = "16px"
  md = "20px"
  lg = "24px"
  xl = "32px"
corner_style = "rounded"
colour_usage = "monochrome"
animation = "hover_only"
fallback_library = "heroicons"
custom_icons = ["launchpad-logo", "deploy-rocket"]

[buttons_and_forms]
button_variants
  primary
    background = "#6366F1"
    text_colour = "#FFFFFF"
    border_radius = "8px"
    padding = "10px 20px"
    font_weight = "500"
    shadow = "0 1px 2px rgba(0,0,0,0.05)"
    hover_effect = "darken"
    transition = "all 150ms ease"
  secondary
    style = "outline"
  destructive
    style = "red background, white text"
    behaviour = "confirm before action"
form_fields
  style = "outlined"
  border_radius = "6px"
  focus_ring = "2px solid #6366F1"
  label_position = "above"
  validation_style = "below_field"
button_copy_patterns
  primary_cta = ["Deploy now", "Start building", "Create project"]
  secondary_cta = ["View docs", "See examples", "Compare plans"]
  destructive_cta = ["Delete project", "Remove", "Disconnect"]
  confirmation_cta = ["Yes, delete", "Confirm", "I understand"]
label_voice = "minimal"
label_examples
  do = ["Project name", "Region", "Build command"]
  dont = ["Please enter your project name", "SELECT A REGION"]
placeholder_style = "example_data"
error_message_examples
  required = "Project name is required"
  invalid = "That doesn't look right. Check the format."
  server = "Deploy failed. Check the build logs for details."
success_message_style = "matter_of_fact"

[media_and_motion]
animation_approach = "subtle"
transition_timing = "fast"
easing = "ease-out"
loading_pattern = "skeleton"
scroll_behaviour = "smooth"
hover_interactions = "subtle_lift"
page_transitions = "fade"
micro_interactions = ["button_press", "deploy_progress", "log_stream"]
video_style = "screen_recording"
video_pacing = "fast_cuts"
music_mood = "ambient"
narration_style = "conversational"
narration_perspective = "second_person"
sound_effects = "none"
video_intro_style = "cold_open"
video_outro_style = "cta_card"

[brand_positioning]
premium_vs_accessible = 4
playful_vs_serious = 4
innovative_vs_established = 3
minimal_vs_maximal = 3
technical_vs_simple = 7
global_vs_local = 8
tagline = "Ship your side project. Tonight."
value_proposition = "Deploy any framework to production in under a minute. No config files, no DevOps degree required."
competitive_differentiator = "Zero-config deploys that actually work. No YAML, no Dockerfiles, no 47-step tutorials."
target_audience = "Independent developers and small teams shipping side projects, MVPs, and internal tools"
audience_sophistication = "intermediate"
industry = "developer_tools"
desired_first_impression = "This is fast, simple, and built by people who actually ship code"
desired_trust_signals = ["deploy_count_stats", "uptime_percentage", "open_source_components"]
brand_archetype = "creator"
```

## File Location and Naming

- **Template definition**: `.agents/tools/design/brand-identity.md` (this file — shared framework)
- **Per-project identity**: `context/brand-identity.toon` (in each project repo)
- **Inspiration patterns**: `context/inspiration/*.toon` (in each project repo)
- **Style catalogue**: `.agents/tools/design/ui-ux-catalogue.toon` (shared framework)
- **Interview workflow**: `.agents/tools/design/ui-ux-inspiration.md` (shared framework)
