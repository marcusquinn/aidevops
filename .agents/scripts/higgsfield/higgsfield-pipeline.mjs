// higgsfield-pipeline.mjs — Video production pipeline for the Higgsfield automation suite.
// Orchestrates image generation → video animation → lipsync → assembly.
// Extracted from higgsfield-commands.mjs (t2127 file-complexity decomposition).

import { readFileSync, writeFileSync, existsSync, copyFileSync, unlinkSync } from 'fs';
import { dirname } from 'path';
import { fileURLToPath } from 'url';
import { execFileSync } from 'child_process';

import {
  STATE_FILE,
  ensureDir,
  findNewestFile,
  findNewestFileMatching,
  safeJoin,
  sanitizePathSegment,
  getUnlimitedModelForCommand,
} from './higgsfield-common.mjs';

import {
  launchBrowser,
  getDefaultOutputDir,
} from './higgsfield-browser.mjs';

import { generateImage } from './higgsfield-image.mjs';
import {
  generateLipsync,
  downloadVideoFromHistory,
  submitVideoJobOnPage,
  pollAndDownloadVideos,
} from './higgsfield-video.mjs';

// ─── Pipeline ─────────────────────────────────────────────────────────────────

function loadPipelineBrief(options) {
  if (options.brief) {
    if (!existsSync(options.brief)) {
      console.error(`ERROR: Brief file not found: ${options.brief}`);
      process.exit(1);
    }
    return JSON.parse(readFileSync(options.brief, 'utf-8'));
  }
  return {
    title: 'Quick Pipeline',
    character: {
      description: options.prompt || 'A friendly young person',
      image: options.characterImage || options.imageFile || null,
    },
    scenes: [{
      prompt: options.prompt || 'Character speaks to camera with warm expression',
      duration: parseInt(options.duration, 10) || 5,
      dialogue: options.dialogue || null,
    }],
    imageModel: options.model || (options.preferUnlimited !== false && getUnlimitedModelForCommand('image')?.slug) || 'soul',
    videoModel: (options.preferUnlimited !== false && getUnlimitedModelForCommand('video')?.slug) || 'kling-2.6',
    aspect: options.aspect || '9:16',
  };
}

async function pipelineCharacterImage(brief, options, outputDir, pipelineState) {
  let characterImagePath = brief.character?.image;
  if (characterImagePath) {
    console.log(`\n--- Step 1: Using provided character image: ${characterImagePath} ---`);
    pipelineState.steps.push({ step: 'character-image', success: true, path: characterImagePath, provided: true });
    return characterImagePath;
  }

  console.log(`\n--- Step 1: Generate character image ---`);
  const charPrompt = brief.character?.description || 'A photorealistic portrait of a friendly young person, neutral expression, studio lighting, high quality';
  console.log(`Prompt: "${charPrompt.substring(0, 80)}..."`);

  const charResult = await generateImage({
    ...options, prompt: charPrompt, model: brief.imageModel,
    aspect: '1:1', batch: 1, output: outputDir,
  });

  if (charResult?.success) {
    characterImagePath = findNewestFile(outputDir, ['.png', '.jpg', '.webp']);
    console.log(`Character image: ${characterImagePath || 'NOT FOUND'}`);
    pipelineState.steps.push({ step: 'character-image', success: true, path: characterImagePath });
  } else {
    console.log('WARNING: Character image generation failed, continuing without it');
    pipelineState.steps.push({ step: 'character-image', success: false });
  }
  return characterImagePath;
}

async function pipelineSceneImages(brief, options, outputDir, pipelineState) {
  console.log(`\n--- Step 2: Generate scene images (${brief.scenes.length} scenes) ---`);
  if (brief.imagePrompts?.length > 0) {
    console.log(`Using separate imagePrompts for start frame generation`);
  }
  const sceneImages = [];

  for (let i = 0; i < brief.scenes.length; i++) {
    const imagePrompt = brief.imagePrompts?.[i] || brief.scenes[i].prompt;
    console.log(`\nScene ${i + 1}/${brief.scenes.length}: "${imagePrompt?.substring(0, 60)}..."`);

    const sceneResult = await generateImage({
      ...options, prompt: imagePrompt, model: brief.imageModel,
      aspect: brief.aspect, batch: 1, output: outputDir,
    });

    if (sceneResult?.success) {
      const scenePath = findNewestFileMatching(outputDir, ['.png', '.jpg', '.webp'], 'hf_');
      sceneImages.push(scenePath);
      console.log(`Scene ${i + 1} image: ${scenePath || 'NOT FOUND'}`);
    } else {
      sceneImages.push(null);
      console.log(`Scene ${i + 1} image generation failed`);
    }
  }
  pipelineState.steps.push({ step: 'scene-images', count: sceneImages.filter(Boolean).length, total: brief.scenes.length });
  return sceneImages;
}

