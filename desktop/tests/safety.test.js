const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const mover = require('../electron/services/mover');
const planner = require('../electron/services/planner');
const scanner = require('../electron/services/scanner');
const geocoder = require('../electron/services/geocoder');
const preferences = require('../electron/services/preferences');
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

test('Windows metadata engine resolves only to the packaged native executable', async (t) => {
  const dir = tempDir(t);
  const resources = path.join(dir, 'resources');
  const executable = path.join(resources, 'exiftool', 'exiftool.exe');
  fs.mkdirSync(path.dirname(executable), { recursive: true });
  fs.writeFileSync(executable, 'MZ-test');

  assert.equal(await scanner.resolveExiftoolExecutable({
    platform: 'win32',
    resourcesPath: resources,
    projectRoot: path.join(dir, 'project'),
  }), executable);
});

test('Windows metadata engine fails clearly when the native runtime is absent', async (t) => {
  const dir = tempDir(t);
  await assert.rejects(
    scanner.resolveExiftoolExecutable({
      platform: 'win32',
      resourcesPath: path.join(dir, 'resources'),
      projectRoot: path.join(dir, 'project'),
    }),
    error => error.code === 'EXIFTOOL_RUNTIME_MISSING'
  );
});

test('metadata recovery splits a failed batch and preserves readable files', async () => {
  const paths = ['one.jpg', 'two.jpg', 'broken.jpg', 'four.jpg'];
  const runner = async candidates => {
    if (candidates.length > 2) throw new Error('slow network batch');
    if (candidates.includes('broken.jpg')) {
      if (candidates.length > 1) throw new Error('isolate damaged file');
      throw new Error('damaged metadata');
    }
    return candidates.map(SourceFile => ({ SourceFile, DateTimeOriginal: '2026:08:12 12:00:00' }));
  };

  const result = await scanner.readMetadataWithRecovery(paths, { runner });
  assert.deepEqual(result.rows.map(row => row.SourceFile), ['one.jpg', 'two.jpg', 'four.jpg']);
  assert.equal(result.failedCount, 1);
  assert.ok(result.splitCount >= 2);
});

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
    duplicateHandling: 'separate',
  });

  assert.equal(plan[0].action, 'copy');
  assert.equal(plan[0].included, true);
});

test('planner separates exact and probable duplicates into explicit folders', (t) => {
  const dir = tempDir(t);
  const outputFolder = path.join(dir, 'output');
  const plan = planner.buildPlan([
    { id: 1, path: path.join(dir, 'exact.jpg'), name: 'exact.jpg', isDuplicate: true },
    { id: 2, path: path.join(dir, 'probable.jpg'), name: 'probable.jpg', isProbableDuplicate: true },
  ], { outputFolder, duplicateHandling: 'separate', copyMode: true });

  assert.equal(plan[0].destPath, path.join(outputFolder, 'Duplicates', 'Exact Duplicates', 'exact.jpg'));
  assert.equal(plan[1].destPath, path.join(outputFolder, 'Duplicates', 'Probable Duplicates', 'probable.jpg'));
  assert.ok(plan.every(file => file.action === 'copy' && file.included));
});

