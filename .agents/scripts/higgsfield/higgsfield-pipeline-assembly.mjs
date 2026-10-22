// higgsfield-pipeline-assembly.mjs — Final pipeline assembly and renderer fallback.

import { execFileSync } from 'node:child_process';
import { copyFileSync, existsSync, unlinkSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { ensureDir, safeJoin, sanitizePathSegment } from './higgsfield-common.mjs';

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

export function pipelineAssemble(brief, validVideos, outputDir, pipelineState) {
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
