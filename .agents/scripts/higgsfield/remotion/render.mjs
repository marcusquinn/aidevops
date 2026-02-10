#!/usr/bin/env node
// Remotion render CLI for Higgsfield post-production
// Usage:
//   node render.mjs --brief <path> --videos <v1.mp4,v2.mp4,...> --output <path>
//   node render.mjs --still --text "Title" --aspect 9:16 --output title.png

import { execFileSync } from "node:child_process";
import { readFileSync, existsSync, copyFileSync, mkdirSync } from "node:fs";
import { resolve, dirname, join, basename } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));

function parseArgs() {
  const args = process.argv.slice(2);
  const opts = {};
  for (let i = 0; i < args.length; i++) {
    if (args[i].startsWith("--")) {
      const key = args[i].slice(2);
      const val = args[i + 1] && !args[i + 1].startsWith("--") ? args[++i] : true;
      opts[key] = val;
    }
  }
  return opts;
}

function renderVideo(opts) {
  const briefPath = resolve(opts.brief);
  if (!existsSync(briefPath)) {
    console.error(`Brief not found: ${briefPath}`);
    process.exit(1);
  }

  const brief = JSON.parse(readFileSync(briefPath, "utf-8"));
  const videoPaths = opts.videos ? opts.videos.split(",").map((v) => resolve(v.trim())) : [];
  const output = opts.output ? resolve(opts.output) : resolve("output.mp4");

  // Validate videos exist
  for (const v of videoPaths) {
    if (!existsSync(v)) {
      console.error(`Video not found: ${v}`);
      process.exit(1);
    }
  }

  // Copy videos into Remotion's public/ directory so staticFile() can resolve them.
  // staticFile() only accepts filenames (not absolute paths), so we copy each video
  // to public/ with a deterministic name and pass only the filename in props.
  const publicDir = join(__dirname, "public");
  if (!existsSync(publicDir)) {
    mkdirSync(publicDir, { recursive: true });
  }
  const sceneVideoFilenames = videoPaths.map((absPath, i) => {
    const filename = `scene-${i}.mp4`;
    const dest = join(publicDir, filename);
    copyFileSync(absPath, dest);
    console.log(`  Copied ${basename(absPath)} -> public/${filename}`);
    return filename;
  });

  // Normalize captions: the brief may use startFrame/endFrame format,
  // but FullVideo.tsx expects { scene, text, position, style }.
  // Map startFrame to scene index based on scene durations.
  const fps = 30;
  const rawCaptions = brief.captions || [];
  const scenes = brief.scenes || [];
  const normalizedCaptions = rawCaptions.map((cap) => {
    if (typeof cap.scene === "number") return cap; // Already in correct format
    // Derive scene index from startFrame
    let frameOffset = 0;
    let sceneIdx = 0;
    for (let s = 0; s < scenes.length; s++) {
      const sceneDur = (scenes[s].duration || 5) * fps;
      if ((cap.startFrame || 0) >= frameOffset && (cap.startFrame || 0) < frameOffset + sceneDur) {
        sceneIdx = s;
        break;
      }
      frameOffset += sceneDur;
    }
    return {
      scene: sceneIdx,
      text: cap.text || "",
      position: cap.position || "bottom",
      style: cap.style || "bold-white",
    };
  });

  // Build props for Remotion
  const props = {
    title: brief.title || "Untitled",
    scenes,
    aspect: brief.aspect || "9:16",
    captions: normalizedCaptions,
    sceneVideos: sceneVideoFilenames,
    transitionStyle: brief.transitionStyle || opts.transition || "fade",
    transitionDuration: parseInt(opts["transition-duration"] || "15", 10),
    musicPath: brief.music ? resolve(brief.music) : undefined,
  };

  // Calculate duration
  const totalSceneDuration = props.scenes.reduce((sum, s) => sum + (s.duration || 5), 0);
  const transitionOverlap = Math.max(0, (sceneVideoFilenames.length - 1)) * props.transitionDuration;
  const totalFrames = totalSceneDuration * fps - transitionOverlap;

  // Aspect dimensions
  const dims = {
    "16:9": [1920, 1080],
    "9:16": [1080, 1920],
    "1:1": [1080, 1080],
    "4:3": [1440, 1080],
    "3:4": [1080, 1440],
    "4:5": [1080, 1350],
    "5:4": [1350, 1080],
  };
  const [width, height] = dims[props.aspect] || dims["9:16"];

  const propsJson = JSON.stringify(props);

  const renderArgs = [
    "remotion", "render",
    "src/index.ts",
    "FullVideo",
    output,
    `--props=${propsJson}`,
    `--width=${width}`,
    `--height=${height}`,
    `--frames=0-${totalFrames - 1}`,
    "--codec=h264",
    "--log=verbose",
  ];

  console.log(`Rendering ${sceneVideoFilenames.length} scenes -> ${output}`);
  console.log(`  Aspect: ${props.aspect} (${width}x${height})`);
  console.log(`  Duration: ${totalSceneDuration}s (${totalFrames} frames @ ${fps}fps)`);
  console.log(`  Transitions: ${props.transitionStyle} (${props.transitionDuration}f)`);
  console.log(`  Captions: ${props.captions.length}`);

  try {
    execFileSync("npx", renderArgs, {
      cwd: __dirname,
      stdio: "inherit",
      timeout: 600000, // 10 min
    });
    console.log(`\nRender complete: ${output}`);
  } catch (err) {
    console.error(`Render failed: ${err.message}`);
    process.exit(1);
  }
}

