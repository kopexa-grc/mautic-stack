# Kopexa · Landing Page

Landing page theme for Mautic in the Kopexa brand
([brand.kopexa.com](https://brand.kopexa.com)): white base, text `#10253D`,
Action Blue `#006CB8` for actions, one Navy brand surface with the open route
at the end. Mobile first: base styles are for phones, wider screens add
columns.

![Preview](thumbnail.png)

Sections, each independent (delete or duplicate them in the builder):

1. Header: original logo, link to kopexa.com
2. Hero: short problem line, solution headline, benefit text, three points,
   panel for the form
3. Benefits: three columns, structure instead of boxes
4. Split: product view and text (the image is a placeholder — replace it
   with an approved product screenshot)
5. Questions: native `<details>`, no script
6. Brand surface: claim, question, one action; the route is recomposed for
   narrow and wide screens from the approved motif
7. Footer: imprint and privacy policy

**Form:** drag the builder's *Form* block onto the dashed box in the panel
and pick the Mautic form. The theme styles Mautic's form classes
(`.mauticform-*`): labels, 48 px fields, focus ring, full-width button.

**Copy** follows the brand's writing rules: informal *du*, short problem
line above the solution, no promises of compliance or security, no
invented figures or customer quotes. The texts are examples from
brand.kopexa.com; adapt them to the campaign.

Fonts and logo come from the base theme
([`mautic-theme-kopexa`](../mautic-theme-kopexa)); its `qa/page.mjs` checks
this theme (brand palette and contrast, radii, no shadows, links, copy
rules, no sideways scrolling from 320 to 1280 px, tap targets, one primary
action per section) and renders the thumbnail.
