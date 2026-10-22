// higgsfield-pipeline.mjs — Video production pipeline for the Higgsfield automation suite.
// Orchestrates image generation → video animation → lipsync → assembly.
// Extracted from higgsfield-commands.mjs (t2127 file-complexity decomposition).

import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import {
  getDefaultOutputDir,
  launchBrowser,
} from './higgsfield-browser.mjs';
import {
  ensureDir,
  findNewestFile,
  findNewestFileMatching,
  getUnlimitedModelForCommand,
  STATE_FILE,
  safeJoin,
} from './higgsfield-common.mjs';

import { generateImage } from './higgsfield-image.mjs';
import { pipelineAssemble } from './higgsfield-pipeline-assembly.mjs';
import {
  generateLipsync,
  pollAndDownloadVideos,
  submitVideoJobOnPage,
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
