// Screenshot of a campaign in Mautic's campaign builder (used for docs/img).
//
//   SMOKE_KEEP=1 SMOKE_INFO=/tmp/smoke-info test/smoke.sh <image>   # keeps the instance
//   node test/campaign-screenshot.js <base-url> <campaign-id> <out.png> [width] [height]
//
// Needs Playwright with Chromium. Logs in as the smoke-test admin.
const { chromium } = require('playwright');
(async () => {
  const base = process.argv[2], id = process.argv[3], out = process.argv[4];
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: +(process.argv[5] || 1500), height: +(process.argv[6] || 950) } });
  await page.goto(base + '/s/login');
  await page.fill('input[name="_username"]', 'admin');
  await page.fill('input[name="_password"]', 'Sm0ke-Test-Passw0rd!');
  await Promise.all([page.waitForNavigation(), page.click('button[type="submit"]')]);
  await page.goto(base + '/s/campaigns/edit/' + id);
  await page.waitForTimeout(2500);
  await page.evaluate(() => Mautic.launchCampaignEditor());
  await page.waitForTimeout(3500);
  await page.evaluate(() => { document.querySelectorAll('#CampaignCanvas, .builder-content, .campaign-builder-content, body, html').forEach(e => { e.scrollTop = 0; e.scrollLeft = 0; }); window.scrollTo(0, 0); });
  await page.waitForTimeout(500);
  const names = await page.$$eval('#CampaignCanvas .list-campaign-event .campaign-event-name, #CampaignCanvas .campaign-event-content', els => els.map(e => e.textContent.trim()).filter(Boolean));
  console.log(JSON.stringify(names));
  console.log('connections', await page.$$eval('#CampaignCanvas svg.jtk-connector', e => e.length));
  await page.screenshot({ path: out });
  await browser.close();
})().catch(e => { console.error(e); process.exit(1); });
