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

Per-project brand identity that bridges design agents and content agents. A designer picks "Glassmorphism + Trust Blue" -- this file ensures the copywriter knows that means "confident, technical, concise."

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Define per-project brand identity covering visual and verbal dimensions
- **Template**: `context/brand-identity.toon` in each project repo
- **Dimensions**: Visual style, voice & tone, copywriting patterns, imagery, iconography, buttons & forms, media & motion, brand positioning
- **Create from scratch**: Run style interview via `tools/design/ui-ux-inspiration.md`
- **Create from existing site**: Run URL study via `tools/design/ui-ux-inspiration.md`
- **Related**: `content/guidelines.md` (structural rules), `content/platform-personas.md` (channel adaptation), `content/production/image.md` (imagery params), `workflows/ui-verification.md` (quality gates)

**When to use**: Before any design or content work on a project. Check `context/brand-identity.toon` -- if missing, create one before proceeding.

<!-- AI-CONTEXT-END -->

## The Problem This Solves

Design and content agents operate independently. Without a shared brand definition:

- A designer picks colours and typography; the copywriter writes in a tone that doesn't match
- Button styling says "premium and restrained" but CTA copy says "GRAB IT NOW!!!"
- Image generation uses photorealistic style while the site uses flat illustrations
- Icon libraries get mixed (Lucide outline on one page, Heroicons filled on another)
- Brand decisions scatter across conversation history, lost between sessions

The brand identity file is the single source of truth. It lives in the project repo as `context/brand-identity.toon` and persists across sessions.

## Brand Identity Template

Each project gets a `context/brand-identity.toon` file covering 8 dimensions. The template below defines the schema -- each section maps to a TOON block.

### Dimension 1: Visual Style

The foundation -- UI style, colour palette, and typography that define the visual language.

```toon
[visual_style]
ui_style = ""              # From catalogue: Glassmorphism, Neubrutalism, etc.
ui_style_keywords = []     # CSS/design keywords for implementation
colour_palette_name = ""   # From catalogue or custom
colours
  primary = ""             # Hex, used for primary actions and brand elements
  secondary = ""           # Hex, supporting colour
  accent = ""              # Hex, highlights and interactive elements
  background = ""          # Hex, page/section backgrounds
  surface = ""             # Hex, cards, modals, elevated surfaces
  text_primary = ""        # Hex, body text
  text_secondary = ""      # Hex, secondary/muted text
  success = ""             # Hex, positive states
  warning = ""             # Hex, caution states
  error = ""               # Hex, error states
dark_mode = false          # Whether dark mode variant exists
dark_mode_strategy = ""    # "invert" | "separate_palette" | "dimmed"
typography
  heading_font = ""        # Font family for headings
  body_font = ""           # Font family for body text
  mono_font = ""           # Font family for code/technical
  heading_weight = ""      # e.g., "700" or "bold"
  body_weight = ""         # e.g., "400" or "regular"
  base_size = ""           # e.g., "16px" or "1rem"
  scale_ratio = ""         # e.g., "1.25" (Major Third)
  line_height = ""         # e.g., "1.6"
  letter_spacing = ""      # e.g., "normal" or "-0.02em"
border_radius = ""         # e.g., "8px", "full", "none"
spacing_unit = ""          # e.g., "4px", "0.25rem"
shadow_style = ""          # e.g., "subtle", "elevated", "flat", "layered"
```

### Dimension 2: Voice & Tone

The verbal personality -- how the brand sounds in writing.

```toon
[voice_and_tone]
register = ""              # "formal" | "casual" | "technical" | "conversational"
vocabulary_level = ""      # "simple" | "intermediate" | "advanced" | "technical"
sentence_style = ""        # "short_punchy" | "flowing" | "varied" | "academic"
personality_traits = []    # e.g., ["confident", "warm", "witty", "direct"]
humour = ""                # "none" | "dry" | "playful" | "self-deprecating"
perspective = ""           # "first_person_plural" | "first_person_singular" | "second_person" | "third_person"
formality_spectrum = ""    # 1-10 scale, 1=very casual, 10=very formal
emotional_range = ""       # "restrained" | "moderate" | "expressive"
jargon_policy = ""         # "avoid" | "define_on_first_use" | "assume_knowledge"
british_english = false    # Whether to use British spelling
brand_voice_examples
  do = []                  # Example phrases that sound like this brand
  dont = []                # Example phrases that do NOT sound like this brand
```

