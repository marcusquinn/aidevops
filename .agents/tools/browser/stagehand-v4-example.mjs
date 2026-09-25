// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn
// This file is copied into the isolated Stagehand v4 project by setup.
import { localBrowser, Stagehand } from '@browserbasehq/stagehand';
import { z } from 'zod/v4';

if (!process.env.OPENAI_API_KEY || !process.env.STAGEHAND_MODEL?.startsWith('openai/')) {
  throw new Error('Set OPENAI_API_KEY and an openai/ STAGEHAND_MODEL before running');
}

const browser = await localBrowser.launch({ headless: true });
try {
  const stagehand = await Stagehand.create({
    browser,
    model: { modelName: process.env.STAGEHAND_MODEL, apiKey: process.env.OPENAI_API_KEY },
  });
  try {
    const [page] = await browser.context.pages();
    await page.goto('https://example.com');
    const result = await stagehand.extract(
      'Extract the heading of this page',
      z.object({ heading: z.string() }),
    );
    console.log(result.data.heading);
  } finally {
    await stagehand.close();
  }
} finally {
  await browser.close();
}
