const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');

const { FolderWatcher, readState, writeState, validateWatch, defaultState } = require('../electron/services/watcher');

function setup() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'foldiq-watch-'));
  const watched = path.join(root, 'Downloads');
  const output = path.join(root, 'Organized');
  fs.mkdirSync(watched);
  fs.mkdirSync(output);
  const statePath = path.join(root, 'state', 'auto-organize.json');
  return { root, watched, output, statePath };
}

function makeWatcher({ watched, output, statePath }, overrides = {}) {
  const calls = [];
  const events = [];
  const clock = { value: Date.now() };
  const watcher = new FolderWatcher({
    now: () => clock.value,
    folder: watched,
    statePath,
    settleMs: 1_000,
    getConfig: () => ({ outputFolder: output, includeVideos: true }),
    organize: async files => { calls.push(files); return { moved: files.length, errors: [], manifestPath: `/m/${calls.length}` }; },
    onEvent: event => events.push(event),
    watchFactory: () => ({ close() {} }),
    ...overrides,
  });
  // Two looks one settle period apart, as the real timer would do.
  const settle = async () => {
    await watcher.flush();
    clock.value += 1_000;
    return watcher.flush();
  };
  return { watcher, calls, events, clock, settle };
}

function writeOld(filePath, content = 'x', ageMs = 60_000) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, content);
  const when = new Date(Date.now() - ageMs);
  fs.utimesSync(filePath, when, when);
}

test('validateWatch refuses a missing output or a watched folder inside the output', () => {
  const env = setup();
  try {
    assert.match(validateWatch({ folder: env.watched, outputFolder: '' }), /output folder/);
    assert.match(validateWatch({ folder: path.join(env.output, 'inbox'), outputFolder: env.output }), /inside the output/);
    assert.match(validateWatch({ folder: path.join(env.root, 'missing'), outputFolder: env.output }), /no longer exists/);
    assert.equal(validateWatch({ folder: env.watched, outputFolder: env.output }), null);
  } finally {
    fs.rmSync(env.root, { recursive: true, force: true });
  }
});

test('state survives a round trip and falls back to defaults when unreadable', () => {
  const env = setup();
  try {
    assert.deepEqual(readState(env.statePath), defaultState());
    writeState(env.statePath, { ...defaultState(), enabled: true, folder: env.watched, enabledAt: 5 });
    const state = readState(env.statePath);
    assert.equal(state.enabled, true);
    assert.equal(state.folder, env.watched);
    assert.equal(state.enabledAt, 5);
  } finally {
    fs.rmSync(env.root, { recursive: true, force: true });
  }
});

test('only finished media files are organized, once each', async () => {
  const env = setup();
  try {
    const { watcher, calls, events, clock, settle } = makeWatcher(env);
    watcher.stopped = false;
    const photo = path.join(env.watched, 'IMG_1.jpg');
    const growing = path.join(env.watched, 'IMG_2.jpg');
    writeOld(photo);
    writeOld(growing, 'still');
    fs.writeFileSync(path.join(env.watched, 'notes.txt'), 'ignored');

    watcher.notice(photo);
    watcher.notice(growing);
    watcher.notice(path.join(env.watched, 'notes.txt'));
    assert.equal(await watcher.flush(), null, 'the first look only records sizes');
    clock.value += 1_000;
    fs.appendFileSync(growing, ' copying');
    const entry = await watcher.flush();

    assert.deepEqual(calls, [[path.resolve(photo)]]);
    assert.equal(entry.organized, 1);
    assert.ok(watcher.pending.has(path.resolve(growing)), 'a file still being written waits for the next run');
    assert.equal(events.find(event => event.type === 'organized').organized, 1);

    // Copy mode leaves the original in place: it must not be organized again.
    watcher.pending.clear();
    watcher.notice(photo);
    assert.equal(await settle(), null);
    assert.equal(calls.length, 1);
    watcher.stop();
  } finally {
    fs.rmSync(env.root, { recursive: true, force: true });
  }
});

test('files inside the output folder are never picked up', () => {
  const env = setup();
  try {
    const inside = { ...env, output: path.join(env.watched, 'Organized') };
    const { watcher } = makeWatcher(inside, { getConfig: () => ({ outputFolder: inside.output }) });
    watcher.stopped = false;
    watcher.notice(path.join(inside.output, '2024', 'IMG_1.jpg'));
    assert.equal(watcher.pending.size, 0);
    watcher.notice(path.join(env.watched, 'IMG_1.jpg'));
    assert.equal(watcher.pending.size, 1);
    watcher.stop();
  } finally {
    fs.rmSync(env.root, { recursive: true, force: true });
  }
});

test('videos are skipped when the settings exclude them', () => {
  const env = setup();
  try {
    const { watcher } = makeWatcher(env, { getConfig: () => ({ outputFolder: env.output, includeVideos: false }) });
    watcher.stopped = false;
    watcher.notice(path.join(env.watched, 'clip.mov'));
    assert.equal(watcher.pending.size, 0);
    watcher.stop();
  } finally {
    fs.rmSync(env.root, { recursive: true, force: true });
  }
});

test('a run waits while a manual scan or apply is in progress', async () => {
  const env = setup();
  try {
    let busy = true;
    const { watcher, calls, settle } = makeWatcher(env, { isBusy: () => busy });
    watcher.stopped = false;
    const photo = path.join(env.watched, 'IMG_1.jpg');
    writeOld(photo);
    watcher.notice(photo);
    assert.equal(await settle(), null);
    assert.equal(calls.length, 0);
    busy = false;
    await settle();
    assert.equal(calls.length, 1);
    watcher.stop();
  } finally {
    fs.rmSync(env.root, { recursive: true, force: true });
  }
});

test('the sweep on start only picks up files that arrived after the watch was turned on', async () => {
  const env = setup();
  try {
    writeOld(path.join(env.watched, 'nested', 'new.jpg'), 'x', 1_000);

    writeState(env.statePath, { ...defaultState(), enabled: true, folder: env.watched, enabledAt: Date.now() + 60_000 });
    const before = makeWatcher(env).watcher;
    before.start();
    await new Promise(resolve => setTimeout(resolve, 50));
    assert.equal(before.pending.size, 0, 'files that were already there are left alone');
    before.stop();

    writeState(env.statePath, { ...defaultState(), enabled: true, folder: env.watched, enabledAt: Date.now() - 60_000 });
    const after = makeWatcher(env).watcher;
    after.start();
    await new Promise(resolve => setTimeout(resolve, 50));
    assert.deepEqual([...after.pending].map(item => path.basename(item)), ['new.jpg']);
    after.stop();
  } finally {
    fs.rmSync(env.root, { recursive: true, force: true });
  }
});

test('history is capped and dropped runs have their manifests discarded', async () => {
  const env = setup();
  try {
    const discarded = [];
    writeState(env.statePath, {
      ...defaultState(),
      history: Array.from({ length: 20 }, (_, index) => ({ at: index, organized: 1, errors: 0, manifestPath: `/old/${index}` })),
    });
    const { watcher, settle } = makeWatcher(env, { discardManifest: manifest => discarded.push(manifest) });
    watcher.stopped = false;
    const photo = path.join(env.watched, 'IMG_9.jpg');
    writeOld(photo);
    watcher.notice(photo);
    await settle();
    assert.equal(readState(env.statePath).history.length, 20);
    assert.deepEqual(discarded, ['/old/19']);
    watcher.stop();
  } finally {
    fs.rmSync(env.root, { recursive: true, force: true });
  }
});
