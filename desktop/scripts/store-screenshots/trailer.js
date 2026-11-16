// Records a ~35-second trailer of the real Windows renderer (desktop/dist) in
// Edge on Windows: the same sample library and Electron stand-in as the
// screenshots, wrapped in a branded frame with one short headline per step and
// a visible cursor. Frames come from Chrome's screencast, so every animation
// is the app's own. Output: frames + timeline, then ffmpeg encodes 1080p MP4s.
//
// Usage (after `npx vite build`):
//   npm i --no-save playwright-core ffmpeg-static
//   node scripts/store-screenshots/trailer.js <output folder>
const fs = require('fs');
const http = require('http');
const path = require('path');
const { execFileSync } = require('child_process');
const { chromium } = require('playwright-core');
const { buildFixture } = require('./fixture');

const DIST = path.join(__dirname, '..', '..', 'dist');
const ICON = path.join(__dirname, '..', '..', 'assets', 'icon.png');
const OUT = path.resolve(process.argv[2] || 'trailer-out');
const FRAMES = path.join(OUT, 'frames');
const FPS = 30;

const ENDINGS = {
  store: { line1: 'Try it free', line2: 'Organize your first 100 files. Undo always works.' },
  web: { line1: 'Safe. Local. Undoable.', line2: 'Foldiq for Windows and Mac · foldiq.app' },
};

function wrapperPage() {
  return `<!doctype html><html><head><meta charset="utf-8"><style>
  html,body{margin:0;width:1280px;height:720px;overflow:hidden;background:#140f3a;font-family:'Segoe UI Variable Display','Segoe UI',system-ui,sans-serif}
  .bg{position:absolute;inset:0;background:radial-gradient(1200px 600px at 20% -10%,#5143c4 0%,rgba(81,67,196,0) 60%),radial-gradient(900px 500px at 110% 120%,#2563eb 0%,rgba(37,99,235,0) 55%),linear-gradient(160deg,#1b1450,#0f0b2e)}
  #headline{position:absolute;left:0;right:0;top:20px;text-align:center;color:#fff;font-size:30px;font-weight:600;letter-spacing:-.3px;transition:opacity .35s ease,transform .35s ease}
  #headline.hide{opacity:0;transform:translateY(-6px)}
  #frame{position:absolute;left:80px;top:80px;width:1120px;height:620px;border-radius:12px;overflow:hidden;box-shadow:0 30px 80px rgba(0,0,0,.45),0 0 0 1px rgba(255,255,255,.12);background:#fff;transition:opacity .5s ease}
  #app{width:1120px;height:620px;border:0;display:block}
  #cursor{position:absolute;left:640px;top:400px;width:22px;height:22px;z-index:20;pointer-events:none;transition:left .55s cubic-bezier(.3,.8,.3,1),top .55s cubic-bezier(.3,.8,.3,1);filter:drop-shadow(0 2px 3px rgba(0,0,0,.35))}
  #cursor.hidden{opacity:0}
  .ripple{position:absolute;width:34px;height:34px;margin:-17px 0 0 -17px;border-radius:50%;border:2px solid rgba(81,67,196,.9);z-index:19;pointer-events:none;animation:rip .45s ease-out forwards}
  @keyframes rip{from{transform:scale(.3);opacity:1}to{transform:scale(1.4);opacity:0}}
  .card{position:absolute;inset:0;z-index:30;background:radial-gradient(1200px 600px at 20% -10%,#5143c4 0%,rgba(81,67,196,0) 60%),radial-gradient(900px 500px at 110% 120%,#2563eb 0%,rgba(37,99,235,0) 55%),linear-gradient(160deg,#1b1450,#0f0b2e);display:flex;flex-direction:column;align-items:center;justify-content:center;color:#fff;transition:opacity .6s ease}
  .card.hide{opacity:0;pointer-events:none}
  .card img{width:112px;height:112px;margin-bottom:22px;filter:drop-shadow(0 18px 30px rgba(0,0,0,.35))}
  .card h1{margin:0;font-size:64px;font-weight:700;letter-spacing:-1px}
  .card p{margin:12px 0 0;font-size:24px;color:#c7c2ff}
  .card .small{margin-top:26px;font-size:18px;color:#a5a0e6}
  </style></head><body><div class="bg"></div>
  <div id="headline" class="hide"></div>
  <div id="frame"><iframe id="app" src="/index.html"></iframe></div>
  <svg id="cursor" class="hidden" viewBox="0 0 24 24"><path d="M3 2l7.5 19 2.6-7.4L20.5 11z" fill="#fff" stroke="#111" stroke-width="1.4" stroke-linejoin="round"/></svg>
  <div id="intro" class="card"><img src="/brand-icon.png"><h1>Foldiq</h1><p>Turn years of messy photos into clean folders</p></div>
  <div id="outro" class="card hide"><img src="/brand-icon.png"><h1 id="o1"></h1><p id="o2"></p></div>
  <script>
    window.setHeadline = text => { const h = document.getElementById('headline'); h.classList.add('hide'); setTimeout(() => { h.textContent = text; if (text) h.classList.remove('hide'); }, 300); };
    window.cursorTo = (x, y) => { const c = document.getElementById('cursor'); c.classList.remove('hidden'); c.style.left = x + 'px'; c.style.top = y + 'px'; };
    window.ripple = (x, y) => { const r = document.createElement('div'); r.className = 'ripple'; r.style.left = x + 'px'; r.style.top = y + 'px'; document.body.appendChild(r); setTimeout(() => r.remove(), 600); };
    window.showCard = (id, show) => document.getElementById(id).classList.toggle('hide', !show);
  </script></body></html>`;
}

