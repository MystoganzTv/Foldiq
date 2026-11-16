// Captures Microsoft Store screenshots of the real Windows renderer (desktop/dist)
// running in Edge on Windows, so text uses Segoe UI exactly as customers see it.
// The Electron bridge (window.foldiq) is replaced by an in-page stand-in that
// serves the fixture library; every screen, string and style is the app's own.
//
// Usage (on Windows, after `npx vite build`):
//   npm i --no-save playwright-core
//   node scripts/store-screenshots/capture.js <output folder>
const fs = require('fs');
const http = require('http');
const path = require('path');
const { chromium } = require('playwright-core');
const { buildFixture } = require('./fixture');

const DIST = path.join(__dirname, '..', '..', 'dist');
const OUT = path.resolve(process.argv[2] || 'store-screenshots');
const VIEWPORT = { width: 1366, height: 768 };

function serve() {
  const types = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.png': 'image/png' };
  const server = http.createServer((req, res) => {
    const urlPath = decodeURIComponent(new URL(req.url, 'http://x').pathname);
    const file = path.join(DIST, urlPath === '/' ? 'index.html' : urlPath);
    if (!file.startsWith(DIST) || !fs.existsSync(file)) { res.writeHead(404); res.end(); return; }
    res.writeHead(200, { 'Content-Type': types[path.extname(file)] || 'application/octet-stream' });
    fs.createReadStream(file).pipe(res);
  });
  return new Promise(resolve => server.listen(0, '127.0.0.1', () => resolve(server)));
}

function thumbnails() {
  const folder = path.join(__dirname, 'thumbs');
  return fs.readdirSync(folder).filter(name => name.endsWith('.jpg')).sort()
    .map(name => `data:image/jpeg;base64,${fs.readFileSync(path.join(folder, name)).toString('base64')}`);
}

// Runs inside the page before the app loads.
function installBridge({ fixture, thumbs }) {
  const listeners = {};
  const on = channel => callback => { listeners[channel] = callback; };
  const emit = (channel, value) => listeners[channel]?.(value);
  const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
  // The first screen shows the free-trial card; later screens show the full version.
  window.__license = { isTrial: true, limit: 100, used: 0, remaining: 100 };
  let thumbIndex = 0;
  const thumbFor = new Map();

  window.foldiq = {
    selectFolders: async () => fixture.folders,
    selectArchives: async () => [],
    selectOutput: async () => fixture.output,
    getPathForFile: file => file.path,
    filterSources: async paths => paths,
    getAppInfo: async () => ({ version: '1.0.20', platform: 'win32' }),
    getPreferences: async () => fixture.config,
    savePreferences: async value => value,
    getLicense: async () => window.__license,
    buyFullVersion: async () => true,

    startScan: async () => {
      const total = fixture.files.length;
      for (const share of [0.2, 0.55, 0.9]) {
        emit('scan:progress', { phase: 'metadata', current: Math.floor(total * share), total, file: fixture.files[Math.floor(total * share)].name });
        await wait(120);
      }
      return { files: fixture.files, archivesExtracted: 0, warnings: [] };
    },
    cancelScan: async () => true,
    onScanProgress: on('scan:progress'),
    getThumbnail: async filePath => {
      if (!thumbFor.has(filePath)) thumbFor.set(filePath, thumbs[thumbIndex++ % thumbs.length]);
      return thumbFor.get(filePath);
    },

    buildPlan: async () => { await wait(300); return fixture.plan; },
    onPlanProgress: on('plan:progress'),

    startApply: async plan => {
      const moves = plan.filter(item => item.action !== 'skip' && item.included !== false);
      for (const share of [0.25, 0.5, 0.75]) {
        emit('apply:progress', { current: Math.floor(moves.length * share), total: moves.length, file: moves[Math.floor(moves.length * share)].name });
        await wait(150);
      }
      if (window.__holdApply) await new Promise(resolve => { window.__releaseApply = resolve; });
      return {
        moved: moves.length,
        skipped: plan.length - moves.length,
        errors: [],
        manifestPath: 'undo-1.json',
        manifestPaths: ['undo-1.json'],
        completed: moves.map(item => ({ path: item.path, destPath: item.destPath, action: item.action })),
        trialHeld: 0,
      };
    },
    retryApply: async () => ({ moved: 0, errors: [], manifestPaths: [], completed: [] }),
    onApplyProgress: on('apply:progress'),
    undoApply: async () => ({ restored: 0, errors: [] }),
    undoAll: async () => ({ restored: 0, errors: [], manifestPaths: [] }),
    onUndoProgress: on('undo:progress'),
    getPendingUndo: async () => [],
    discardUndo: async () => true,
    discardUndoAll: async () => true,
    countEmptyFolders: async () => 0,
    removeEmptyFolders: async () => ({ removed: 0 }),

    openFolder: async () => {},
    revealFile: async () => {},
    openAttribution: async () => true,
    openDiagnosticsForm: async () => true,
    copyDiagnostics: async () => true,

    recordOrganizationSuccess: async () => false,
    dismissReviewInvite: async () => true,
    openReviewForm: async () => true,

    getWatchState: async () => ({ enabled: false, folder: '', active: false, history: [], lastEvent: null }),
    chooseWatchFolder: async () => null,
    configureWatch: async () => ({ enabled: false, folder: '', active: false, history: [], lastEvent: null }),
    undoWatchRun: async () => ({ restored: 0, errors: [] }),
    onWatchEvent: on('watch:event'),

    exportCSV: async () => null,
    removeAllListeners: channel => { delete listeners[channel]; },
  };
}