### Dimension 3: Copywriting Patterns

Specific writing rules -- how headlines, CTAs, and body copy are structured.

```toon
[copywriting_patterns]
headline_style = ""        # "question" | "statement" | "how_to" | "number" | "mixed"
headline_case = ""         # "sentence" | "title" | "lowercase"
headline_max_words = 0     # Maximum words in a headline
subheadline_style = ""     # "explanatory" | "benefit" | "action"
paragraph_length = ""      # "one_sentence" | "two_three_sentences" | "varied"
cta_language = ""          # "direct" | "benefit_led" | "urgency" | "conversational"
cta_examples = []          # e.g., ["Start building", "See how it works", "Try free"]
power_words = []           # Words that align with brand voice
words_to_avoid = []        # Words that clash with brand voice
transition_style = ""      # "none" | "subtle" | "explicit"
list_style = ""            # "bullets" | "numbers" | "prose" | "mixed"
social_proof_style = ""    # "testimonial_quotes" | "stats" | "logos" | "case_studies"
error_message_tone = ""    # "apologetic" | "helpful" | "casual" | "technical"
empty_state_tone = ""      # "encouraging" | "instructional" | "playful"
```

### Dimension 4: Imagery

Photography, illustration, and visual content direction.

```toon
[imagery]
primary_style = ""         # "photography" | "illustration" | "3d" | "mixed" | "abstract"
photography_style = ""     # "editorial" | "lifestyle" | "product" | "documentary"
illustration_style = ""    # "flat" | "isometric" | "hand_drawn" | "geometric" | "line_art"
mood = ""                  # "bright_optimistic" | "dark_moody" | "warm_natural" | "cool_technical"
colour_treatment = ""      # "full_colour" | "muted" | "duotone" | "monochrome" | "brand_tinted"
subjects = []              # e.g., ["people_working", "abstract_shapes", "product_screenshots"]
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

Icon library, style, and usage rules.

```toon
[iconography]
library = ""               # "lucide" | "heroicons" | "phosphor" | "tabler" | "custom"
style = ""                 # "outline" | "filled" | "duotone" | "solid"
stroke_width = ""          # e.g., "1.5px", "2px" (for outline icons)
size_scale
  xs = ""                  # e.g., "12px"
  sm = ""                  # e.g., "16px"
  md = ""                  # e.g., "20px"
  lg = ""                  # e.g., "24px"
  xl = ""                  # e.g., "32px"
corner_style = ""          # "rounded" | "sharp" | "mixed"
colour_usage = ""          # "monochrome" | "brand_colours" | "contextual"
animation = ""             # "none" | "hover_only" | "transition" | "micro_interaction"
fallback_library = ""      # Secondary library if primary lacks an icon
custom_icons = []          # List of custom icons not in the library
```

### Dimension 6: Buttons & Forms

Both visual styling AND verbal patterns for interactive elements.

```toon
[buttons_and_forms]
# Visual styling
button_variants
  primary
    background = ""        # Hex or gradient
    text_colour = ""       # Hex
    border_radius = ""     # e.g., "8px", "full"
    padding = ""           # e.g., "12px 24px"
    font_weight = ""       # e.g., "600"
    shadow = ""            # e.g., "0 2px 4px rgba(0,0,0,0.1)"
    hover_effect = ""      # "darken" | "lighten" | "scale" | "shadow" | "glow"
    transition = ""        # e.g., "all 150ms ease"
  secondary
    style = ""             # "outline" | "ghost" | "subtle" | "tonal"
  destructive
    style = ""             # How delete/danger actions look
