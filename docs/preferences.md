# Email preferences (preference center)

Recipients choose which emails they get instead of only unsubscribing from
everything. The link „Abmelden oder Themen wählen“ in the footer of every
Kopexa email opens a page in the Kopexa design (theme
`kopexa-preferences`) with

- **Themen** — one switch per topic (e.g. Webinare & Events, Ressourcen &
  Downloads, Produkt-Updates),
- **Alle E-Mails** — off unsubscribes from everything (*Do Not Contact*),
- one save button and a confirmation.

![Preference page](../image/extensions/mautic-theme-kopexa-preferences/thumbnail.png)

## How topics work

Topics are Mautic **categories** (bundle *global*). An email carries one
category; a contact who switched that topic off gets no email of that
category any more:

| Sent as | Topic switched off | All emails off |
|---|---|---|
| Campaign email (marketing) | not sent (logged in the campaign) | not sent |
| Segment email (newsletter) | not in the send list | not sent |
| Campaign email, *transactional*, without category | sent | not sent |

So:

- **Every marketing email gets its topic** (email → *Category*). Without a
  category the topic switches do not apply to it. The MCP tools set it with
  `category` and warn when a marketing email has none.
- **Service emails** the person asked for (download link after a form,
  access link to a booked webinar, double opt-in) get **no** topic and are
  sent as *transactional* in the campaign step. They contain no marketing.
- *Alle E-Mails* off is final for all of them. Someone who later fills in a
  form again has to be re-subscribed (double opt-in).

Topics are not segments: a segment decides who is targeted, a topic
decides who does not want it. Mautic can also show segments on the page;
this setup does not, so nobody leaves a segment by accident.

## Setup with the Helm chart

```yaml
mautic:
  preferenceCenter:
    topics:
      - name: Webinare & Events
        description: Einladungen und Erinnerungen zu Online-Terminen
      - name: Ressourcen & Downloads
        description: Neue Checklisten, Leitfäden und Vorlagen
      - name: Produkt-Updates
        description: Neue Funktionen und Verbesserungen in Kopexa
    page: {alias: einstellungen, title: E-Mail-Einstellungen}
    # page.language: only an installed Mautic language (default: none)
    # frequency: true    # also offer "fewer emails"
    # pauseDates: true   # also offer a pause
```

At every start the init container (`kopexa:preferences:sync`):

1. creates missing topics (matched by name; descriptions follow the values;
   other categories are not touched, removed topics are not deleted);
2. creates the preference page once from the theme (`page.alias`, default
   `einstellungen`), marks it as preference center and publishes it. After
   that the page is edited in Mautic; set `page.updateContent: true` once
   to re-create its content from the theme (e.g. after a theme update —
   pages built with the builder keep their stored HTML);
3. sets Mautic's unsubscribe settings: show the preferences with the
   topics (not segments), the page as default preference center for all
   emails, and the Kopexa theme for the system pages (unsubscribed,
   re-subscribed).

Nothing is written when everything matches (`unchanged` in the log).
Invalid values stop the init with a list of errors.

Without the chart: create the categories, a landing page with the theme
*Kopexa · E-Mail-Einstellungen* marked as preference center, and set
*Configuration → Email Settings → Unsubscribe settings* (show contact
preferences and categories, default preference center) and *Theme
Settings → default theme Kopexa*.

## Texts

Mautic's own texts on these pages are English unless a language pack is
installed. The Kopexa themes use their own German texts instead:

- email footer: „Abmelden oder Themen wählen“ (`{unsubscribe_url}`) and „Im
  Browser ansehen“ (`{webview_url}`), not Mautic's `{unsubscribe_text}` /
  `{webview_text}` (the theme QA rejects them);
- preference page: German labels wired to Mautic's form fields.

The confirmation after a one-click unsubscribe or a re-subscribe shows
Mautic's message (*Configuration → Email Settings → Unsubscribe message /
Resubscribe message*), in the Kopexa layout. Set German texts there, e.g.
„Du bist abgemeldet und bekommst keine E-Mails mehr von uns. Versehentlich?
\<a href="|URL|"\>Wieder anmelden\</a\>.“

## Fonts and privacy

Mautic's builders offer a list of fonts and load each one with a URL into
every page Mautic renders — by default eight Google Fonts, so every
visitor's IP address went to Google. The image replaces that list
(`editor_fonts`) with the Kopexa brand fonts, self-hosted by the theme
(`themes/kopexa/assets/fonts/kopexa-fonts.css`), and system fonts. Pages and
emails saved earlier still carried the Google links in their HTML; the
init removes those Mautic-injected links
(`kopexa:privacy:strip-third-party-fonts`). Override the list with
`mautic.configParameters.editor_fonts` if needed.

## Tests

`test/smoke.sh` (section *Email preference center*): the init sets up the
declared topics and page and changes nothing the second time; an email with
a topic is sent, its unsubscribe link opens the Kopexa page (one document,
no Google Fonts), switching one topic off is saved for that topic only. The
landing page job of the theme QA (`qa/page.mjs`) checks the theme against
the brand rules and on screen widths from 320 to 1280 px.