function renderStill(opts) {
  const output = opts.output ? resolve(opts.output) : resolve("graphic.png");
  const aspect = opts.aspect || "9:16";
  const dims = {
    "16:9": [1920, 1080],
    "9:16": [1080, 1920],
    "1:1": [1080, 1080],
  };
  const [width, height] = dims[aspect] || dims["9:16"];

  const props = {
    text: opts.text || "Title",
    subtitle: opts.subtitle || "",
    width,
    height,
    backgroundColor: opts.bg || "#0a0a0a",
    textColor: opts.color || "#ffffff",
    fontFamily: opts.font || "Inter",
  };

  const propsJson = JSON.stringify(props);

  const stillArgs = [
    "remotion", "still",
    "src/index.ts",
    "SceneGraphic",
    output,
    `--props=${propsJson}`,
    `--width=${width}`,
    `--height=${height}`,
    "--log=verbose",
  ];

  console.log(`Rendering still: "${props.text}" -> ${output}`);

  try {
    execFileSync("npx", stillArgs, {
      cwd: __dirname,
      stdio: "inherit",
      timeout: 120000,
    });
    console.log(`\nStill rendered: ${output}`);
  } catch (err) {
    console.error(`Still render failed: ${err.message}`);
    process.exit(1);
  }
}

// Main
const opts = parseArgs();

if (!opts.brief && !opts.still && !opts.help) {
  console.log(`
Higgsfield Post-Production Renderer (Remotion)

Usage:
  node render.mjs --brief <path> --videos <v1.mp4,v2.mp4,...> [--output out.mp4]
  node render.mjs --still --text "Title" [--subtitle "Sub"] [--aspect 9:16] [--output out.png]

Video options:
  --brief              Path to pipeline brief JSON
  --videos             Comma-separated scene video paths
  --output             Output file path (default: output.mp4)
  --transition         Transition style: fade, slide, wipe, none (default: fade)
  --transition-duration  Transition duration in frames (default: 15)

Still options:
  --still              Render a still image (title card / graphic)
  --text               Title text
  --subtitle           Subtitle text
  --aspect             Aspect ratio (default: 9:16)
  --bg                 Background color (default: #0a0a0a)
  --color              Text color (default: #ffffff)
  --font               Font family (default: Inter)
  --output             Output file path (default: graphic.png)
`);
  process.exit(0);
}

if (opts.still) {
  renderStill(opts);
} else {
  renderVideo(opts);
}