form_fields
  style = ""               # "outlined" | "filled" | "underlined" | "minimal"
  border_radius = ""       # e.g., "6px"
  focus_ring = ""          # e.g., "2px solid primary" or "glow"
  label_position = ""      # "above" | "floating" | "inline" | "placeholder_only"
  validation_style = ""    # "inline" | "tooltip" | "below_field" | "summary"
# Verbal patterns -- CTA copy, labels, and error messages
button_copy_patterns
  primary_cta = []         # e.g., ["Get started", "Start free trial", "Create account"]
  secondary_cta = []       # e.g., ["Learn more", "See pricing", "View demo"]
  destructive_cta = []     # e.g., ["Delete account", "Remove", "Cancel plan"]
  confirmation_cta = []    # e.g., ["Yes, delete", "Confirm", "I understand"]
label_voice = ""           # "instructional" | "conversational" | "minimal"
label_examples
  do = []                  # e.g., ["Your email", "Company name"]
  dont = []                # e.g., ["Enter your email address here", "INPUT EMAIL"]
placeholder_style = ""     # "example_data" | "instruction" | "none"
error_message_examples
  required = ""            # e.g., "Please enter your email" vs "Email is required"
  invalid = ""             # e.g., "That doesn't look like an email" vs "Invalid email format"
  server = ""              # e.g., "Something went wrong. Try again?" vs "Error 500"
