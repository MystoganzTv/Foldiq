const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const { PNG } = require('pngjs');
const scanner = require('../electron/services/scanner');

const {
  normalizedStem,
  classifyPair,
  markExactDuplicates,
  orientationAwareAspectDifference,
  visualCandidateIndexes,
} = require('../electron/services/smart-duplicates');
const { computeVisualHashes, hammingDistance, minimumVisualDistance } = require('../electron/services/visual-hash');

test('copy and edit suffixes normalize to the same source stem', () => {
  assert.equal(normalizedStem('IMG_1234 copy 2.JPG'), 'img_1234');
  assert.equal(normalizedStem('IMG_1234 (1).HEIC'), 'img_1234');
  assert.equal(normalizedStem('IMG_1234-edited.png'), 'img_1234');
});

test('visual distance is orientation invariant across hash variants', () => {
  assert.equal(hammingDistance('0000000000000000', '000000000000000f'), 4);
  assert.equal(minimumVisualDistance(
    ['ffffffffffffffff', '0000000000000000'],
    ['0f0f0f0f0f0f0f0f', '0000000000000001']
  ), 1);
  assert.equal(orientationAwareAspectDifference(4 / 3, 3 / 4), 0);
});

test('a renamed 90-degree rotation remains a visual candidate', () => {
  const match = classifyPair(
    { name: 'portrait.jpg', size: 1000, date: '2025-01-01T10:00:00Z', pixelWidth: 4000, pixelHeight: 3000, visualHashes: ['0123456789abcdef'] },
    { name: 'renamed.jpg', size: 900, date: '2025-01-01T10:00:01Z', pixelWidth: 3000, pixelHeight: 4000, visualHashes: ['0123456789abcdef'] }
  );
  assert.equal(match.kind, 'same');
});

test('large phone libraries do not hash every same-dimension photo', () => {
  const files = Array.from({ length: 200 }, (_, index) => ({
    ext: '.heic',
    name: `IMG_${String(index).padStart(4, '0')}.HEIC`,
    size: 3_000_000 + index * 1_000,
    date: new Date(Date.UTC(2024, 0, 1 + index, 12, 0, 0)).toISOString(),
    pixelWidth: 4032,
    pixelHeight: 3024,
  }));
  assert.equal(visualCandidateIndexes(files).size, 0);
});

test('bursts and same-name conversions remain visual candidates', () => {
  const files = [
    { ext: '.heic', name: 'IMG_1000.HEIC', size: 4_000_000, date: '2025-05-01T10:00:00Z', pixelWidth: 4032, pixelHeight: 3024 },
    { ext: '.heic', name: 'IMG_1001.HEIC', size: 4_100_000, date: '2025-05-01T10:00:03Z', pixelWidth: 4032, pixelHeight: 3024 },
    { ext: '.jpg', name: 'IMG_9000.JPG', size: 2_000_000, date: '2024-01-01T10:00:00Z', pixelWidth: 4032, pixelHeight: 3024 },
    { ext: '.heic', name: 'IMG_9000.HEIC', size: 4_500_000, date: '2023-01-01T10:00:00Z', pixelWidth: 4032, pixelHeight: 3024 },
  ];
  assert.deepEqual([...visualCandidateIndexes(files)].sort((a, b) => a - b), [0, 1, 2, 3]);
});

test('visual hasher decodes an actual PNG locally', async (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'foldiq-visual-hash-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const image = new PNG({ width: 32, height: 24 });
  for (let y = 0; y < image.height; y++) {
    for (let x = 0; x < image.width; x++) {
      const offset = (y * image.width + x) * 4;
      image.data[offset] = x * 7;
      image.data[offset + 1] = y * 9;
      image.data[offset + 2] = (x + y) * 4;
      image.data[offset + 3] = 255;
    }
  }
  const filePath = path.join(directory, 'pattern.png');
  fs.writeFileSync(filePath, PNG.sync.write(image));
  const hashes = await computeVisualHashes(filePath, image.width, image.height);
  assert.equal(hashes.length, 8);
  assert.ok(hashes.every(hash => /^[0-9a-f]{16}$/.test(hash)));
});

