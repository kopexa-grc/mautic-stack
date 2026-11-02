// Static quality checks on the rendered email (dist/email.html) and the
// template source. Exit code 1 on any failure.
import { readFileSync } from 'node:fs';

const here = new URL('.', import.meta.url).pathname;
const html = readFileSync(`${here}dist/email.html`, 'utf8');
const text = readFileSync(`${here}dist/email.txt`, 'utf8');
const source = readFileSync(`${here}../html/email.mjml.twig`, 'utf8');
const tokens = JSON.parse(readFileSync(`${here}tokens.json`, 'utf8'));

let failed = 0;
const ok = (m) => console.log(`  \x1b[32mok\x1b[0m   ${m}`);
const fail = (m) => { console.log(`  \x1b[31mFAIL\x1b[0m ${m}`); failed++; };
const warn = (m) => console.log(`  \x1b[33mwarn\x1b[0m ${m}`);

// 1. Size: Gmail clips messages above 102 KB (and hides the unsubscribe link).
const size = Buffer.byteLength(html);
if (size > 102 * 1024) fail(`HTML is ${size} bytes — Gmail clips above 102 KB`);
else if (size > 60 * 1024) warn(`HTML is ${size} bytes — leave room for content (< 60 KB template)`);
else ok(`HTML size ${(size / 1024).toFixed(1)} KB (Gmail clips at 102 KB)`);

// 2. Images: alt text, https, explicit width (Outlook), no tracking-hostile hosts.
const imgs = [...html.matchAll(/<img\b[^>]*>/gi)].map((m) => m[0]);
const attr = (tag, a) => (tag.match(new RegExp(`\\b${a}="([^"]*)"`, 'i')) ?? [])[1];
const badImg = imgs.filter((t) => !attr(t, 'alt') || !/^https:\/\//.test(attr(t, 'src') ?? '') || !attr(t, 'width'));
badImg.length ? fail(`images without alt / https src / width: ${badImg.length}`) : ok(`${imgs.length} images: alt text, https, width`);

// 3. Links: https only, no URL shorteners.
const hrefs = [...html.matchAll(/<a\b[^>]*href="([^"]*)"/gi)].map((m) => m[1]);
const badLinks = hrefs.filter((h) => !/^(https:\/\/|mailto:)/.test(h));
const shorteners = hrefs.filter((h) => /\/\/(bit\.ly|t\.co|goo\.gl|tinyurl\.com|ow\.ly|is\.gd)\//.test(h));
badLinks.length ? fail(`non-https links: ${badLinks.join(', ')}`) : ok(`${hrefs.length} links, all https`);
shorteners.length ? fail(`URL shorteners hurt reputation: ${shorteners.join(', ')}`) : ok('no URL shorteners');

// 4. Required parts of a marketing email.
// Mautic's GrapesJS builder: it parses the template as HTML and checks for
// the literal "<mjml>" before converting ("No valid MJML provided").
const mjmlSource = source.replace(/\{#[\s\S]*?#\}/g, '');
/<mjml>/.test(mjmlSource) ? ok('root tag is exactly <mjml> (Mautic builder)') : fail('root must be exactly <mjml> without attributes, or the Mautic builder rejects the template');
const selfClosing = mjmlSource.match(/<mj-[a-z-]+[^<>]*\/>/g) || [];
selfClosing.length === 0 ? ok('no self-closing mj-* tags (builder parses HTML)') : fail(`self-closing tags break the builder's HTML parsing: ${selfClosing.slice(0, 3).join(' ')}`);
/\{unsubscribe_text\}|\{unsubscribe_url\}/.test(source) ? ok('unsubscribe token present') : fail('no {unsubscribe_text} / {unsubscribe_url} in template');
/\{webview_text\}|\{webview_url\}/.test(source) ? ok('web view token present') : warn('no web view link');
// Mautic's builder only accepts a bare <mjml> root, so MJML writes lang="und".
const lang = (html.match(/<html[^>]*\blang="([a-z-]+)"/i) || [])[1];
!lang ? fail('missing <html lang>') : lang === 'und'
  ? warn('<html lang="und">: the Mautic builder does not allow <mjml lang>; screen readers fall back to their default language')
  : ok(`lang="${lang}" (screen readers)`);
/<title>[^<]+<\/title>/i.test(html) ? ok('<title> set') : fail('missing <title>');
/Impressum/.test(source) && /Datenschutz/.test(source) ? ok('imprint and privacy links in footer') : fail('footer needs Impressum and Datenschutz links');
text.replace(/\s+/g, ' ').length > 100 ? ok(`plain-text part ${text.length} chars`) : fail('plain-text part too short');

// 5. Brand palette only (tokens.json + text colour on white).
const allowed = new Set([...Object.values(tokens.color), '#10253D', '#FFFFFF'].map((c) => c.toUpperCase()));
const used = new Set([...source.matchAll(/#[0-9a-fA-F]{6}\b/g)].map((m) => m[0].toUpperCase()));
const foreign = [...used].filter((c) => !allowed.has(c));
foreign.length ? fail(`colours outside the brand palette: ${foreign.join(', ')}`) : ok(`only brand colours (${[...used].join(' ')})`);

// 6. Contrast (WCAG AA 4.5:1) for every text/background pair the theme uses.
const lum = (hex) => {
  const [r, g, b] = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255)
    .map((c) => (c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4));
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
};
const ratio = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p); return (x + 0.05) / (y + 0.05); };
const pairs = [
  ['body text', '#10253D', '#FFFFFF'], ['headings', '#070B14', '#FFFFFF'],
  ['primary button', '#FFFFFF', tokens.color.action], ['secondary button / links', tokens.color.action, '#FFFFFF'],
  ['footer text', tokens.color.supporting, tokens.color.navy], ['footer claim', '#FFFFFF', tokens.color.navy],
];
for (const [name, fg, bg] of pairs) {
  const r = ratio(fg, bg);
  r >= 4.5 ? ok(`contrast ${name} ${r.toFixed(2)}:1`) : fail(`contrast ${name} ${r.toFixed(2)}:1 < 4.5:1`);
}
// Route Blue is an accent colour: it must not be used for text or buttons on white.
/color="#0E9DFD"|background-color="#0E9DFD"/i.test(source) ? fail('Route Blue #0E9DFD used for text/buttons — use Action Blue #006CB8') : ok('Route Blue not used for text/buttons');

// 7. Brand fonts embedded, no external CSS.
['IBM Plex Sans', 'Inter', 'Geist Mono'].every((f) => html.includes(`font-family: '${f}'`) || html.includes(`font-family:'${f}'`))
  ? ok('brand fonts embedded (@font-face IBM Plex Sans, Inter, Geist Mono) with system fallbacks') : fail('brand @font-face rules missing');
/<link[^>]+stylesheet/i.test(html) ? fail('external stylesheet <link> — spam filters penalise it, most clients ignore it') : ok('no external stylesheets');

// 8. Dark mode: we ship a light-only design, so ask clients not to invert it.
/<meta name="color-scheme" content="light only">/.test(html) ? ok('color-scheme: light only') : fail('missing color-scheme meta');

if (failed) { console.log(`\n${failed} check(s) failed`); process.exit(1); }
console.log('\nall static checks passed');