success_message_style = "" # "celebratory" | "matter_of_fact" | "next_steps"
```

### Dimension 7: Media & Motion

Video, animation, and dynamic content direction.

```toon
[media_and_motion]
# Visual motion
animation_approach = ""    # "subtle" | "moderate" | "bold" | "none"
transition_timing = ""     # "fast" (150ms) | "normal" (300ms) | "slow" (500ms)
easing = ""                # "ease-out" | "spring" | "linear" | "custom"
loading_pattern = ""       # "skeleton" | "spinner" | "shimmer" | "progressive"
scroll_behaviour = ""      # "smooth" | "snap" | "parallax" | "none"
hover_interactions = ""    # "subtle_lift" | "colour_shift" | "scale" | "none"
page_transitions = ""     # "fade" | "slide" | "none" | "morph"
micro_interactions = []    # e.g., ["button_press", "toggle_switch", "form_success"]
# Video and audio
video_style = ""           # "talking_head" | "screen_recording" | "animated" | "cinematic" | "mixed"
video_pacing = ""          # "fast_cuts" | "measured" | "documentary" | "energetic"
music_mood = ""            # "upbeat" | "ambient" | "corporate" | "none" | "genre_specific"
narration_style = ""       # "conversational" | "authoritative" | "storytelling" | "none"
narration_perspective = "" # "first_person" | "second_person" | "third_person"
sound_effects = ""         # "none" | "subtle" | "prominent"
video_intro_style = ""     # "logo_sting" | "cold_open" | "title_card" | "none"
video_outro_style = ""     # "cta_card" | "subscribe_prompt" | "fade_out" | "loop"
```

### Dimension 8: Brand Positioning

The shared axis that aligns design and content -- where the brand sits on key spectrums.

```toon
[brand_positioning]
# Each value is a position on a spectrum (1-10)
premium_vs_accessible = 0      # 1=budget-friendly, 10=luxury
playful_vs_serious = 0         # 1=fun and casual, 10=corporate and serious
innovative_vs_established = 0  # 1=cutting-edge, 10=trusted and traditional
minimal_vs_maximal = 0         # 1=stripped back, 10=feature-rich and dense
technical_vs_simple = 0        # 1=consumer-friendly, 10=developer/expert
global_vs_local = 0            # 1=hyper-local, 10=global/universal
# Positioning statement
tagline = ""                   # One-line brand promise
value_proposition = ""         # What you do, for whom, why it matters
competitive_differentiator = "" # What makes you different from alternatives
target_audience = ""           # Primary audience description
audience_sophistication = ""   # "beginner" | "intermediate" | "expert" | "mixed"
industry = ""                  # e.g., "developer_tools", "healthcare", "ecommerce"
# Emotional targets
desired_first_impression = ""  # What someone should feel in the first 5 seconds
desired_trust_signals = []     # e.g., ["social_proof", "certifications", "transparency"]
brand_archetype = ""           # e.g., "creator", "sage", "explorer", "hero"
```

## Agent Integration

Every agent that produces design or content output must check for `context/brand-identity.toon` before generating. If present, all output must align. This is not optional guidance -- it is a constraint.

### Design Agents

Design agents (UI implementation, component design, layout) read these sections:

| Section | What it controls |
|---------|-----------------|
| `visual_style` | Colour palette, typography, border radius, shadows, spacing |
| `iconography` | Icon library, style, sizing, animation |
| `buttons_and_forms` | Button variants, form field styling, focus states, validation |
| `media_and_motion` | Animation approach, transitions, hover effects, loading patterns |
| `brand_positioning` | Premium vs accessible, minimal vs maximal (affects density and whitespace) |

**Integration rule for design agents**: Before generating any UI component, read `context/brand-identity.toon`. Extract `visual_style`, `iconography`, and `buttons_and_forms`. Apply these as hard constraints -- not suggestions. If the brand identity specifies `border_radius = "full"`, every button and input uses full rounding. No exceptions without explicit user override.

Also check `context/inspiration/` for project-specific design patterns extracted from studied URLs. These provide concrete visual references that complement the abstract brand identity.

### Content Agents

Content agents (copywriting, blog posts, social media, email) read these sections:

| Section | What it controls |
|---------|-----------------|
| `voice_and_tone` | Register, vocabulary, personality, humour, perspective |
| `copywriting_patterns` | Headlines, CTAs, paragraph structure, power words, error messages |
| `buttons_and_forms` | CTA button copy, label voice, error message tone, placeholder style |
| `brand_positioning` | Audience sophistication, formality level, emotional targets |
| `imagery` | Image subjects and mood (for image selection in content) |

**Integration rule for content agents**: Before writing any copy, read `context/brand-identity.toon`. Extract `voice_and_tone` and `copywriting_patterns`. These override the defaults in `content/guidelines.md`. When a brand identity is present, `guidelines.md` provides structural rules (paragraph length, HTML formatting, SEO bolding) while `brand-identity.toon` provides the voice. When no brand identity exists, `guidelines.md` is the sole authority.

### Production Agents

Production agents (image generation, video, audio, character design) read these sections:

| Section | What it controls |
|---------|-----------------|
| `imagery` | Photography vs illustration, mood, colour treatment, composition |
| `iconography` | Icon style for any generated graphics containing icons |
| `media_and_motion` | Video style, pacing, music mood, narration |
| `brand_positioning` | Premium vs accessible, playful vs serious (affects visual tone) |
| `visual_style` | Colour palette (for brand-consistent image generation) |

**Integration rule for production agents**: Before generating any visual or video asset, read `context/brand-identity.toon`. Extract `imagery` and `visual_style.colours`. Pass the colour palette as constraints to image generation tools (see `content/production/image.md` for Nanobanana Pro JSON schema -- map brand colours to the `color.palette` field). For character design, also read `brand_positioning` to align character personality with brand archetype (see `content/production/characters.md`).

### All Agents

Every agent reads `brand_positioning` -- it is the shared axis that keeps design and content aligned. A brand positioned at `premium_vs_accessible = 9` and `playful_vs_serious = 8` demands both restrained visual design AND formal, confident copy. Neither side can deviate independently.

**Relationship to `content/humanise.md`**: The humanise agent removes AI writing patterns but must respect the brand voice. If the brand identity specifies `humour = "dry"` and `personality_traits = ["witty"]`, humanise should preserve wit rather than flattening to neutral. Pass the `voice_and_tone` section to humanise as context.

**Relationship to `workflows/ui-verification.md`**: UI verification quality gates always apply regardless of brand identity. Brand identity adds constraints on top (e.g., "all buttons must use the primary colour") but never relaxes verification requirements. The verification workflow checks that implemented UI matches the brand identity when one exists.

## Workflow: Create Brand Identity from Scratch

When a project has no `context/brand-identity.toon`, create one before starting design or content work.

### Step 1: Visual Identity Interview

Run the style interview from `tools/design/ui-ux-inspiration.md`. This presents UI styles from the catalogue (`tools/design/ui-ux-catalogue.toon`), asks the user to share sites they like, and extracts visual patterns.

The interview produces:

- Preferred UI style (or combination)
- Colour palette (from catalogue or custom)
- Typography pairing
- Imagery direction
- Extracted patterns from reference sites (saved to `context/inspiration/`)

### Step 2: Verbal Identity Interview

After visual identity is established, interview the user on verbal identity:

1. **Voice**: "How should your brand sound? Pick 3-5 adjectives." Show examples:
   - Confident and direct (Stripe)
   - Warm and encouraging (Notion)
   - Technical and precise (Vercel)
   - Playful and irreverent (Slack)
   - Authoritative and trustworthy (IBM)

2. **Tone spectrum**: "On a scale of 1-10, where does your brand sit?"
   - Casual (1) -------- Formal (10)
   - Playful (1) -------- Serious (10)
   - Simple (1) -------- Technical (10)

3. **CTA style**: Show pairs and ask which feels right:
   - "Get started" vs "Begin your journey"
   - "Try free" vs "Start your free trial"
   - "Learn more" vs "Discover how it works"
   - "Sign up" vs "Create your account"
   - "Buy now" vs "Add to cart"

4. **Error messages**: "When something goes wrong, how should your product respond?"
   - "Oops! That didn't work. Try again?" (casual)
   - "We couldn't process your request. Please try again." (neutral)
   - "Request failed. Check your input and retry." (technical)

5. **Words to avoid**: "Any words or phrases that feel wrong for your brand?"

### Step 3: Imagery and Media Interview

1. **Image style**: Show examples of photography, illustration, 3D, and abstract. Ask preference.
2. **People in images**: "Should your visuals include people? Always, sometimes, never?"
3. **Icon library**: Present options (Lucide, Heroicons, Phosphor, Tabler) with visual samples.
4. **Animation**: "How much motion? Subtle and functional, or bold and expressive?"
5. **Video**: "If you make videos, what style? Talking head, screen recording, animated, cinematic?"

### Step 4: Brand Positioning

Walk through the positioning spectrums:

1. Present each spectrum with examples at each end
2. Ask the user to place their brand on each scale
3. Derive the positioning statement from the answers

### Step 5: Generate and Review

1. Synthesise all interview answers into a `context/brand-identity.toon` file
2. Present the complete file to the user for review
3. Highlight any internal contradictions (e.g., "playful" voice with "corporate" positioning)
4. Iterate until the user approves
5. Save to the project's `context/brand-identity.toon`

## Workflow: Brand Identity from Existing Site

When rebranding or extending an existing project, extract the current identity first.

### Step 1: URL Study

Run the URL study workflow from `tools/design/ui-ux-inspiration.md` on the existing site. This extracts:

- Current colour palette (from CSS/computed styles)
- Typography (font families, sizes, weights)
- UI patterns (border radius, shadows, spacing)
- Button and form styling
- Icon library in use
- Animation and transition patterns

### Step 2: Content Analysis

Analyse existing copy on the site:

1. Read 5-10 pages of existing content
2. Identify voice patterns: formal/casual, technical/simple, personality traits
3. Catalogue CTA language across buttons and links
4. Note error messages, empty states, and form labels
5. Identify imagery style (photography, illustration, stock, custom)

### Step 3: Present Findings

Show the user what their current brand identity looks like as a filled-in template:

- "Here's your current visual identity based on what's live on your site"
- "Here's how your copy currently sounds"
- "Here are the patterns I found in your CTAs and error messages"

### Step 4: Refine

Ask the user:

1. "What should stay the same?"
2. "What should change?"
3. "What's missing that you want to add?"
4. "Are there new directions you want to explore?"

### Step 5: Generate Updated Identity

1. Merge kept elements with new directions
2. Generate the updated `context/brand-identity.toon`
3. Flag any breaking changes (e.g., switching icon libraries means updating every icon)
4. Save to the project's `context/brand-identity.toon`

## Relationship Map

How `context/brand-identity.toon` connects to existing agents:

```text
context/brand-identity.toon (per-project)
    |
    |-- read by: tools/design/ui-ux-inspiration.md
    |     Design decisions reference brand identity for consistency.
    |     The interview workflow WRITES this file; subsequent design
    |     work READS it.
    |
    |-- read by: content/guidelines.md
    |     When brand identity exists: guidelines.md provides structural
    |     rules (paragraph length, HTML formatting, SEO bolding).
    |     Brand-identity.toon provides the voice.
    |     When no brand identity: guidelines.md is sole authority.
    |
    |-- read by: content/platform-personas.md
    |     Reads brand-identity.toon for the base voice, then applies
    |     platform-specific shifts (LinkedIn = more formal, Instagram =
    |     more casual). Replaces the previous context/brand-voice.md
    |     reference.
    |
    |-- read by: content/production/image.md
    |     Reads imagery and visual_style sections. Maps brand colours
    |     to Nanobanana Pro JSON color.palette field. Uses imagery.mood
    |     for lighting and style parameters.
    |
    |-- read by: content/production/characters.md
    |     Reads brand_positioning and imagery for character design
    |     alignment. Brand archetype informs character personality.
    |
    |-- read by: content/humanise.md
    |     Receives voice_and_tone as context. Preserves brand
    |     personality traits during AI pattern removal instead of
    |     flattening to neutral.
    |
    |-- read by: workflows/ui-verification.md
    |     Quality gates always apply. Brand identity adds constraints
    |     (colour consistency, icon library, typography) but never
    |     relaxes verification requirements.
    |
    |-- read by: tools/design/ui-ux-catalogue.toon
    |     Catalogue provides the style/palette/typography options.
    |     Brand identity records which options were chosen.