async function submitPipelineVideoJobs(brief, sceneImages, options) {
  const validScenes = brief.scenes
    .map((scene, i) => ({ scene, index: i, image: sceneImages[i] }))
    .filter(s => s.image);
  const skippedScenes = brief.scenes.length - validScenes.length;
  if (skippedScenes > 0) console.log(`Skipping ${skippedScenes} scene(s) with no image`);

  console.log(`\n--- Step 3a: Submit ${validScenes.length} video job(s) in parallel ---`);

  if (validScenes.length === 0) return [];

  const { browser: videoBrowser, context: videoCtx, page: videoPage } = await launchBrowser(options);
  const submittedJobs = [];
  try {
    for (const { scene, index, image } of validScenes) {
      console.log(`\n  Submitting scene ${index + 1}/${brief.scenes.length}...`);
      const promptPrefix = await submitVideoJobOnPage(videoPage, {
        prompt: scene.prompt, imageFile: image,
        model: brief.videoModel, duration: String(scene.duration || 5),
      });
      if (promptPrefix) {
        submittedJobs.push({ sceneIndex: index, promptPrefix, model: brief.videoModel });
      }
    }
    await videoCtx.storageState({ path: STATE_FILE });
  } catch (err) {
    console.error('Error during parallel video submission:', err.message);
  }
  try { await videoBrowser.close(); } catch {}
  return submittedJobs;
}

async function pollPipelineVideoResults(brief, submittedJobs, outputDir, options, pipelineState) {
  const sceneVideos = new Array(brief.scenes.length).fill(null);
  if (submittedJobs.length === 0) return sceneVideos;

  const { browser: pollBrowser, context: pollCtx, page: pollPage } = await launchBrowser(options);
  try {
    console.log(`\n--- Step 3b: Polling for ${submittedJobs.length} video(s) ---`);
    const videoResults = await pollAndDownloadVideos(
      pollPage, submittedJobs, outputDir, options.timeout || 600000
    );
    for (const [sceneIndex, path] of videoResults) {
      sceneVideos[sceneIndex] = path;
    }
    await pollCtx.storageState({ path: STATE_FILE });
  } catch (err) {
    console.error('Error during video polling:', err.message);
  }
  try { await pollBrowser.close(); } catch {}

  const videoCount = sceneVideos.filter(Boolean).length;
  console.log(`\nVideo generation: ${videoCount}/${brief.scenes.length} scenes completed`);
  pipelineState.steps.push({ step: 'scene-videos', count: videoCount, total: brief.scenes.length });
  return sceneVideos;
}

async function pipelineAnimateScenes(brief, sceneImages, options, outputDir, pipelineState) {
  const submittedJobs = await submitPipelineVideoJobs(brief, sceneImages, options);
  return pollPipelineVideoResults(brief, submittedJobs, outputDir, options, pipelineState);
}

async function pipelineLipsync({ brief, sceneVideos, characterImagePath, options, outputDir, pipelineState }) {
  console.log(`\n--- Step 4: Add lipsync dialogue ---`);
  const lipsyncVideos = [];
  const scenesWithDialogue = brief.scenes.filter(s => s.dialogue);

  if (scenesWithDialogue.length > 0 && characterImagePath) {
    for (let i = 0; i < brief.scenes.length; i++) {
      const scene = brief.scenes[i];
      if (!scene.dialogue) {
        lipsyncVideos.push(sceneVideos[i]);
        continue;
      }

      console.log(`\nLipsync scene ${i + 1}: "${scene.dialogue.substring(0, 60)}..."`);
      const lipsyncResult = await generateLipsync({
        ...options, prompt: scene.dialogue, imageFile: characterImagePath, output: outputDir,
      });

      if (lipsyncResult?.success) {
        const lipsyncPath = findNewestFile(outputDir, ['.mp4']);
        lipsyncVideos.push(lipsyncPath);
        console.log(`Lipsync video: ${lipsyncPath || 'NOT FOUND'}`);
      } else {
        lipsyncVideos.push(sceneVideos[i]);
        console.log(`Lipsync failed, using original video for scene ${i + 1}`);
      }
    }
  } else {
    console.log('No dialogue scenes or no character image - skipping lipsync');
    lipsyncVideos.push(...sceneVideos);
  }
  pipelineState.steps.push({ step: 'lipsync', count: lipsyncVideos.filter(Boolean).length });
  return lipsyncVideos;
}