async function main() {
  fs.mkdirSync(OUT, { recursive: true });
  const fixture = buildFixture();
  const server = await serve();
  const browser = await chromium.launch({ channel: process.env.SCREENSHOT_BROWSER || 'msedge' });
  const page = await browser.newPage({ viewport: VIEWPORT, deviceScaleFactor: 2, timezoneId: 'UTC' });
  page.on('pageerror', error => console.error('page error:', error.message));
  await page.addInitScript(installBridge, { fixture, thumbs: thumbnails() });

  const shot = async name => {
    await page.waitForTimeout(700);
    await page.screenshot({ path: path.join(OUT, `${name}.png`) });
    console.log('saved', name);
  };
  const button = text => page.getByRole('button', { name: text });

  await page.goto(`http://127.0.0.1:${server.address().port}/`);
  await button('+ Add Folders').click();
  await shot('1 Choose folders');

  await page.evaluate(() => { window.__license = { isTrial: false, limit: 100, used: 0, remaining: null }; });
  await button('Scan Items →').click();
  await button('Configure Organization →').waitFor({ state: 'visible' });
  await page.waitForFunction(() => [...document.querySelectorAll('button')].some(b => b.textContent.includes('Configure Organization') && !b.disabled));
  await shot('2 Scan results');

  await button('Configure Organization →').click();
  await shot('3 Organization settings');

  await button('Preview Organization →').click();
  await page.getByText('Review your photos').waitFor();
  const firstRow = () => page.locator('[role="button"]').filter({ hasText: /\.(jpg|heic|png|mp4|mov)/i }).first();
  await firstRow().click();
  await page.waitForSelector('img[src^="data:image"]', { timeout: 10000 }).catch(() => {});
  await shot('4 Preview every change');

  await button(/^Duplicates/).click();
  await firstRow().click();
  await shot('5 Duplicates set aside');
  await button(/^All/).click();

  await page.getByRole('button', { name: 'Preview folder structure' }).click();
  await shot('6 Planned folder structure');
  await button('Done').click();

  await page.getByRole('button', { name: /Organize [\d,]+ Files/ }).click();
  await shot('7 Review before moving');

  await button(/Move Files Now/).click();
  await button(/View Report/).waitFor({ timeout: 15000 });
  await button(/View Report/).click();
  await shot('8 Report with undo');

  await browser.close();
  server.close();
}

main().catch(error => { console.error(error); process.exit(1); });
