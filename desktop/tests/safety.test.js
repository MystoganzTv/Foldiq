const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const mover = require('../electron/services/mover');
const planner = require('../electron/services/planner');
const scanner = require('../electron/services/scanner');
const { escapeCSVCell, rowsToCSV } = require('../electron/services/csv');

function applyConfig(dir, overrides = {}) {
  return {
    outputFolder: path.join(dir, 'output'),
    manifestDirectory: path.join(dir, 'internal', 'undo'),
    copyMode: true,
    ...overrides,
  };
}

function tempDir(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'foldiq-test-'));
  t.after(async () => {
    await scanner.end();
    fs.rmSync(dir, { recursive: true, force: true });
  });
  return dir;
}

test('planner never selects an existing destination', (t) => {
  const dir = tempDir(t);
  const existing = path.join(dir, 'photo.jpg');
  fs.writeFileSync(existing, 'existing');

  const resolved = planner.resolveCollision(existing, new Set());
  assert.equal(resolved, path.join(dir, 'photo_1.jpg'));
});

test('planner resolves collisions for extensionless files', (t) => {
  const dir = tempDir(t);
  const existing = path.join(dir, 'README');
  fs.writeFileSync(existing, 'existing');

  assert.equal(planner.resolveCollision(existing, new Set()), path.join(dir, 'README_1'));
});

test('planner copies extracted archive media even when Move is selected', (t) => {
  const dir = tempDir(t);
  const plan = planner.buildPlan([{
    id: 1,
    path: path.join(dir, 'temporary', 'photo.jpg'),
    name: 'photo.jpg',
    date: '2026-08-11T12:00:00.000Z',
    archiveSourcePath: path.join(dir, 'photos.zip'),
    isDuplicate: false,
  }], {
    outputFolder: path.join(dir, 'output'),
    groupByMonth: false,
    groupByDay: false,
    copyMode: false,
    skipDuplicates: true,
  });

  assert.equal(plan[0].action, 'copy');
  assert.equal(plan[0].included, true);
});

test('apply leaves files excluded by the user untouched', async (t) => {
  const dir = tempDir(t);
  const source = path.join(dir, 'source.jpg');
  const destination = path.join(dir, 'output', 'source.jpg');
  fs.writeFileSync(source, 'original');

  const result = await mover.apply([
    {
      name: 'source.jpg',
      path: source,
      destPath: destination,
      action: 'move',
      included: false,
    },
  ], applyConfig(dir, { copyMode: false }), () => {});

  assert.equal(result.moved, 0);
  assert.equal(result.skipped, 1);
  assert.equal(fs.readFileSync(source, 'utf8'), 'original');
  assert.equal(fs.existsSync(destination), false);
});

test('apply refuses to overwrite a destination created after preview', async (t) => {
  const dir = tempDir(t);
  const source = path.join(dir, 'source.jpg');
  const destination = path.join(dir, 'output', 'source.jpg');
  fs.writeFileSync(source, 'original');
  fs.mkdirSync(path.dirname(destination));
  fs.writeFileSync(destination, 'do not overwrite');

  const result = await mover.apply([
    { name: 'source.jpg', path: source, destPath: destination, action: 'copy' },
  ], applyConfig(dir), () => {});

  assert.equal(result.moved, 0);
  assert.equal(result.errors.length, 1);
  assert.equal(fs.readFileSync(destination, 'utf8'), 'do not overwrite');
  assert.equal(path.dirname(result.manifestPath), path.join(dir, 'internal', 'undo'));
  assert.equal(fs.readdirSync(path.join(dir, 'output')).some(name => name.endsWith('.json')), false);
});

test('Undo removes an unchanged copy and deletes its completed manifest', async (t) => {
  const dir = tempDir(t);
  const source = path.join(dir, 'source.jpg');
  const destination = path.join(dir, 'output', 'source.jpg');
  fs.writeFileSync(source, 'original');

  const applied = await mover.apply([
    { name: 'source.jpg', path: source, destPath: destination, action: 'copy' },
  ], applyConfig(dir), () => {});
  const undone = await mover.undo(applied.manifestPath);

  assert.equal(undone.restored, 1);
  assert.deepEqual(undone.errors, []);
  assert.equal(fs.existsSync(destination), false);
  assert.equal(fs.existsSync(applied.manifestPath), false);
});