function serve() {
  const types = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.png': 'image/png' };
  const server = http.createServer((req, res) => {
    const urlPath = decodeURIComponent(new URL(req.url, 'http://x').pathname);
    if (urlPath === '/trailer.html') { res.writeHead(200, { 'Content-Type': 'text/html' }); res.end(wrapperPage()); return; }
    const file = urlPath === '/brand-icon.png' ? ICON : path.join(DIST, urlPath === '/' ? 'index.html' : urlPath);
    if (!(file === ICON || file.startsWith(DIST)) || !fs.existsSync(file)) { res.writeHead(404); res.end(); return; }
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

// Same stand-in as capture.js, with slower progress so it reads on video.
function installBridge({ fixture, thumbs }) {
  if (window.top === window) return; // only the app iframe gets the bridge
  const listeners = {};
  const on = channel => callback => { listeners[channel] = callback; };
  const emit = (channel, value) => listeners[channel]?.(value);
  const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
  let thumbIndex = 0;
  const thumbFor = new Map();
  const noop = async () => true;
  window.foldiq = {
    selectFolders: async () => fixture.folders,
    selectArchives: async () => [],
    selectOutput: async () => fixture.output,
    getPathForFile: file => file.path,
    filterSources: async paths => paths,
    getAppInfo: async () => ({ version: '1.0.20', platform: 'win32' }),
    getPreferences: async () => fixture.config,
    savePreferences: async value => value,
    getLicense: async () => ({ isTrial: false, limit: 100, used: 0, remaining: null }),
    buyFullVersion: noop,
    startScan: async () => {
      const total = fixture.files.length;
      for (let step = 1; step <= 12; step++) {
        const current = Math.floor(total * step / 12);
        emit('scan:progress', { phase: step < 9 ? 'metadata' : 'duplicates', current, total, file: fixture.files[Math.min(current, total - 1)].name });
        await wait(190);
      }
      return { files: fixture.files, archivesExtracted: 0, warnings: [] };
    },
    cancelScan: noop,
    onScanProgress: on('scan:progress'),
    getThumbnail: async filePath => {
      if (!thumbFor.has(filePath)) thumbFor.set(filePath, thumbs[thumbIndex++ % thumbs.length]);
      return thumbFor.get(filePath);
    },
    buildPlan: async () => { await wait(700); return fixture.plan; },
    onPlanProgress: on('plan:progress'),
    startApply: async plan => {
      const moves = plan.filter(item => item.action !== 'skip' && item.included !== false);
      for (let step = 1; step <= 14; step++) {
        const current = Math.floor(moves.length * step / 14);
        emit('apply:progress', { current, total: moves.length, file: moves[Math.min(current, moves.length - 1)].name });
        await wait(160);
      }
      return {
        moved: moves.length, skipped: plan.length - moves.length, errors: [],
        manifestPath: 'undo-1.json', manifestPaths: ['undo-1.json'],
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
    discardUndo: noop, discardUndoAll: noop,
    countEmptyFolders: async () => 0,
    removeEmptyFolders: async () => ({ removed: 0 }),
    openFolder: noop, revealFile: noop, openAttribution: noop, openDiagnosticsForm: noop, copyDiagnostics: noop,
    recordOrganizationSuccess: async () => false, dismissReviewInvite: noop, openReviewForm: noop,
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
  fs.mkdirSync(FRAMES, { recursive: true });
  const fixture = buildFixture();
  const server = await serve();
  const browser = await chromium.launch({ channel: process.env.SCREENSHOT_BROWSER || 'msedge' });
  const page = await browser.newPage({ viewport: { width: 1280, height: 720 }, deviceScaleFactor: 1.5, timezoneId: 'UTC' });
  page.on('pageerror', error => console.error('page error:', error.message));
  await page.addInitScript(installBridge, { fixture, thumbs: thumbnails() });
  await page.goto(`http://127.0.0.1:${server.address().port}/trailer.html`);
  const app = page.frameLocator('#app');
  await app.getByRole('button', { name: '+ Add Folders' }).waitFor();
  await page.waitForTimeout(800);

  // ── Recording ──
  const cdp = await page.context().newCDPSession(page);
  const timeline = [];
  cdp.on('Page.screencastFrame', async frame => {
    const index = timeline.length;
    const file = `f${String(index).padStart(5, '0')}.jpg`;
    fs.writeFileSync(path.join(FRAMES, file), Buffer.from(frame.data, 'base64'));
    timeline.push({ file, t: frame.metadata.timestamp });
    cdp.send('Page.screencastFrameAck', { sessionId: frame.sessionId }).catch(() => {});
  });
  // A tiny always-changing pixel keeps frames flowing while the screen is still.
  await page.evaluate(() => {
    const tick = document.createElement('div');
    tick.style.cssText = 'position:fixed;right:0;bottom:0;width:1px;height:1px;z-index:99';
    document.body.appendChild(tick);
    let on = false;
    setInterval(() => { on = !on; tick.style.background = on ? 'rgba(15,11,46,.99)' : 'rgba(15,11,46,1)'; }, 33);
  });
  await cdp.send('Page.startScreencast', { format: 'jpeg', quality: 94, maxWidth: 1920, maxHeight: 1080, everyNthFrame: 1 });

  const pause = ms => page.waitForTimeout(ms);
  const headline = async text => { await page.evaluate(t => window.setHeadline(t), text); await pause(450); };
  const click = async (locator, { hold = 250 } = {}) => {
    await locator.waitFor({ state: 'visible' });
    const box = await locator.boundingBox();
    const x = box.x + box.width / 2;
    const y = box.y + box.height / 2;
    await page.evaluate(([px, py]) => window.cursorTo(px, py), [x, y]);
    await pause(650);
    await page.evaluate(([px, py]) => window.ripple(px, py), [x, y]);
    await locator.click();
    await pause(hold);
  };
  const button = text => app.getByRole('button', { name: text });

  await pause(1800);                                   // intro card
  await page.evaluate(() => window.showCard('intro', false));
  await pause(500);

  await headline('Add folders, ZIP archives or a Google Takeout export');
  await click(button('+ Add Folders'), { hold: 1000 });

  await headline('Foldiq finds the real date of every photo');
  await click(button('Scan Items →'));
  await app.locator('button:not([disabled])', { hasText: 'Configure Organization' }).waitFor({ timeout: 15000 });
  await pause(1700);

  await headline('Choose how your folders are built');
  await click(button('Configure Organization →'), { hold: 500 });
  const smart = app.locator('[class*="radioCard"]').first();
  const sb = await smart.boundingBox();
  await page.evaluate(([px, py]) => window.cursorTo(px, py), [sb.x + sb.width * 0.35, sb.y + sb.height / 2]);
  await pause(1500);

  await headline('Preview every move before anything changes');
  await click(button('Preview Organization →'));
  await app.getByText('Review your photos').waitFor();
  await pause(500);
  const rows = app.locator('[role="button"]').filter({ hasText: /\.(jpg|heic|png|mp4|mov)/i });
  await click(rows.nth(1), { hold: 700 });
  const listBox = await rows.nth(3).boundingBox();
  await page.mouse.move(listBox.x + 200, listBox.y);
  for (let i = 0; i < 10; i++) { await page.mouse.wheel(0, 70); await pause(60); }
  await pause(500);

  await headline('Duplicates are set aside, never deleted');
  await click(button(/^Duplicates/), { hold: 400 });
  await click(rows.first(), { hold: 1300 });

  await headline('See the folder structure before it exists');
  await click(app.getByRole('button', { name: 'Preview folder structure' }), { hold: 1700 });
  await click(button('Done'), { hold: 200 });

  await headline('One click to organize thousands of files');
  await click(app.getByRole('button', { name: /Organize [\d,]+ Files/ }), { hold: 500 });
  await click(button(/Move Files Now/));
  await button(/View Report/).waitFor({ timeout: 20000 });
  await pause(700);

  await headline('…and one click to undo it all');
  await click(button(/View Report/), { hold: 500 });
  const undo = app.getByRole('button', { name: '↩ Undo', exact: true });
  const ub = await undo.boundingBox();
  await page.evaluate(([px, py]) => window.cursorTo(px, py), [ub.x + ub.width / 2, ub.y + ub.height / 2]);
  await pause(2200);

  await cdp.send('Page.stopScreencast');
  const mainEnd = Date.now() / 1000;

  // ── Endings: rendered as stills, faded in by ffmpeg ──
  await page.evaluate(() => { document.getElementById('cursor').classList.add('hidden'); window.setHeadline(''); });
  const endings = {};
  for (const [name, text] of Object.entries(ENDINGS)) {
    await page.evaluate(t => {
      document.getElementById('o1').textContent = t.line1;
      document.getElementById('o2').textContent = t.line2;
      document.getElementById('outro').style.transition = 'none';
      window.showCard('outro', true);
    }, text);
    await pause(400);
    endings[name] = path.join(OUT, `ending-${name}.png`);
    await page.screenshot({ path: endings[name] });
  }
  // Title card for thumbnails.
  await page.evaluate(() => { window.showCard('outro', false); document.getElementById('intro').style.transition = 'none'; window.showCard('intro', true); });
  await pause(300);
  await page.screenshot({ path: path.join(OUT, 'title-card.png') });

  await browser.close();
  server.close();

  // ── Encode ──
  const list = [];
  for (let i = 0; i < timeline.length; i++) {
    const next = i + 1 < timeline.length ? timeline[i + 1].t : timeline[i].t + 0.6;
    list.push(`file '${path.join(FRAMES, timeline[i].file).replace(/\\/g, '/')}'`, `duration ${Math.max(0.001, next - timeline[i].t).toFixed(4)}`);
  }
  list.push(`file '${path.join(FRAMES, timeline.at(-1).file).replace(/\\/g, '/')}'`);
  fs.writeFileSync(path.join(OUT, 'frames.txt'), list.join('\n'));
  const ffmpeg = process.env.FFMPEG || require('ffmpeg-static');
  const mainVideo = path.join(OUT, 'main.mp4');
  execFileSync(ffmpeg, ['-y', '-f', 'concat', '-safe', '0', '-i', path.join(OUT, 'frames.txt'),
    '-vf', `fps=${FPS},scale=1920:1080:flags=lanczos,format=yuv420p`, '-c:v', 'libx264', '-preset', 'slow', '-crf', '16', mainVideo], { stdio: 'inherit' });
  const names = { store: 'Foldiq trailer for Microsoft Store.mp4', web: 'Foldiq trailer for the website.mp4' };
  for (const [name, still] of Object.entries(endings)) {
    execFileSync(ffmpeg, ['-y', '-i', mainVideo, '-loop', '1', '-t', '3.6', '-i', still,
      '-filter_complex',
      `[0:v]fps=${FPS},format=yuv420p,setpts=PTS-STARTPTS[a];[1:v]scale=1920:1080,fps=${FPS},format=yuv420p,setpts=PTS-STARTPTS[b];[a][b]xfade=transition=fade:duration=0.6:offset=OFFSET[v]`
        .replace('OFFSET', String(Math.max(0, probeDuration(ffmpeg, mainVideo) - 0.6))),
      '-map', '[v]', '-c:v', 'libx264', '-preset', 'slow', '-crf', name === 'web' ? '22' : '17', '-pix_fmt', 'yuv420p', '-movflags', '+faststart',
      path.join(OUT, names[name])], { stdio: 'inherit' });
  }
  console.log('frames', timeline.length, 'seconds', (timeline.at(-1).t - timeline[0].t).toFixed(1), 'main end', mainEnd);
}

function probeDuration(ffmpeg, file) {
  try {
    execFileSync(ffmpeg, ['-i', file], { stdio: 'pipe' });
  } catch (error) {
    const match = String(error.stderr).match(/Duration: (\d+):(\d+):([\d.]+)/);
    if (match) return Number(match[1]) * 3600 + Number(match[2]) * 60 + Number(match[3]);
  }
  throw new Error('Could not read the video duration');
}

main().catch(error => { console.error(error); process.exit(1); });
