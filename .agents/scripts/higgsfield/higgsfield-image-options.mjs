// higgsfield-image-options.mjs — Image page option controls.

async function adjustBatchSize(page, targetBatch) {
  console.log(`Setting batch size: ${targetBatch}`);
  const currentBatch = await page.evaluate(() => {
    const batchMatch = document.body.innerText.match(/(\d)\/4/);
    return batchMatch ? parseInt(batchMatch[1], 10) : 4;
  });
  console.log(`Current batch size: ${currentBatch}, target: ${targetBatch}`);

  if (currentBatch === targetBatch) {
    console.log(`Batch size already at ${targetBatch}`);
    return;
  }

  const diff = targetBatch - currentBatch;
  const btnName = diff < 0 ? 'Decrement' : 'Increment';
  const btn = page.getByRole('button', { name: btnName, exact: true });
  if (await btn.count() === 0) {
    console.log(`Could not find ${btnName} button for batch size`);
    return;
  }

  for (let clicks = 0; clicks < Math.abs(diff); clicks++) {
    await btn.click({ force: true });
    await page.waitForTimeout(200);
  }
  console.log(`Clicked ${btnName} ${Math.abs(diff)} time(s) to set batch to ${targetBatch}`);

  const newBatch = await page.evaluate(() => {
    const batchMatch = document.body.innerText.match(/(\d)\/4/);
    return batchMatch ? parseInt(batchMatch[1], 10) : -1;
  });
  console.log(newBatch === targetBatch
    ? `Batch size confirmed: ${newBatch}`
    : `WARNING: Batch size may not have changed (showing ${newBatch})`);
}

export async function setAspectRatio(page, aspect) {
  console.log(`Setting aspect ratio: ${aspect}`);
  const aspectBtn = page.locator(`button:has-text("${aspect}")`);
  if (await aspectBtn.count() > 0) {
    await aspectBtn.first().click({ force: true });
    await page.waitForTimeout(300);
    console.log(`Selected aspect ratio: ${aspect}`);
    return;
  }
  const aspectSelector = page.locator('button:has-text("Aspect"), [class*="aspect"]');
  if (await aspectSelector.count() > 0) {
    await aspectSelector.first().click({ force: true });
    await page.waitForTimeout(500);
    const option = page.locator(`[role="option"]:has-text("${aspect}"), button:has-text("${aspect}")`);
    if (await option.count() > 0) {
      await option.first().click({ force: true });
      await page.waitForTimeout(300);
      console.log(`Selected aspect ratio: ${aspect}`);
    }
  }
}

export async function setEnhanceToggle(page, enhance) {
  const enhanceLabel = page.locator('label:has-text("Enhance"), button:has-text("Enhance")');
  if (await enhanceLabel.count() === 0) return;
  const isChecked = await page.evaluate(() => {
    const el = document.querySelector('label:has(input) span:has-text("Enhance")');
    const input = el?.closest('label')?.querySelector('input');
    return input?.checked || false;
  });
  if (isChecked !== enhance) {
    await enhanceLabel.first().click({ force: true });
    await page.waitForTimeout(300);
    console.log(`${enhance ? 'Enabled' : 'Disabled'} enhance`);
  }
}

export async function configureImageOptions(page, options) {
  if (options.aspect) await setAspectRatio(page, options.aspect);

  if (options.quality) {
    console.log(`Setting quality: ${options.quality}`);
    const qualityBtn = page.locator(`button:has-text("${options.quality}")`);
    if (await qualityBtn.count() > 0) {
      await qualityBtn.first().click({ force: true });
      await page.waitForTimeout(300);
      console.log(`Selected quality: ${options.quality}`);
    }
  }

  if (options.enhance !== undefined) await setEnhanceToggle(page, options.enhance);

  if (options.batch && options.batch >= 1 && options.batch <= 4) {
    await adjustBatchSize(page, options.batch);
  }

  if (options.preset) {
    console.log(`Selecting preset: ${options.preset}`);
    const presetBtn = page.locator(`button:has-text("${options.preset}"), [class*="preset"]:has-text("${options.preset}")`);
    if (await presetBtn.count() > 0) {
      await presetBtn.first().click({ force: true });
      await page.waitForTimeout(500);
      console.log(`Selected preset: ${options.preset}`);
    } else {
      console.log(`Preset "${options.preset}" not found on page`);
    }
  }
}
