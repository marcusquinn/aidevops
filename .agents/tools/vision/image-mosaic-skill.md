---
name: image-mosaic
description: Tiled image mosaic, photo mosaic, image mosaic, collage wallpaper, image grid background, and mozaic asset pipeline from approved real source imagery
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: false
  grep: true
  webfetch: false
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Image Mosaic Skill

Use this skill when the user asks for a `tiled image mosaic`, `photo mosaic`, `image mosaic`, `collage wallpaper`, `image grid background`, or `mozaic`.

Goal: produce a reproducible raster-heavy mosaic from approved real source imagery, with proof that the final result is recognisable at the target display size.

## Core decision

Choose the tile style before generating assets:

| User intent | Tile baseline | Verification target |
|-------------|---------------|---------------------|
| Recognisable photo mosaic | 200px square tiles | A human can identify representative source photos inside the final mosaic |
| Collage wallpaper | 200px square tiles, then responsive scaling | Individual tiles remain crisp and deliberately placed at target viewport sizes |
| Abstract texture grid | 40-120px tiles | Overall colour and rhythm matter more than photo recognisability |

Default to 200px square tiles when the user expects people, products, places, events, or portfolio images to remain recognisable. Use smaller tiles only when the user explicitly wants texture, noise, ambience, or a distant background pattern.

## Source-image rules

Use only approved source images from user-provided files, project assets, or clearly permitted public assets. Do not invent placeholder photos, pull arbitrary unrelated stock images, or include private/secret images in public artifacts.

Filter candidates before processing:

- Keep real photos that match the requested subject, theme, licence, and privacy boundary.
- Exclude tiny images, logos, icons, transparent placeholders, screenshots, watermarks, UI captures, decorative gradients, and unrelated files unless the user explicitly requests them.
- Require enough variety for the grid size. If the source set is small, repeat deterministically with balanced spacing instead of clustering duplicates.
- Normalize image orientation and colour profile before cropping so tile outputs are stable across reruns.

## Deterministic pipeline

1. **Inventory sources**: write or record a manifest with source path, dimensions, accepted/rejected status, and rejection reason.
2. **Square cover-crop**: crop each accepted source to the centre or detected subject focus, preserving cover semantics rather than stretching.
3. **Generate real tile assets**: export square raster files with deterministic names such as `tile-0001.jpg` under a generated tile directory.
4. **Assemble explicitly**: compose the SVG, HTML, CSS, canvas, or raster output with explicit width and height for the full canvas and every tile.
5. **Avoid fragile raster reuse**: do not rely on SVG `<symbol>`/`<use>` indirection for embedded raster images unless the exact renderer has been proven to preserve image rendering. Inline `<image>` elements or generate a final raster when renderer portability matters.
6. **Emit proof artifacts**: create at least one proof image, contact sheet, or HTML proof that shows the final mosaic next to representative source images and generated tile assets.

Use deterministic ordering. Sort accepted sources by a stable key, seed any shuffle, and document the regeneration command or manual steps.

## Output layout

Use project-local, non-secret output paths. Example names:

```text
mosaic-output/
├── source-manifest.csv
├── generated-tiles/
│   ├── tile-0001.jpg
│   ├── tile-0002.jpg
│   └── ...
├── mosaic.html
├── mosaic.png
└── mosaic-proof.png
```

Do not publish source filenames, private directory names, or sensitive metadata when the output will be shared publicly. Use generic names in public documentation and PRs.

## Assembly guidance

- Compute the final canvas size from `columns * tile_size` and `rows * tile_size`; write those dimensions explicitly.
- Set each tile's rendered dimensions explicitly (`width`, `height`, CSS size, or raster paste box), not only its intrinsic image dimensions.
- Prefer object-cover semantics for HTML/CSS grids and pre-cropped square rasters for SVG/canvas/raster output.
- For responsive collage wallpapers, generate a fixed high-resolution proof plus responsive CSS. Verify both the generated raster proof and representative viewport sizes.
- Avoid mixed live remote image URLs in final artifacts; copy approved images into generated tiles or use data only when size and privacy are acceptable.

## Verification checklist

Before claiming completion, verify all items that apply:

- The source manifest shows only approved, relevant, non-private images accepted.
- Every generated tile is a real raster derived from an accepted source image; no blank placeholders or arbitrary unrelated images remain.
- Tile size matches intent: 200px baseline for recognisable-photo mosaics; smaller only for texture-only grids.
- The final output has explicit full-canvas and per-tile dimensions.
- A proof artifact exists, for example `mosaic-proof.png`, comparing the final mosaic with representative source images and generated tiles.
- At the target display size, at least several representative photos are visually recognisable in the final proof.
- Regeneration is deterministic: source ordering, seed, tile size, columns, output dimensions, and command or manual workflow are documented.

## Dry-run fixture pattern

When no real fixture set is committed, use a dry-run manifest to prove the pipeline without leaking private images:

```text
source-images/photo-a.jpg,1200x800,accepted,real approved photo
source-images/photo-b.jpg,640x960,accepted,real approved photo
source-images/logo.svg,400x400,rejected,logo not a photo
source-images/screenshot.png,1440x900,rejected,screenshot excluded
```

Expected recognisable-photo settings:

```text
tile_size=200
columns=6
rows=4
canvas=1200x800
tiles=generated-tiles/tile-0001.jpg..tile-0024.jpg
proof=mosaic-proof.png
```

The dry-run passes only when the worker can explain which images were accepted, why rejected files were excluded, how square cover-crops are generated, and where the proof artifact demonstrates recognisability.

## Failure modes

- Placeholder mosaics: a pretty grid with synthetic blocks, gradients, or unrelated stock images is not a photo mosaic.
- Micro-tile recognisability loss: 40-100px photo tiles often become texture; use 200px when individual photos matter.
- Privacy leakage: public proofs must not reveal sensitive filenames, EXIF data, private faces, private projects, or local paths.
- Renderer mismatch: SVG-heavy raster reuse can pass in one renderer and collapse in another; verify with the actual export path.
- Non-determinism: undocumented shuffles or remote images make the mosaic impossible to regenerate or review.