```

## Example: Complete Brand Identity

A fictional SaaS product -- "Launchpad" -- a developer tool for deploying side projects.

```toon
# Brand Identity: Launchpad
# Developer tool for deploying side projects
# Created: 2026-03-01
# Last updated: 2026-03-01

[visual_style]
ui_style = "Clean Minimal"
ui_style_keywords = ["whitespace", "clear-hierarchy", "functional", "modern"]
colour_palette_name = "Developer Calm"
colours
  primary = "#6366F1"          # Indigo -- primary actions, brand mark
  secondary = "#0EA5E9"        # Sky blue -- secondary elements, links
  accent = "#F59E0B"           # Amber -- highlights, notifications, badges
  background = "#FAFAFA"       # Near-white -- page background
  surface = "#FFFFFF"          # White -- cards, modals
  text_primary = "#18181B"     # Near-black -- body text
  text_secondary = "#71717A"   # Zinc -- secondary text, captions
  success = "#22C55E"          # Green -- deploy success, positive states
  warning = "#F59E0B"          # Amber -- build warnings
  error = "#EF4444"            # Red -- deploy failures, errors
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
formality_spectrum = "4"
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
    style = "red background, white text, confirm before action"
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
  dont = ["Please enter your project name", "SELECT A REGION", "Type your build command here"]
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

- **Template definition**: `.agents/tools/design/brand-identity.md` (this file -- shared framework)
- **Per-project identity**: `context/brand-identity.toon` (in each project repo)
- **Inspiration patterns**: `context/inspiration/*.toon` (in each project repo)
- **Style catalogue**: `.agents/tools/design/ui-ux-catalogue.toon` (shared framework)
- **Interview workflow**: `.agents/tools/design/ui-ux-inspiration.md` (shared framework)
