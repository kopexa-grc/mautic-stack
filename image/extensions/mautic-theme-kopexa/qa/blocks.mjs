// Block library for emails built by assistants (kopexa/mautic-mcp-bundle,
// tool create_email_from_layout): panels (hero, article, cards) made of
// elements (label, title, text, button, image, ...), as MJML (so the
// email stays editable in Mautic's builder) and as HTML compiled by MJML
// (Mautic only compiles MJML in the browser, so the server needs the HTML
// to send). Both come from the same source below and the theme's head,
// header and footer (html/email.mjml.twig).
//
//   node blocks.mjs          write ../mcp/blocks.json
//   node blocks.mjs --check  fail if blocks.json is out of date, and prove
//                            that assembled HTML == MJML's own output
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import mjml2html from 'mjml';

const here = new URL('.', import.meta.url).pathname;
const out = `${here}../mcp/blocks.json`;

// ---------------------------------------------------------------------------
// Theme parts from the template
let tpl = readFileSync(`${here}../html/email.mjml.twig`, 'utf8').replace(/\{#[\s\S]*?#\}/g, '');
tpl = tpl.replace(/\{\{\s*getAssetUrl\('themes\/'~template~'\/assets\/([^']+)'[^}]*\}\}/g, '{{asset:$1}}');
const between = (s, a, b) => s.slice(s.indexOf(a), s.indexOf(b, s.indexOf(a) + a.length));
const head = between(tpl, '<mj-head>', '<mj-body') ;
const bodyOpen = tpl.match(/<mj-body[^>]*>/)[0];
const header = between(tpl, '<!-- Header', '<!-- Content panel').trim();
const footer = between(tpl, '<!-- Footer', '</mj-body>').trim();

// ---------------------------------------------------------------------------
// Elements: MJML with {{slots}}. Slot types: text (escaped), html (inline
// HTML: b, strong, i, em, a, br, ul, ol, li), url (https, mailto or a Mautic
// token), image (https URL).
const h = (tag, slot) => `<${tag} style="margin:0;font:inherit;color:inherit;">{{${slot}}}</${tag}>`;
const el = {
  article: {
    label: ['Small label above the headline (Geist Mono, uppercase)', { text: 'text' }, '<mj-text mj-class="t-label" padding="0 32px 12px 32px">{{text}}</mj-text>'],
    title: ['Main headline (H1)', { text: 'text' }, `<mj-text mj-class="t-h1" padding="0 32px 24px 32px">${h('h1', 'text')}</mj-text>`],
    subtitle: ['Section headline (H2)', { text: 'text' }, `<mj-text mj-class="t-h2" padding="8px 32px 12px 32px">${h('h2', 'text')}</mj-text>`],
    lead: ['Intro sentence, larger', { text: 'text' }, '<mj-text mj-class="t-lead" padding="0 32px 16px 32px">{{text}}</mj-text>'],
    text: ['Paragraph; inline HTML allowed (b, strong, i, em, a, br, ul, ol, li), tokens like {contactfield=firstname|zusammen}', { html: 'html' }, '<mj-text mj-class="t-body">{{html}}</mj-text>'],
    note: ['Small print, e.g. "Der Link ist 48 Stunden gültig."', { text: 'text' }, '<mj-text mj-class="k-note" padding="0 32px 16px 32px">{{text}}</mj-text>'],
    button: ['Primary button (one per panel)', { text: 'text', url: 'url' }, '<mj-button mj-class="t-btn t-btn-primary" href="{{url}}">{{text}}</mj-button>'],
    button_secondary: ['Secondary (outline) button', { text: 'text', url: 'url' }, '<mj-button mj-class="t-btn t-btn-secondary" href="{{url}}">{{text}}</mj-button>'],
    image: ['Full-width image, 576 px wide (upload 1152 px); height follows the image', { src: 'image', alt: 'text' }, '<mj-image src="{{src}}" alt="{{alt}}" width="576px" border-radius="8px" padding="0 32px 24px 32px"></mj-image>'],
  },
  hero: {
    label: ['Small label (light on dark)', { text: 'text' }, '<mj-text mj-class="k-hero-label" padding="0 32px 16px 32px">{{text}}</mj-text>'],
    title: ['Headline (H1, white)', { text: 'text' }, `<mj-text mj-class="k-hero-h1" css-class="k-hero-h1" padding="0 32px 16px 32px">${h('h1', 'text')}</mj-text>`],
    lead: ['Intro (light on dark)', { text: 'text' }, '<mj-text mj-class="k-hero-lead" padding="0 32px 24px 32px">{{text}}</mj-text>'],
    button: ['Primary button', { text: 'text', url: 'url' }, '<mj-button mj-class="t-btn t-btn-primary" href="{{url}}">{{text}}</mj-button>'],
    image: ['Full-width image, 576 px wide', { src: 'image', alt: 'text' }, '<mj-image src="{{src}}" alt="{{alt}}" width="576px" border-radius="8px" padding="0 32px 24px 32px"></mj-image>'],
  },
  card: {
    image: ['Card image, 272 × 153 px (upload 544 × 306)', { src: 'image', alt: 'text' }, '<mj-image src="{{src}}" alt="{{alt}}" width="272px" height="153px" border-radius="8px" padding="0 16px 16px 16px"></mj-image>'],
    label: ['Small label', { text: 'text' }, '<mj-text mj-class="t-label" padding="0 16px 8px 16px">{{text}}</mj-text>'],
    title: ['Card headline (H3)', { text: 'text' }, `<mj-text mj-class="t-h4" padding="0 16px 8px 16px">${h('h3', 'text')}</mj-text>`],
    text: ['Card text; inline HTML allowed', { html: 'html' }, '<mj-text mj-class="t-body" padding="0 16px 16px 16px">{{html}}</mj-text>'],
    button: ['Card button (outline)', { text: 'text', url: 'url' }, '<mj-button mj-class="t-btn t-btn-secondary" href="{{url}}" padding="0 16px 24px 16px">{{text}}</mj-button>'],
  },
  intro: {
    subtitle: ['Headline above the cards (H2)', { text: 'text' }, `<mj-text mj-class="t-h2" padding="0 32px 12px 32px">${h('h2', 'text')}</mj-text>`],
    text: ['Intro text above the cards', { html: 'html' }, '<mj-text mj-class="t-body" padding="0 32px 24px 32px">{{html}}</mj-text>'],
  },
};

// Panels: MJML split into parts around the element areas.
const panels = {
  article: {
    description: 'White panel: label, headline, text, buttons, images, small print in any order. The standard content panel.',
    areas: [['items', el.article]],
    parts: [
      '<mj-wrapper mj-class="t-surface-1" css-class="k-panel" border-radius="14px" padding="40px 0 16px 0"><mj-section mj-class="t-section t-surface-1"><mj-column>',
      '</mj-column></mj-section></mj-wrapper>',
    ],
  },
  hero: {
    description: 'Dark hero panel for the opening: label, big headline, lead, button, optional image.',
    areas: [['items', el.hero]],
    parts: [
      '<mj-wrapper mj-class="k-hero" css-class="k-panel" border-radius="14px" padding="48px 0 24px 0"><mj-section mj-class="t-section k-hero"><mj-column>',
      '</mj-column></mj-section></mj-wrapper>',
    ],
  },
  cards: {
    description: 'White panel with an optional intro and two cards side by side (stacked on mobile). Each card: image, label, title, text, button, all optional.',
    areas: [['intro', el.intro], ['left', el.card], ['right', el.card]],
    parts: [
      '<mj-wrapper mj-class="t-surface-1" css-class="k-panel" border-radius="14px" padding="40px 0 16px 0"><mj-section mj-class="t-section t-surface-1"><mj-column>',
      '</mj-column></mj-section><mj-section mj-class="t-section t-surface-1" padding="0 16px"><mj-column>',
      '</mj-column><mj-column>',
      '</mj-column></mj-section></mj-wrapper>',
    ],
  },
};
const gap = '<mj-section mj-class="k-navy" padding="8px 0"><mj-column><mj-spacer height="8px"></mj-spacer></mj-column></mj-section>';

// ---------------------------------------------------------------------------
// Kitchen sink: every panel with every element, separated by markers; MJML
// compiles it once, the HTML is cut at the markers.
const raw = (m) => `<mj-raw><!--kx:${m}--></mj-raw>`;
const slotToken = (name) => `KXS${name}KXE`;
const tokens = (mjml) => mjml.replace(/\{\{([a-z]+)\}\}/g, (_, n) => slotToken(n));
let sink = '';
for (const [name, p] of Object.entries(panels)) {
  sink += raw(`p:${name}`) + p.parts[0];
  p.areas.forEach(([area, elements], i) => {
    for (const [e, [, , m]] of Object.entries(elements)) sink += raw(`e:${name}:${area}:${e}`) + tokens(m);
    sink += raw(`end:${name}:${area}`) + p.parts[i + 1];
  });
  sink += raw(`gap`) + gap;
}
sink += raw('end');
const doc = (content) => `<mjml>${head}${bodyOpen}${header}${raw('content')}${content}${raw('content-end')}${footer}</mj-body></mjml>`;
const compile = (m) => {
  const { html, errors } = mjml2html(m, { validationLevel: 'strict', keepComments: true });
  if (errors.length) throw new Error(errors.map((e) => `line ${e.line}: ${e.message}`).join('\n'));
  return html;
};
const html = compile(doc(sink));
const cut = (from, to) => {
  const a = html.indexOf(`<!--kx:${from}-->`);
  const b = html.indexOf(`<!--kx:${to}-->`, a + 1);
  if (a < 0 || b < 0) throw new Error(`marker ${from} / ${to} missing`);
  return html.slice(a + `<!--kx:${from}-->`.length, b).trim();
};
const untoken = (s) => s.replace(/KXS([a-z]+)KXE/g, '{{$1}}');

const library = {
  version: 1,
  theme: 'kopexa',
  description: 'Kopexa brand emails: navy page, logo header, footer with imprint, privacy and unsubscribe. Build them from panels (hero, article, cards); a navy gap separates panels.',
  slot_types: { text: 'plain text (escaped)', html: 'inline HTML: b, strong, i, em, u, a href, br, p, ul, ol, li', url: 'https or mailto URL, or a Mautic token such as {doi_link}', image: 'https image URL' },
  placeholders: {
    card: ['{{asset:placeholder/card-1.png}}', '{{asset:placeholder/card-2.png}}'],
    wide: ['{{asset:placeholder/feature.png}}'],
  },
  mjml: { open: `<mjml>${head}${bodyOpen}${header}`, close: `${footer}</mj-body></mjml>`, gap },
  html: {
    document: html.slice(0, html.indexOf('<!--kx:content-->')) + '<!--kx:content-->' + html.slice(html.indexOf('<!--kx:content-end-->') + '<!--kx:content-end-->'.length),
    gap: untoken(cut('gap', Object.keys(panels)[1] ? `p:${Object.keys(panels)[1]}` : 'end')),
  },
  panels: {},
};
const names = Object.keys(panels);
names.forEach((name, n) => {
  const p = panels[name];
  const entry = { description: p.description, areas: {}, mjml: { parts: p.parts }, html: { parts: [] } };
  // html parts: before the first element marker of area i, between areas, after the last
  const firstMarker = (area) => `e:${name}:${area}:${Object.keys(p.areas.find(([a]) => a === area)[1])[0]}`;
  entry.html.parts.push(cut(`p:${name}`, firstMarker(p.areas[0][0])));
  p.areas.forEach(([area, elements], i) => {
    const keys = Object.keys(elements);
    entry.areas[area] = {};
    keys.forEach((e, k) => {
      const [description, slots, m] = elements[e];
      entry.areas[area][e] = { description, slots, mjml: m, html: untoken(cut(`e:${name}:${area}:${e}`, k + 1 < keys.length ? `e:${name}:${area}:${keys[k + 1]}` : `end:${name}:${area}`)) };
    });
    entry.html.parts.push(cut(`end:${name}:${area}`, i + 1 < p.areas.length ? firstMarker(p.areas[i + 1][0]) : 'gap'));
  });
  library.panels[name] = entry;
});
// the gap between panels (identical everywhere): cut after the first panel
library.html.gap = cut('gap', `p:${names[1]}`);

// ---------------------------------------------------------------------------
// Assembly, exactly as the PHP side does it (MauticPlugin\KopexaMcpBundle\Email\LayoutRenderer)
export function assemble(lib, layout, fill) {
  let m = lib.mjml.open, x = '';
  layout.forEach((panel, i) => {
    const p = lib.panels[panel.type];
    if (i > 0) { m += lib.mjml.gap; x += lib.html.gap; }
    m += p.mjml.parts[0]; x += p.html.parts[0];
    Object.keys(p.areas).forEach((area, a) => {
      for (const item of panel[area] ?? []) {
        const e = p.areas[area][item.type];
        m += fill(e.mjml, item, 'mjml'); x += fill(e.html, item, 'html');
      }
      m += p.mjml.parts[a + 1]; x += p.html.parts[a + 1];
    });
  });
  return { mjml: m + lib.mjml.close, html: lib.html.document.replace('<!--kx:content-->', x) };
}

const json = JSON.stringify(library, null, 1) + '\n';
if (process.argv.includes('--check')) {
  let failed = 0;
  const current = (() => { try { return readFileSync(out, 'utf8'); } catch { return ''; } })();
  if (current !== json) { console.log('  FAIL mcp/blocks.json is out of date: run node qa/blocks.mjs'); failed++; } else console.log('  ok   mcp/blocks.json up to date');
  // Proof: an assembled email (markers kept in the MJML) compiles to the same HTML.
  const sample = [
    { type: 'hero', items: [{ type: 'label', text: 'WEBINAR' }, { type: 'title', text: 'NIS2 & Co' }, { type: 'button', text: 'Platz sichern', url: 'https://www.kopexa.com/de' }] },
    { type: 'article', items: [{ type: 'title', text: 'Hallo' }, { type: 'text', html: 'Erster <b>Absatz</b>' }, { type: 'text', html: 'Zweiter' }, { type: 'note', text: 'Klein' }] },
    { type: 'cards', intro: [{ type: 'subtitle', text: 'Themen' }], left: [{ type: 'title', text: 'A' }], right: [{ type: 'label', text: 'B' }, { type: 'text', html: 'b' }] },
  ];
  const fill = (tplStr, item) => tplStr.replace(/\{\{([a-z]+)\}\}/g, (_, n) => String(item[n] ?? ''));
  const markLib = JSON.parse(json);
  const withMarkers = assembleWithMarkers(markLib, sample, fill);
  const expected = compile(withMarkers.mjml).replace(/<!--kx:[^>]*-->/g, '');
  const actual = withMarkers.html.replace(/<!--kx:[^>]*-->/g, '');
  const norm = (s) => s.replace(/>\s+</g, '><').replace(/\s+/g, ' ').trim();
  if (norm(expected) === norm(actual)) console.log('  ok   assembled HTML is identical to what MJML compiles from the assembled MJML');
  else {
    const a = norm(expected), b = norm(actual); let i = 0; while (a[i] === b[i]) i++;
    console.log(`  FAIL assembled HTML differs from MJML's output at ${i}:\n    mjml: ${a.slice(i - 80, i + 120)}\n    ours: ${b.slice(i - 80, i + 120)}`); failed++;
  }
  // every panel compiles in strict mode on its own (builder round trip)
  for (const type of names) compile(assemble(markLib, [{ type, ...Object.fromEntries(Object.keys(markLib.panels[type].areas).map((a) => [a, Object.keys(markLib.panels[type].areas[a]).map((e) => ({ type: e, text: 'x', html: 'x', url: 'https://www.kopexa.com/de', src: 'https://www.kopexa.com/x.png', alt: 'x' }))])) }], fill).mjml);
  console.log(`  ok   every panel with all elements is valid MJML (strict)`);
  process.exit(failed ? 1 : 0);
}
mkdirSync(`${here}../mcp`, { recursive: true });
writeFileSync(out, json);
console.log(`wrote ${out} (${(json.length / 1024).toFixed(1)} KB): panels ${names.join(', ')}`);

// Same as assemble(), but keeps the kitchen-sink markers in the MJML so that
// MJML's output can be compared one to one.
function assembleWithMarkers(lib, layout, fill) {
  let m = `${lib.mjml.open}${raw('content')}`, x = '';
  layout.forEach((panel, i) => {
    const p = lib.panels[panel.type];
    if (i > 0) { m += raw('gap') + lib.mjml.gap; x += '<!--kx:gap-->' + lib.html.gap; }
    m += raw('p') + p.mjml.parts[0]; x += '<!--kx:p-->' + p.html.parts[0];
    Object.keys(p.areas).forEach((area, a) => {
      for (const item of panel[area] ?? []) {
        const e = p.areas[area][item.type];
        m += raw('e') + fill(e.mjml, item); x += '<!--kx:e-->' + fill(e.html, item);
      }
      m += raw('end') + p.mjml.parts[a + 1]; x += '<!--kx:end-->' + p.html.parts[a + 1];
    });
  });
  m += raw('gap');
  return { mjml: `${m}${raw('content-end')}${lib.mjml.close}`, html: lib.html.document.replace('<!--kx:content-->', x + '<!--kx:gap-->') };
}