test('Undo refuses to delete a file changed after organization', async (t) => {
  const dir = tempDir(t);
  const source = path.join(dir, 'source.jpg');
  const destination = path.join(dir, 'output', 'source.jpg');
  fs.writeFileSync(source, 'original');

  const applied = await mover.apply([
    { name: 'source.jpg', path: source, destPath: destination, action: 'copy' },
  ], applyConfig(dir), () => {});
  fs.writeFileSync(destination, 'changed later');
  const undone = await mover.undo(applied.manifestPath);

  assert.equal(undone.restored, 0);
  assert.equal(undone.errors.length, 1);
  assert.equal(fs.readFileSync(destination, 'utf8'), 'changed later');
  assert.equal(fs.existsSync(applied.manifestPath), true);
});

test('moving files never removes the user-selected source root', async (t) => {
  const dir = tempDir(t);
  const sourceRoot = path.join(dir, 'source');
  const source = path.join(sourceRoot, 'nested', 'photo.jpg');
  const destination = path.join(dir, 'output', 'photo.jpg');
  fs.mkdirSync(path.dirname(source), { recursive: true });
  fs.writeFileSync(source, 'original');

  const applied = await mover.apply([
    { name: 'photo.jpg', path: source, destPath: destination, action: 'move' },
  ], {
    outputFolder: path.join(dir, 'output'),
    copyMode: false,
    sourceFolders: [sourceRoot],
    manifestDirectory: path.join(dir, 'internal', 'undo'),
  }, () => {});

  assert.equal(applied.errors.length, 0);
  assert.equal(fs.existsSync(sourceRoot), true);
  assert.equal(fs.existsSync(path.join(sourceRoot, 'nested')), false);
});

test('scanner hashes media with streaming SHA-256', async (t) => {
  const dir = tempDir(t);
  const file = path.join(dir, 'large-video.mp4');
  const contents = Buffer.alloc(1024 * 1024, 7);
  fs.writeFileSync(file, contents);

  assert.equal(
    await scanner.hashFile(file),
    crypto.createHash('sha256').update(contents).digest('hex')
  );
});

test('Start Over discards only an internal Foldiq Undo manifest', async (t) => {
  const dir = tempDir(t);
  const internal = path.join(dir, 'internal', 'undo');
  const source = path.join(dir, 'source.jpg');
  const destination = path.join(dir, 'output', 'source.jpg');
  fs.writeFileSync(source, 'original');

  const applied = await mover.apply([
    { name: 'source.jpg', path: source, destPath: destination, action: 'copy' },
  ], applyConfig(dir), () => {});

  mover.discardManifest(applied.manifestPath, internal);
  assert.equal(fs.existsSync(applied.manifestPath), false);
  assert.throws(
    () => mover.discardManifest(path.join(dir, 'unrelated.json'), internal),
    /Invalid internal Undo manifest path/
  );
});

test('date parsing rejects absurd years and impossible calendar dates', () => {
  const now = new Date('2026-08-11T12:00:00');
  assert.equal(scanner.dateFromFilename('IMG_91610811_120000.jpg', now), null);
  assert.equal(scanner.dateFromFilename('IMG_20260230_120000.jpg', now), null);
  assert.equal(scanner.metadataDate('4917:08:11 12:00:00', now), null);
  assert.equal(scanner.dateFromFilename('IMG_20230228_120000.jpg', now).getFullYear(), 2023);
});

test('planner routes missing or implausible dates to Unknown Date', (t) => {
  const dir = tempDir(t);
  const config = {
    outputFolder: path.join(dir, 'output'),
    groupByMonth: true,
    groupByDay: false,
  };

  assert.equal(
    planner.buildDestPath({ name: 'unknown.jpg', date: null }, config),
    path.join(dir, 'output', 'Unknown Date', 'unknown.jpg')
  );
  assert.equal(
    planner.buildDestPath({ name: 'future.jpg', date: '4917-08-11T00:00:00.000Z' }, config),
    path.join(dir, 'output', 'Unknown Date', 'future.jpg')
  );
});

test('CSV output quotes commas and neutralizes spreadsheet formulas', () => {
  assert.equal(escapeCSVCell('hello,world'), '"hello,world"');
  assert.equal(escapeCSVCell('=HYPERLINK("bad")'), '"\'=HYPERLINK(""bad"")"');
  assert.equal(rowsToCSV([{ name: 'photo,1.jpg', note: '+cmd' }]), '"photo,1.jpg","\'+cmd"');
});
