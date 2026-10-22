// higgsfield-batch-video-submission.mjs — Single video job submission on a Higgsfield page.
// Extracted from higgsfield-batch-video.mjs: start-frame upload, model selection and
// Generate click. Batch state, polling and orchestration stay in the original module.

import { dismissAllModals } from './higgsfield-browser.mjs';
import { BASE_URL } from './higgsfield-common.mjs';
import {
  findModelButtonInDropdown,
  removeExistingStartFrame,
  tryUploadViaButton,
  tryUploadViaStartFrameArea,
  VIDEO_MODEL_NAME_MAP,
} from './higgsfield-video.mjs';

async function uploadJobStartFrame(page, imageFile, promptSnippet) {
  await removeExistingStartFrame(page);

  const uploaded = await tryUploadViaButton(page, imageFile) ||
    await tryUploadViaStartFrameArea(page, imageFile);

  if (!uploaded) {
    console.log(`  WARNING: Could not upload start frame for: "${promptSnippet}"`);
  }
  return uploaded;
}

async function selectJobVideoModel(page, model) {
  const uiModelName = VIDEO_MODEL_NAME_MAP[model] || model;
  const modelSelector = page.getByRole('button', { name: 'Model' });
  if (await modelSelector.count() === 0) return;

  const currentModel = await modelSelector.textContent().catch(() => '');
  if (currentModel.includes(uiModelName)) return;

  await modelSelector.click({ force: true });
  await page.waitForTimeout(1500);
  const matchingBtns = await findModelButtonInDropdown(page, uiModelName);
  if (matchingBtns.length > 0) {
    await page.mouse.click(matchingBtns[0].x + matchingBtns[0].w / 2, matchingBtns[0].y + matchingBtns[0].h / 2);
    await page.waitForTimeout(1500);
  } else {
    await page.keyboard.press('Escape');
  }
}

export async function submitVideoJobOnPage(page, sceneOptions) {
  const prompt = sceneOptions.prompt || '';
  const model = sceneOptions.model || 'kling-2.6';

  try {
    await page.goto(`${BASE_URL}/create/video`, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForTimeout(4000);
    await dismissAllModals(page);

    if (sceneOptions.imageFile) {
      await uploadJobStartFrame(page, sceneOptions.imageFile, prompt.substring(0, 40));
    }

    await page.waitForTimeout(2000);
    await dismissAllModals(page);
    await selectJobVideoModel(page, model);

    const unlimitedSwitch = page.getByRole('switch', { name: 'Unlimited mode' });
    if (await unlimitedSwitch.count() > 0) {
      const isChecked = await unlimitedSwitch.isChecked().catch(() => false);
      if (!isChecked) {
        await unlimitedSwitch.click({ force: true });
        await page.waitForTimeout(500);
      }
    }

    const promptByRole = page.getByRole('textbox', { name: 'Prompt' });
    if (await promptByRole.count() > 0) {
      await promptByRole.click({ force: true });
      await page.waitForTimeout(300);
      await promptByRole.fill(prompt, { force: true });
    }

    const generateBtn = page.locator('button:has-text("Generate")');
    if (await generateBtn.count() > 0) {
      await generateBtn.last().click({ force: true });
      await page.waitForTimeout(3000);
      console.log(`  Submitted: "${prompt.substring(0, 60)}..."`);
      return prompt.substring(0, 60);
    }

    console.log(`  Failed to submit: "${prompt.substring(0, 40)}..." (no Generate button)`);
    return null;
  } catch (err) {
    console.log(`  Submit error: ${err.message}`);
    return null;
  }
}
