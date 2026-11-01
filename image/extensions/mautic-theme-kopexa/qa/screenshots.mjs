// Screenshots of the rendered email (desktop + mobile) for review, plus
// the theme thumbnail Mautic shows in the theme picker.
import { chromium } from 'playwright';
import { mkdirSync } from 'node:fs';

const here = new URL('.', import.meta.url).pathname;
mkdirSync(`${here}dist`, { recursive: true });

// CHROMIUM_PATH: use a preinstalled browser instead of Playwright's download.
const browser = await chromium.launch(process.env.CHROMIUM_PATH ? { executablePath: process.env.CHROMIUM_PATH } : {});
for (const [name, width] of [['desktop', 800], ['mobile', 375]]) {
  const page = await browser.newPage({ viewport: { width, height: 900 }, deviceScaleFactor: 2 });
  // Serve theme assets locally instead of the placeholder Mautic host.
  await page.route('https://mautic.example.com/themes/kopexa/assets/**', (route) => {
    const file = route.request().url().replace('https://mautic.example.com/themes/kopexa/assets/', `${here}../assets/`);
    return route.fulfill({ path: file });
  });
  await page.goto(`file://${here}dist/email.html`);
  await page.waitForLoadState('networkidle');
  await page.screenshot({ path: `${here}dist/screenshot-${name}.png`, fullPage: true });
  if (name === 'desktop') {
    await page.setViewportSize({ width: 800, height: 600 });
    await page.screenshot({ path: `${here}../thumbnail.png`, clip: { x: 0, y: 0, width: 800, height: 600 } });
  }
  await page.close();
}
await browser.close();
console.log('screenshots written to dist/, thumbnail.png updated');
