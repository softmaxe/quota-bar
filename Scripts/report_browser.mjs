import {createRequire} from 'node:module';

// PLAYWRIGHT_MODULE points to the entry file of an existing Playwright-backed CLI.
export async function launchReportBrowser() {
  const {chromium} = process.env.PLAYWRIGHT_MODULE
    ? createRequire(process.env.PLAYWRIGHT_MODULE)('playwright')
    : await import('playwright-core');
  return chromium.launch({
    headless: true,
    executablePath: process.env.CHROMIUM_PATH || '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser',
  });
}

export async function captureReport(page) {
  const viewport = page.viewportSize();
  const height = await page.evaluate(() => document.documentElement.scrollHeight);
  if (height <= viewport.height) return page.screenshot({animations: 'disabled'});

  // Fit the report in one frame. Chromium can repeat the first viewport when stitching a tall page.
  await page.setViewportSize({...viewport, height});
  try {
    await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
    return await page.screenshot({animations: 'disabled'});
  } finally {
    await page.setViewportSize(viewport);
  }
}
