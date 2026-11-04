// Quality gate for Kopexa landing page themes (html/page.html.twig):
// renders the template with the base theme's assets, checks the brand rules
// (brand.kopexa.com) and mobile-first layout in a real browser, writes
// screenshots and the theme thumbnail. Exit code 1 on any failure.
//   node page.mjs <theme-dir>      (e.g. ../../mautic-theme-kopexa-page)
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { chromium } from 'playwright';
import { themeDir, themeName, dist, baseDir } from './theme.mjs';

const here = new URL('.', import.meta.url).pathname;
const tokens = JSON.parse(readFileSync(`${here}tokens.json`, 'utf8'));
const source = readFileSync(`${themeDir}/html/page.html.twig`, 'utf8');
mkdirSync(dist, { recursive: true });
console.log(`theme ${themeName} (landing page)`);

let failed = 0;
const ok = (m) => console.log(`  \x1b[32mok\x1b[0m   ${m}`);
const fail = (m) => { console.log(`  \x1b[31mFAIL\x1b[0m ${m}`); failed++; };

// Render: Twig tags and comments out, getAssetUrl(kx~'…') -> base theme assets.
const body = source
  .replace(/\{#[\s\S]*?#\}/g, '')
  .replace(/\{%[\s\S]*?%\}/g, '')
  .replace(/\{\{\s*getAssetUrl\(kx~'([^']+)'[^}]*\}\}/g, `file://${baseDir}/assets/$1`);
/\{\{|\{%/.test(body) ? fail('unrendered Twig left after the known helpers') : ok('template renders with getAssetUrl only');
const html = `<!DOCTYPE html><html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>Kopexa</title></head><body>${body}</body></html>`;
writeFileSync(`${dist}/page.html`, html);

// Brand palette: tokens, text colour on white, and the colours this theme
// derives for white surfaces (declared once as --kx-muted / --kx-line).
const derived = { muted: '#475B70', line: '#E1E6EC', error: '#B42318' };
const allowed = new Set([...Object.values(tokens.color), '#10253D', ...Object.values(derived)].map((c) => c.toUpperCase()));
const used = new Set([...source.matchAll(/#[0-9a-fA-F]{6}\b/g)].map((m) => m[0].toUpperCase()));
const foreign = [...used].filter((c) => !allowed.has(c));
foreign.length ? fail(`colours outside the brand palette: ${foreign.join(', ')}`) : ok(`only brand colours (${[...used].join(' ')})`);

const lum = (hex) => {
  const [r, g, b] = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255)
    .map((c) => (c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4));
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
};
const ratio = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p); return (x + 0.05) / (y + 0.05); };
for (const [name, fg, bg] of [
  ['body text', '#10253D', '#FFFFFF'], ['headings', tokens.color.navy, '#FFFFFF'], ['secondary text', derived.muted, '#FFFFFF'],
  ['labels and links', tokens.color.action, '#FFFFFF'], ['button', '#FFFFFF', tokens.color.action], ['button hover', '#FFFFFF', tokens.color.actionHover],
  ['brand surface text', tokens.color.supporting, tokens.color.navy], ['brand surface headline', '#FFFFFF', tokens.color.navy],
]) {
  const r = ratio(fg, bg);
  r >= 4.5 ? ok(`contrast ${name} ${r.toFixed(2)}:1`) : fail(`contrast ${name} ${r.toFixed(2)}:1 < 4.5:1`);
}
// Route Blue is the motif colour: never for text, buttons or links.
/(?<![-\w])(color|background|background-color)\s*:\s*(var\(--kx-route\)|#0E9DFD)/i.test(source)
  ? fail('Route Blue used for text or fills — buttons and text use Action Blue #006CB8') : ok('Route Blue only in the motif');
// Flat colours: no shadows, glows or gradients.
/box-shadow|text-shadow|gradient\(/i.test(source) ? fail('shadow or gradient — the brand uses flat colours') : ok('flat colours (no shadows, gradients)');
// Radii from the tokens only.
const radii = new Set(Object.values(tokens.radius).map((r) => `${r}px`));
const badRadii = [...source.matchAll(/--kx-r-\w+:\s*(\d+px)/g)].map((m) => m[1]).filter((r) => !radii.has(r));
badRadii.length ? fail(`radii outside the tokens: ${badRadii.join(', ')}`) : ok('radii from the tokens (6, 8, 14, 24 px)');
/border-radius:\s*\d/.test(source.replace(/--kx-r-\w+:\s*\d+px/g, '')) ? fail('hard-coded border-radius — use var(--kx-r-…)') : ok('border-radius only via the radius tokens');
// Fonts: the three brand fonts, embedded.
['IBM Plex Sans', 'Inter', 'Geist Mono'].every((f) => source.includes(`font-family: '${f}'`))
  ? ok('brand fonts embedded (IBM Plex Sans, Inter, Geist Mono)') : fail('brand @font-face rules missing');
// Links: https (or in-page anchors); legal links present.
const hrefs = [...body.matchAll(/href="([^"]*)"/g)].map((m) => m[1]);
const insecure = hrefs.filter((h) => !/^(https:\/\/|#)/.test(h));
insecure.length ? fail(`links must be https or anchors: ${insecure.join(', ')}`) : ok(`${hrefs.length} links, all https or anchors`);
['https://kopexa.com/de/legal/imprint', 'https://kopexa.com/de/legal/privacy'].every((u) => hrefs.includes(u))
  ? ok('imprint and privacy policy linked') : fail('imprint or privacy link missing');
// Copy rules (brand.kopexa.com/sprache): informal "du", no promises.
/\b(Sie|Ihr|Ihre|Ihnen|Ihren)\b/.test(body.replace(/<[^>]+>/g, ' ')) ? fail('formal address (Sie/Ihr) — the brand writes du, dich, dein') : ok('informal address (du)');
/automatisch compliant|garantiert|100\s*%\s*(sicher|compliant)|rechtssicher/i.test(body) ? fail('promise of compliance or security — not allowed') : ok('no compliance or security promises');

// Browser checks: mobile first, tap targets, one primary action per section.
const browser = await chromium.launch(process.env.CHROMIUM_PATH ? { executablePath: process.env.CHROMIUM_PATH } : {});
for (const width of [320, 360, 390, 768, 1024, 1280]) {
  const page = await browser.newPage({ viewport: { width, height: 900 } });
  await page.goto(`file://${dist}/page.html`);
  await page.waitForLoadState('networkidle');
  const r = await page.evaluate(() => {
    const overflow = document.documentElement.scrollWidth - window.innerWidth;
    const small = [...document.querySelectorAll('.kx-button, .mauticform-button, .mauticform-input')]
      .filter((e) => e.getBoundingClientRect().height < 44).length;
    const perSection = [...document.querySelectorAll('section')].map((s) => s.querySelectorAll('.kx-button').length);
    const noAlt = [...document.querySelectorAll('img')].filter((i) => !i.getAttribute('alt')).length;
    const broken = [...document.querySelectorAll('img')].filter((i) => !i.complete || i.naturalWidth === 0).length;
    const tiny = [...document.querySelectorAll('p, li, a, summary, span')].filter((e) => e.textContent.trim() && parseFloat(getComputedStyle(e).fontSize) < 13).length;
    return { overflow, small, maxActions: Math.max(0, ...perSection), noAlt, broken, tiny };
  });
  const problems = [];
  if (r.overflow > 0) problems.push(`scrolls sideways by ${r.overflow}px`);
  if (r.small) problems.push(`${r.small} tap targets < 44px`);
  if (r.maxActions > 1) problems.push(`${r.maxActions} primary buttons in one section (brand: one per section)`);
  if (r.noAlt) problems.push(`${r.noAlt} images without alt`);
  if (r.broken) problems.push(`${r.broken} images not loaded`);
  if (r.tiny) problems.push(`${r.tiny} texts below 13px`);
  problems.length ? fail(`${width}px: ${problems.join('; ')}`) : ok(`${width}px: no sideways scrolling, tap targets ≥ 44px, one action per section, images with alt`);
  if (width === 390 || width === 1280) {
    await page.screenshot({ path: `${dist}/screenshot-${width === 390 ? 'mobile' : 'desktop'}.png`, fullPage: true });
  }
  await page.close();
}
// Thumbnail like the email themes: 1600 x 1200 (800 x 600 at 2x), top of the page.
const thumb = await browser.newPage({ viewport: { width: 1280, height: 960 }, deviceScaleFactor: 1.25 });
await thumb.goto(`file://${dist}/page.html`);
await thumb.waitForLoadState('networkidle');
await thumb.screenshot({ path: `${themeDir}/thumbnail.png`, clip: { x: 0, y: 0, width: 1280, height: 960 } });
await browser.close();
console.log(`screenshots in ${dist}, ${themeDir}/thumbnail.png updated`);

if (failed) { console.log(`${failed} check(s) failed`); process.exit(1); }
console.log('all landing page checks passed');