function runFfmpegConcat(concatList, finalPath) {
  const baseArgs = ['-y', '-f', 'concat', '-safe', '0', '-i', concatList, '-c', 'copy', finalPath];
  const reencodeArgs = ['-y', '-f', 'concat', '-safe', '0', '-i', concatList, '-c:v', 'libx264', '-c:a', 'aac', '-movflags', '+faststart', finalPath];
  try {
    execFileSync('ffmpeg', baseArgs, { timeout: 120000, stdio: 'pipe' });
    return { success: true, method: 'copy' };
  } catch {
    try {
      execFileSync('ffmpeg', reencodeArgs, { timeout: 300000, stdio: 'pipe' });
      return { success: true, method: 'reencode' };
    } catch (reencodeErr) {
      return { success: false, error: reencodeErr.message };
    }
  }
}

function addMusicToVideo(finalPath, musicPath) {
  const withMusicPath = finalPath.replace('-final.mp4', '-final-music.mp4');
  try {
    execFileSync('ffmpeg', ['-y', '-i', finalPath, '-i', musicPath, '-c:v', 'copy', '-c:a', 'aac', '-map', '0:v:0', '-map', '1:a:0', '-shortest', withMusicPath], {
      timeout: 120000, stdio: 'pipe',
    });
    console.log(`Final video with music: ${withMusicPath}`);
  } catch (musicErr) {
    console.log(`Adding music failed: ${musicErr.message}`);
  }
}

function assembleWithFfmpeg(validVideos, finalPath, brief, outputDir, pipelineState) {
  if (validVideos.length === 1) {
    copyFileSync(validVideos[0], finalPath);
    console.log(`Final video (single scene, ffmpeg copy): ${finalPath}`);
  } else {
    const concatList = safeJoin(outputDir, 'concat-list.txt');
    writeFileSync(concatList, validVideos.map(v => `file '${v}'`).join('\n'));

    const result = runFfmpegConcat(concatList, finalPath);
    if (!result.success) {
      console.log(`ffmpeg assembly failed: ${result.error}`);
      console.log(`Individual scene videos are in: ${outputDir}`);
      pipelineState.steps.push({ step: 'assembly', success: false, method: 'ffmpeg', reason: result.error });
      return;
    }
    console.log(`Final video (ffmpeg ${result.method}, ${validVideos.length} scenes): ${finalPath}`);
  }

  if (brief.music && existsSync(brief.music) && existsSync(finalPath)) {
    addMusicToVideo(finalPath, brief.music);
  }

  pipelineState.steps.push({ step: 'assembly', success: true, method: 'ffmpeg', path: finalPath });
}

function assembleWithRemotion({ validVideos, finalPath, brief, remotionDir, outputDir, pipelineState }) {
  console.log(`Using Remotion for assembly (${validVideos.length} scenes, ${brief.captions?.length || 0} captions)`);

  const publicDir = safeJoin(remotionDir, 'public');
  ensureDir(publicDir);
  const staticVideoNames = [];
  for (let i = 0; i < validVideos.length; i++) {
    const staticName = `scene-${i}.mp4`;
    const destPath = safeJoin(publicDir, sanitizePathSegment(staticName, `scene-${i}.mp4`));
    try { if (existsSync(destPath)) { unlinkSync(destPath); } } catch { /* ignore */ }
    copyFileSync(validVideos[i], destPath);
    staticVideoNames.push(staticName);
  }

  const remotionProps = {
    title: brief.title || 'Untitled', scenes: brief.scenes || [],
    aspect: brief.aspect || '9:16', captions: brief.captions || [],
    sceneVideos: staticVideoNames, transitionStyle: brief.transitionStyle || 'fade',
    transitionDuration: brief.transitionDuration || 15,
    musicPath: brief.music && existsSync(brief.music) ? brief.music : undefined,
  };

  const propsFile = safeJoin(outputDir, 'remotion-props.json');
  writeFileSync(propsFile, JSON.stringify(remotionProps));

  const remotionArgs = [
    'remotion', 'render', 'src/index.ts', 'FullVideo', finalPath,
    `--props=${propsFile}`, '--codec=h264', '--log=warn',
  ];

  try {
    execFileSync('npx', remotionArgs, { cwd: remotionDir, stdio: 'inherit', timeout: 600000 });
    console.log(`Final video (Remotion, ${validVideos.length} scenes + captions): ${finalPath}`);
    pipelineState.steps.push({ step: 'assembly', success: true, method: 'remotion', path: finalPath });
  } catch (remotionErr) {
    console.log(`Remotion render failed: ${remotionErr.message}`);
    console.log('Falling back to ffmpeg concat...');
    assembleWithFfmpeg(validVideos, finalPath, brief, outputDir, pipelineState);
  }
}

