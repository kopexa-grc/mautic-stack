// Which theme a QA script works on: `node <script>.mjs [theme-dir]`, default
// the base theme (..). Output goes to dist/<install name>/.
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const here = new URL('.', import.meta.url).pathname;
export const themeDir = resolve(here, process.argv[2] ?? '..');
export const themeName = JSON.parse(readFileSync(`${themeDir}/composer.json`, 'utf8')).extra['install-directory-name'];
export const dist = `${here}dist/${themeName}`;
export const baseDir = resolve(here, '..');

// Sample subject per theme (rendered into <title>, used by deliverability.sh).
export const subject = {
  kopexa: 'Bring die wichtigen Maßnahmen ins Ziel',
  'kopexa-confirm': 'Bitte bestätige deine Anmeldung',
  'kopexa-hero': 'NIS2 ohne Umwege: Webinar in 30 Minuten',
}[themeName] ?? 'Neuigkeiten von Kopexa';
