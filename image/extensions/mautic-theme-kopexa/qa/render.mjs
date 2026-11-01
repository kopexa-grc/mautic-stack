// Render html/email.mjml.twig the way Mautic does (MJML 4.15.3, the version
// bundled with Mautic 7's GrapesJS builder) into dist/email.html + .txt.
// Twig asset calls become absolute URLs under ASSET_BASE; Mautic tokens get
// realistic sample values, so size, links and spam checks see a real mail.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import mjml2html from 'mjml';

const here = new URL('.', import.meta.url).pathname;
const assetBase = process.env.ASSET_BASE ?? 'https://mautic.example.com/themes/kopexa/assets';
const site = process.env.SITE ?? 'https://mautic.example.com';

let src = readFileSync(`${here}../html/email.mjml.twig`, 'utf8');
src = src.replace(/\{#[\s\S]*?#\}/g, '');
src = src.replace(/\{\{\s*getAssetUrl\('themes\/'~template~'\/assets\/([^']+)'[^}]*\}\}/g, (_, p) => `${assetBase}/${p}`);
const leftover = src.match(/\{\{[\s\S]*?\}\}|\{%[\s\S]*?%\}/);
if (leftover) { console.error(`unsupported Twig in template: ${leftover[0]}`); process.exit(1); }

const tokens = {
  '{subject}': 'Bring die wichtigen Maßnahmen ins Ziel',
  '{unsubscribe_text}': `<a href="${site}/email/unsubscribe/0123456789abcdef">Abmelden</a>`,
  '{webview_text}': `<a href="${site}/email/view/0123456789abcdef">Im Browser ansehen</a>`,
};
const sample = src
  .replace(/\{contactfield=firstname\|[^}]*\}/g, 'Alex')
  .replace(/\{[a-z_]+(?:=[^}]*)?\}/g, (t) => tokens[t] ?? t);

const { html, errors } = mjml2html(sample, { validationLevel: 'strict', keepComments: false });
if (errors.length) {
  for (const e of errors) console.error(`MJML: line ${e.line}: ${e.message}`);
  process.exit(1);
}

const text = html
  .replace(/<(style|title|head)[\s\S]*?<\/\1>/gi, '')
  .replace(/<a [^>]*href="([^"]+)"[^>]*>([\s\S]*?)<\/a>/gi, '$2 ($1)')
  .replace(/<br\s*\/?>|<\/(p|div|h[1-6]|tr|td)>/gi, '\n')
  .replace(/<[^>]+>/g, '')
  .replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&')
  .replace(/[ \t]+/g, ' ').replace(/\n\s*\n+/g, '\n\n').trim();

mkdirSync(`${here}dist`, { recursive: true });
writeFileSync(`${here}dist/email.html`, html);
writeFileSync(`${here}dist/email.txt`, text + '\n');
console.log(`rendered dist/email.html (${Buffer.byteLength(html)} bytes) and dist/email.txt`);