test('full scanner finds the same pixels after a PNG re-encode', async (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'foldiq-smart-scan-'));
  t.after(async () => {
    await scanner.cleanupTempDirs();
    fs.rmSync(directory, { recursive: true, force: true });
  });
  const image = new PNG({ width: 64, height: 48 });
  for (let y = 0; y < image.height; y++) {
    for (let x = 0; x < image.width; x++) {
      const offset = (y * image.width + x) * 4;
      image.data[offset] = (x * 3 + y) % 256;
      image.data[offset + 1] = (y * 5 + x) % 256;
      image.data[offset + 2] = (x * y) % 256;
      image.data[offset + 3] = 255;
    }
  }
  fs.writeFileSync(path.join(directory, 'holiday.png'), PNG.sync.write(image, { deflateLevel: 1, filterType: 0 }));
  fs.writeFileSync(path.join(directory, 'holiday copy.png'), PNG.sync.write(image, { deflateLevel: 9, filterType: 4 }));

  const result = await scanner.scan([directory], () => {}, { includeVideos: false, includeArchives: false });
  assert.equal(result.files.filter(file => file.isDuplicate).length, 0, 're-encoded files have different bytes');
  assert.equal(result.files.filter(file => file.probableDuplicateGroupID).length, 2);
  assert.equal(result.files.filter(file => file.isProbableDuplicate).length, 1);
});

test('a strong visual match can use different filenames and sizes', () => {
  const base = {
    ext: '.jpg',
    date: '2025-05-01T10:00:00.000Z',
    pixelWidth: 4032,
    pixelHeight: 3024,
  };
  const match = classifyPair(
    { ...base, name: 'IMG_0001.JPG', size: 4_000_000, visualHashes: ['0123456789abcdef'] },
    { ...base, name: 'vacation-renamed.JPG', size: 1_800_000, visualHashes: ['0123456789abcdef'] }
  );
  assert.equal(match.kind, 'same');
  assert.ok(match.score >= 94);
});

test('visually close burst photos remain review-only', () => {
  const base = {
    ext: '.jpg',
    size: 4_000_000,
    pixelWidth: 4032,
    pixelHeight: 3024,
  };
  const match = classifyPair(
    { ...base, name: 'IMG_0001.JPG', date: '2025-05-01T10:00:00.000Z', visualHashes: ['0000000000000000'] },
    { ...base, name: 'IMG_0002.JPG', date: '2025-05-01T10:00:02.000Z', visualHashes: ['00000000000000ff'] }
  );
  assert.equal(match.kind, 'burst');
  assert.match(match.reasons, /review only/);
});

test('an explicitly edited version is review-only even when its visual hash is identical', () => {
  const base = {
    ext: '.jpg',
    date: '2025-05-01T10:00:00.000Z',
    size: 4_000_000,
    pixelWidth: 4032,
    pixelHeight: 3024,
    visualHashes: ['0123456789abcdef'],
  };
  const match = classifyPair(
    { ...base, name: 'portrait.JPG' },
    { ...base, name: 'portrait-edited.JPG', size: 3_000_000 }
  );
  assert.equal(match.kind, 'edited');
  assert.match(match.reasons, /review only/);
});

test('similar-photo groups are classified and never marked as movable duplicates', () => {
  const files = [
    { id: 1, ext: '.jpg', name: 'IMG_0200.JPG', path: '/photos/IMG_0200.JPG', date: '2025-05-01T10:00:00.000Z', size: 4_000_000, pixelWidth: 4032, pixelHeight: 3024, visualHashes: ['0000000000000000'] },
    { id: 2, ext: '.jpg', name: 'IMG_0201.JPG', path: '/photos/IMG_0201.JPG', date: '2025-05-01T10:00:02.000Z', size: 4_100_000, pixelWidth: 4032, pixelHeight: 3024, visualHashes: ['00000000000000ff'] },
  ];
  scanner.detectProbableDuplicates(files);
  assert.equal(files.every(file => file.probableMatchKind === 'burst'), true);
  assert.equal(files.every(file => !file.isProbableDuplicate), true);
});

test('exact duplicate election prefers metadata-rich non-archive file', () => {
  const files = [
    { id: 1, hash: 'same', path: '/archive/a.jpg', name: 'a.jpg', size: 10, archiveSourcePath: '/backup.zip' },
    { id: 2, hash: 'same', path: '/photos/a.jpg', name: 'a.jpg', size: 10, date: '2024-01-01', dateSource: 'camera metadata', latitude: 1, longitude: 1 },
    { id: 3, hash: 'same', path: '/deep/copy/a.jpg', name: 'a.jpg', size: 10 },
  ];
  assert.equal(markExactDuplicates(files), 1);
  assert.equal(files[1].isDuplicate, false);
  assert.equal(files[0].duplicateOf, 2);
  assert.equal(files[2].duplicateOf, 2);
  assert.equal(new Set(files.map(file => file.duplicateGroupID)).size, 1);
  assert.ok(files.every(file => file.duplicateGroupID));
});
