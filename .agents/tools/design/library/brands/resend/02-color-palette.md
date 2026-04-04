# Design System: Resend — Color Palette & Roles

## Primary

- **Void Black** (`#000000`): Page background, the defining canvas color (95% opacity via `--color-black-12`)
- **Near White** (`#f0f0f0`): Primary text, button text, high-contrast elements
- **Pure White** (`#ffffff`): `--color-white`, maximum emphasis text, link highlights

## Accent Scale — Orange

- **Orange 4** (`#ff5900`): `--color-orange-4`, at 22% opacity — subtle warm glow
- **Orange 10** (`#ff801f`): `--color-orange-10`, primary orange accent — warm, energetic
- **Orange 11** (`#ffa057`): `--color-orange-11`, lighter orange for secondary use

## Accent Scale — Green

- **Green 3** (`#22ff99`): `--color-green-3`, at 12% opacity — faint emerald wash
- **Green 4** (`#11ff99`): `--color-green-4`, at 18% opacity — success indicator glow

## Accent Scale — Blue

- **Blue 4** (`#0075ff`): `--color-blue-4`, at 34% opacity — medium blue accent
- **Blue 5** (`#0081fd`): `--color-blue-5`, at 42% opacity — stronger blue
- **Blue 10** (`#3b9eff`): `--color-blue-10`, bright blue — links, interactive elements

## Accent Scale — Other

- **Yellow 9** (`#ffc53d`): `--color-yellow-9`, warm gold for warnings or highlights
- **Red 5** (`#ff2047`): `--color-red-5`, at 34% opacity — error states, destructive actions

## Neutral Scale

- **Silver** (`#a1a4a5`): Secondary text, muted links, descriptions
- **Dark Gray** (`#464a4d`): Tertiary text, de-emphasized content
- **Mid Gray** (`#5c5c5c`): Hover states, subtle emphasis
- **Medium Gray** (`#494949`): Quaternary text
- **Light Gray** (`#f8f8f8`): Light mode surface (if applicable)
- **Border Gray** (`#eaeaea`): Light context borders
- **Edge Gray** (`#ececec`): Subtle borders on light surfaces
- **Mist Gray** (`#dedfdf`): Light dividers
- **Soft Gray** (`#e5e6e6`): Alternate light border

## Surface & Overlay

- **Frost Primary** (`#fcfdff`): Primary color token (slight blue tint, 94% opacity)
- **White Hover** (`rgba(255, 255, 255, 0.28)`): Button hover state on dark
- **White 60%** (`oklab(0.999994 ... / 0.577)`): Semi-transparent white for muted text
- **White 64%** (`oklab(0.999994 ... / 0.642)`): Slightly brighter semi-transparent white

## Borders & Shadows

- **Frost Border** (`rgba(214, 235, 253, 0.19)`): The signature — icy blue-tinted borders at 19% opacity
- **Frost Border Alt** (`rgba(217, 237, 254, 0.145)`): Slightly lighter variant for list items
- **Ring Shadow** (`rgba(176, 199, 217, 0.145) 0px 0px 0px 1px`): Blue-tinted shadow-as-border
- **Focus Ring** (`rgb(0, 0, 0) 0px 0px 0px 8px`): Heavy black focus ring
- **Subtle Shadow** (`rgba(0, 0, 0, 0.1) 0px 1px 3px, rgba(0, 0, 0, 0.1) 0px 1px 2px -1px`): Minimal card elevation