function pipelineAssemble(brief, validVideos, outputDir, pipelineState) {
  console.log(`\n--- Step 5: Assemble final video ---`);

  if (validVideos.length === 0) {
    console.log('No valid video clips to assemble');
    pipelineState.steps.push({ step: 'assembly', success: false, reason: 'no valid clips' });
    return;
  }

  const finalPath = safeJoin(outputDir, sanitizePathSegment(`${brief.title.toLowerCase().replace(/[^a-z0-9]+/g, '-')}-final.mp4`, 'pipeline-final.mp4'));
  const __dirname = dirname(fileURLToPath(import.meta.url));
  const remotionDir = safeJoin(__dirname, 'remotion');
  const remotionInstalled = existsSync(safeJoin(remotionDir, 'node_modules', 'remotion'));
  const hasCaptions = brief.captions && brief.captions.length > 0;

  if (remotionInstalled && (hasCaptions || validVideos.length > 1)) {
    assembleWithRemotion({ validVideos, finalPath, brief, remotionDir, outputDir, pipelineState });
  } else if (validVideos.length === 1 && !hasCaptions) {
    copyFileSync(validVideos[0], finalPath);
    console.log(`Final video (single scene): ${finalPath}`);
    pipelineState.steps.push({ step: 'assembly', success: true, method: 'copy', path: finalPath });
  } else {
    if (!remotionInstalled) {
      console.log('Remotion not installed - using ffmpeg concat (no captions/transitions)');
      console.log(`Install with: cd ${remotionDir} && npm install`);
    }
    assembleWithFfmpeg(validVideos, finalPath, brief, outputDir, pipelineState);
  }
}

export async function pipeline(options = {}) {
  const brief = loadPipelineBrief(options);
  const outputDir = options.output || safeJoin(getDefaultOutputDir(options), `pipeline-${Date.now()}`);
  ensureDir(outputDir);

  console.log(`\n=== Video Production Pipeline ===`);
  console.log(`Title: ${brief.title}`);
  console.log(`Scenes: ${brief.scenes.length}`);
  console.log(`Image model: ${brief.imageModel}`);
  console.log(`Video model: ${brief.videoModel}`);
  console.log(`Aspect: ${brief.aspect}`);
  console.log(`Output: ${outputDir}`);

  const pipelineState = { brief, outputDir, steps: [], startTime: Date.now() };

  const characterImagePath = await pipelineCharacterImage(brief, options, outputDir, pipelineState);
  const sceneImages = await pipelineSceneImages(brief, options, outputDir, pipelineState);
  const sceneVideos = await pipelineAnimateScenes(brief, sceneImages, options, outputDir, pipelineState);
  const lipsyncVideos = await pipelineLipsync({ brief, sceneVideos, characterImagePath, options, outputDir, pipelineState });
  pipelineAssemble(brief, lipsyncVideos.filter(Boolean), outputDir, pipelineState);

  const elapsed = ((Date.now() - pipelineState.startTime) / 1000).toFixed(0);
  pipelineState.elapsed = `${elapsed}s`;
  writeFileSync(safeJoin(outputDir, 'pipeline-state.json'), JSON.stringify(pipelineState, null, 2));

  console.log(`\n=== Pipeline Complete ===`);
  console.log(`Duration: ${elapsed}s`);
  console.log(`Output: ${outputDir}`);
  console.log(`Steps: ${pipelineState.steps.map(s => `${s.step}:${s.success !== false ? 'OK' : 'FAIL'}`).join(' -> ')}`);

  return pipelineState;
}