test('planner can leave duplicate extras untouched', (t) => {
  const dir = tempDir(t);
  const plan = planner.buildPlan([{
    id: 1,
    path: path.join(dir, 'duplicate.jpg'),
    name: 'duplicate.jpg',
    isDuplicate: true,
  }], { outputFolder: path.join(dir, 'output'), duplicateHandling: 'skip' });

  assert.equal(plan[0].action, 'skip');
  assert.equal(plan[0].included, false);
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

test('a failed file can be retried later and its retry remains undoable', async (t) => {
  const dir = tempDir(t);
  const source = path.join(dir, 'source.jpg');
  const destination = path.join(dir, 'output', 'source.jpg');
  fs.writeFileSync(source, 'original');
  fs.mkdirSync(path.dirname(destination));
  fs.writeFileSync(destination, 'temporary obstruction');
  const item = { name: 'source.jpg', path: source, destPath: destination, action: 'copy' };

  const first = await mover.apply([item], applyConfig(dir), () => {});
  assert.equal(first.errors[0].path, source);
  assert.equal(first.errors[0].destPath, destination);
  assert.equal(first.errors[0].action, 'copy');

  fs.unlinkSync(destination);
  const retry = await mover.apply([item], applyConfig(dir), () => {});
  assert.equal(retry.errors.length, 0);
  assert.equal(retry.completed.length, 1);
  assert.equal(fs.readFileSync(destination, 'utf8'), 'original');

  const undone = await mover.undo(retry.manifestPath);
  assert.equal(undone.restored, 1);
  assert.equal(fs.existsSync(destination), false);
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

test('moving files keeps empty folders until the user confirms cleanup', async (t) => {
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
  assert.equal(fs.existsSync(path.join(sourceRoot, 'nested')), true);
  assert.equal(mover.findEmptyFolders([sourceRoot]).length, 1);
  assert.equal(mover.removeEmptyFolders([sourceRoot]), 1);
  assert.equal(fs.existsSync(path.join(sourceRoot, 'nested')), false);
  assert.equal(fs.existsSync(sourceRoot), true);
});

test('empty-folder cleanup never enters the organized output folder', (t) => {
  const dir = tempDir(t);
  const sourceRoot = path.join(dir, 'source');
  const emptySourceFolder = path.join(sourceRoot, 'old-empty');
  const outputFolder = path.join(sourceRoot, 'Organized Media');
  const emptyOutputFolder = path.join(outputFolder, '2026');
  fs.mkdirSync(emptySourceFolder, { recursive: true });
  fs.mkdirSync(emptyOutputFolder, { recursive: true });

  assert.deepEqual(mover.findEmptyFolders([sourceRoot], [outputFolder]), [emptySourceFolder]);
  assert.equal(mover.removeEmptyFolders([sourceRoot], [outputFolder]), 1);
  assert.equal(fs.existsSync(emptyOutputFolder), true);
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

test('scanner honors video and archive scan options', async (t) => {
  const dir = tempDir(t);
  fs.writeFileSync(path.join(dir, 'photo.jpg'), 'photo');
  fs.writeFileSync(path.join(dir, 'video.mp4'), 'video');

  const result = await scanner.scan([dir], () => {}, {
    includeVideos: false,
    includeArchives: false,
  });

  assert.deepEqual(result.files.map(file => file.name), ['photo.jpg']);
});

test('scanner stops immediately when cancelled', async (t) => {
  const dir = tempDir(t);
  fs.writeFileSync(path.join(dir, 'photo.jpg'), 'photo');
  const controller = new AbortController();
  controller.abort();

  await assert.rejects(
    scanner.scan([dir], () => {}, { signal: controller.signal }),
    error => error.name === 'AbortError' && /cancelled/i.test(error.message)
  );
});

test('bounded concurrency preserves order without exceeding its limit', async () => {
  let active = 0;
  let peak = 0;
  const result = await scanner.mapWithConcurrency([5, 4, 3, 2, 1], 2, async value => {
    active++;
    peak = Math.max(peak, active);
    await new Promise(resolve => setTimeout(resolve, value));
    active--;
    return value * 10;
  });

  assert.deepEqual(result, [50, 40, 30, 20, 10]);
  assert.equal(peak, 2);
});

test('probable duplicate detector marks only the elected extra', () => {
  const files = [
    { id: 1, name: 'IMG_1000.HEIC', path: '/photos/IMG_1000.HEIC', size: 1000, date: '2024-01-01T10:00:00.000Z', pixelWidth: 100, pixelHeight: 100 },
    { id: 2, name: 'IMG_1000.JPG', path: '/export/nested/IMG_1000.JPG', size: 1005, date: '2024-01-01T10:02:00.000Z', pixelWidth: 100, pixelHeight: 100, archiveSourcePath: '/export.zip' },
  ];

  scanner.detectProbableDuplicates(files);
  assert.equal(files.filter(file => file.isProbableDuplicate).length, 1);
  assert.equal(files[1].isProbableDuplicate, true);
  assert.ok(files[1].probableMatchScore >= 90);
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

test('date selection never treats modification timestamps as capture dates', () => {
  const now = new Date('2026-08-11T12:00:00');
  const selected = scanner.dateFromTrustedMetadata({
    ModifyDate: '2026:08:06 09:30:00',
    FileModifyDate: '2026:08:11 12:00:00',
  }, now);
  assert.equal(selected, null);
});

test('a media file with only a recent filesystem timestamp remains undated', async (t) => {
  const dir = tempDir(t);
  const mediaPath = path.join(dir, 'old-photo-without-metadata.jpg');
  fs.writeFileSync(mediaPath, 'not-real-image-data');
  const misleadingDate = new Date('2026-08-06T09:30:00');
  fs.utimesSync(mediaPath, misleadingDate, misleadingDate);

  assert.equal(await scanner.extractDate(mediaPath, new Date('2026-08-11T12:00:00')), null);
});

test('an older filename date corrects recently replaced embedded metadata', () => {
  const metadata = {
    date: new Date('2026-08-06T09:30:00'),
    source: 'embedded metadata',
    tag: 'CreateDate',
  };
  const filenameDate = new Date('2021-05-14T12:00:00');
  const selected = scanner.resolveDateCandidates(metadata, filenameDate);
  assert.equal(selected.source, 'filename');
  assert.equal(selected.date.getFullYear(), 2021);
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

test('planner uses file timestamps only after explicit opt-in', (t) => {
  const dir = tempDir(t);
  const file = {
    id: 1,
    path: path.join(dir, 'photo.jpg'),
    name: 'photo.jpg',
    date: null,
    fileModifiedDate: '2026-08-12T12:00:00.000Z',
  };
  const base = { outputFolder: path.join(dir, 'output'), groupByMonth: false, groupByDay: false, copyMode: true };

  const conservative = planner.buildPlan([file], { ...base, useFileDateFallback: false });
  assert.match(conservative[0].destPath, /Unknown Date/);

  const estimated = planner.buildPlan([file], { ...base, useFileDateFallback: true });
  assert.match(estimated[0].destPath, /2026/);
  assert.equal(estimated[0].dateSource, 'file date estimate');
  assert.equal(estimated[0].dateEstimated, true);
});

test('Smart Hybrid and By Location use resolved GPS names', (t) => {
  const dir = tempDir(t);
  const outputFolder = path.join(dir, 'output');
  const file = {
    name: 'photo.jpg',
    date: '2026-05-18T12:00:00.000Z',
    location: { country: 'United States', state: 'Virginia', city: 'Herndon' },
  };

  assert.equal(
    planner.buildDestPath(file, {
      outputFolder,
      organizationMode: 'smart',
      groupByMonth: true,
      groupByDay: true,
      useGPSLocation: true,
    }),
    path.join(outputFolder, '2026', '2026-05 May', '2026-05-18 Herndon VA', 'photo.jpg')
  );
  assert.equal(
    planner.buildDestPath(file, {
      outputFolder,
      organizationMode: 'location',
      useGPSLocation: true,
    }),
    path.join(outputFolder, 'United States', 'Virginia', 'Herndon', 'photo.jpg')
  );
});

test('By Location keeps files without GPS in an explicit fallback', (t) => {
  const dir = tempDir(t);
  const outputFolder = path.join(dir, 'output');
  assert.equal(
    planner.buildDestPath({ name: 'photo.jpg', date: '2026-05-18T12:00:00.000Z' }, {
      outputFolder,
      organizationMode: 'location',
      useGPSLocation: true,
    }),
    path.join(outputFolder, 'Unknown Location', '2026', 'photo.jpg')
  );
});

test('GPS lookups are rounded, cached, and do not repeat nearby requests', async (t) => {
  const dir = tempDir(t);
  const cachePath = path.join(dir, 'location-cache.json');
  let requests = 0;
  let requestedURL = '';
  const fetchImpl = async url => {
    requests++;
    requestedURL = url;
    return {
      ok: true,
      json: async () => ({ address: { country: 'United States', state: 'Virginia', city: 'Herndon' } }),
    };
  };
  const files = [
    { name: 'one.jpg', latitude: 38.94972, longitude: -77.40295 },
    { name: 'two.jpg', latitude: 38.95001, longitude: -77.40001 },
  ];

  const first = await geocoder.enrichFiles(files, { enabled: true, cachePath, fetchImpl, requestIntervalMs: 0 });
  const second = await geocoder.enrichFiles(files, { enabled: true, cachePath, fetchImpl, requestIntervalMs: 0 });
  assert.equal(requests, 1);
  assert.match(requestedURL, /lat=38\.95/);
  assert.match(requestedURL, /lon=-77\.4/);
  assert.doesNotMatch(requestedURL, /38\.94972|-77\.40295/);
  assert.equal(first.files[0].location.city, 'Herndon');
  assert.equal(second.files[1].location.state, 'Virginia');
});

test('preferences persist only validated Windows settings', (t) => {
  const dir = tempDir(t);
  const filePath = path.join(dir, 'settings.json');
  const written = preferences.writePreferences(filePath, {
    outputFolder: 'C:\\Photos',
    organizationMode: 'location',
    duplicateHandling: 'skip',
    includeVideos: false,
    includeArchives: true,
    useGPSLocation: true,
    unexpected: 'ignored',
  });

  assert.equal(written.organizationMode, 'location');
  assert.equal(written.groupByMonth, false);
  assert.equal(written.useGPSLocation, true);
  assert.equal('unexpected' in preferences.readPreferences(filePath), false);
});

test('CSV output quotes commas and neutralizes spreadsheet formulas', () => {
  assert.equal(escapeCSVCell('hello,world'), '"hello,world"');
  assert.equal(escapeCSVCell('=HYPERLINK("bad")'), '"\'=HYPERLINK(""bad"")"');
  assert.equal(rowsToCSV([{ name: 'photo,1.jpg', note: '+cmd' }]), '"photo,1.jpg","\'+cmd"');
});
