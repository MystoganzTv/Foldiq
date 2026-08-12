const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const zlib = require('node:zlib');
const { execFileSync } = require('node:child_process');
const { path7za } = require('7zip-bin');

const {
  extractArchive,
  extractZip,
  parseTechnicalListing,
  safeRelativePath,
} = require('../electron/services/archive');
const scanner = require('../electron/services/scanner');
const { filterSupportedSources } = require('../electron/services/sources');

function crc32(buffer) {
  let crc = 0xffffffff;
  for (const byte of buffer) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit++) {
      crc = (crc >>> 1) ^ (0xedb88320 & -(crc & 1));
    }
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function createZip(entries) {
  const localParts = [];
  const centralParts = [];
  let offset = 0;

  for (const item of entries) {
    const name = Buffer.from(item.name, 'utf8');
    const contents = Buffer.from(item.contents ?? '');
    const method = item.method ?? 0;
    const compressed = method === 8 ? zlib.deflateRawSync(contents) : contents;
    const checksum = crc32(contents);

    const localHeader = Buffer.alloc(30);
    localHeader.writeUInt32LE(0x04034b50, 0);
    localHeader.writeUInt16LE(20, 4);
    localHeader.writeUInt16LE(0, 6);
    localHeader.writeUInt16LE(method, 8);
    localHeader.writeUInt32LE(checksum, 14);
    localHeader.writeUInt32LE(compressed.length, 18);
    localHeader.writeUInt32LE(contents.length, 22);
    localHeader.writeUInt16LE(name.length, 26);

    localParts.push(localHeader, name, compressed);

    const centralHeader = Buffer.alloc(46);
    centralHeader.writeUInt32LE(0x02014b50, 0);
    centralHeader.writeUInt16LE(20, 4);
    centralHeader.writeUInt16LE(20, 6);
    centralHeader.writeUInt16LE(0, 8);
    centralHeader.writeUInt16LE(method, 10);
    centralHeader.writeUInt32LE(checksum, 16);
    centralHeader.writeUInt32LE(compressed.length, 20);
    centralHeader.writeUInt32LE(contents.length, 24);
    centralHeader.writeUInt16LE(name.length, 28);
    centralHeader.writeUInt32LE(offset, 42);
    centralParts.push(centralHeader, name);

    offset += localHeader.length + name.length + compressed.length;
  }

  const centralDirectory = Buffer.concat(centralParts);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(entries.length, 8);
  end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(centralDirectory.length, 12);
  end.writeUInt32LE(offset, 16);

  return Buffer.concat([...localParts, centralDirectory, end]);
}

function tempDir(t) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'foldiq-archive-test-'));
  t.after(async () => {
    await scanner.end();
    fs.rmSync(directory, { recursive: true, force: true });
  });
  return directory;
}

test('ZIP scanner finds stored and deflated media and ignores other files', async (t) => {
  const directory = tempDir(t);
  const zipPath = path.join(directory, 'photos.zip');
  fs.writeFileSync(zipPath, createZip([
    { name: 'album/one.jpg', contents: 'stored photo' },
    { name: 'album/two.png', contents: 'deflated photo', method: 8 },
    { name: 'notes.txt', contents: 'not media' },
  ]));

  const result = await scanner.scan([directory], () => {});

  assert.equal(result.archivesExtracted, 1);
  assert.deepEqual(result.warnings, []);
  assert.equal(result.files.length, 2);
  assert.ok(result.files.every(file => file.archiveSourcePath === zipPath));
  assert.ok(result.files.every(file => fs.existsSync(file.path)));

  const directResult = await scanner.scan([zipPath], () => {});
  assert.equal(directResult.archivesExtracted, 1);
  assert.equal(directResult.files.length, 2);
});

test('ZIP extraction rejects path traversal', async (t) => {
  const directory = tempDir(t);
  const zipPath = path.join(directory, 'unsafe.zip');
  fs.writeFileSync(zipPath, createZip([
    { name: '../escaped.jpg', contents: 'unsafe' },
  ]));

  await assert.rejects(
    extractZip(zipPath, filePath => path.extname(filePath) === '.jpg'),
    /unsafe path/
  );
  assert.equal(fs.existsSync(path.join(directory, 'escaped.jpg')), false);
});

test('source filtering accepts folders, ZIP, RAR, and 7z but rejects unrelated files', (t) => {
  const directory = tempDir(t);
  const zipPath = path.join(directory, 'photos.ZIP');
  const rarPath = path.join(directory, 'photos.RAR');
  const sevenZipPath = path.join(directory, 'photos.7z');
  const textPath = path.join(directory, 'notes.txt');
  fs.writeFileSync(zipPath, createZip([]));
  fs.writeFileSync(rarPath, 'rar placeholder');
  fs.writeFileSync(sevenZipPath, '7z placeholder');
  fs.writeFileSync(textPath, 'notes');

  assert.deepEqual(
    filterSupportedSources([directory, zipPath, rarPath, sevenZipPath, textPath, zipPath]),
    [directory, zipPath, rarPath, sevenZipPath]
  );
});

test('safe ZIP paths accept nested media paths', () => {
  assert.equal(safeRelativePath('album/2026/photo.jpg'), path.join('album', '2026', 'photo.jpg'));
});

test('7-Zip listing parser accepts entries without blank separators', () => {
  const entries = parseTechnicalListing([
    'Path = album\\one.jpg',
    'Size = 10',
    'Attributes = A',
    'Path = notes.txt',
    'Size = 4',
    'Attributes = A',
  ].join('\r\n'));

  assert.deepEqual(entries.map(entry => entry.Path), ['album\\one.jpg', 'notes.txt']);
});

test('7z scanner extracts nested media and keeps the archive untouched', async (t) => {
  const directory = tempDir(t);
  const sourceDirectory = path.join(directory, 'source');
  const archivePath = path.join(directory, 'photos.7z');
  fs.mkdirSync(path.join(sourceDirectory, 'album'), { recursive: true });
  fs.writeFileSync(path.join(sourceDirectory, 'album', 'one.jpg'), 'photo data');
  fs.writeFileSync(path.join(sourceDirectory, 'notes.txt'), 'not media');
  if (process.platform !== 'win32') fs.chmodSync(path7za, 0o755);
  execFileSync(path7za, ['a', '-t7z', archivePath, '.'], { cwd: sourceDirectory, stdio: 'ignore' });

  const before = fs.readFileSync(archivePath);
  const result = await extractArchive(archivePath, filePath => path.extname(filePath) === '.jpg');
  t.after(() => fs.rmSync(result.tempDirectory, { recursive: true, force: true }));

  assert.equal(result.mediaPaths.length, 1);
  assert.equal(path.basename(result.mediaPaths[0]), 'one.jpg');
  assert.equal(fs.readFileSync(result.mediaPaths[0], 'utf8'), 'photo data');
  assert.deepEqual(fs.readFileSync(archivePath), before);

  const scanResult = await scanner.scan([archivePath], () => {});
  assert.equal(scanResult.archivesExtracted, 1);
  assert.equal(scanResult.files.length, 1);
  assert.equal(scanResult.files[0].archiveSourcePath, archivePath);
});

test('bundled Windows engine extracts real RAR media', {
  skip: process.platform !== 'win32',
}, async (t) => {
  const archivePath = path.resolve(__dirname, '..', '..', 'FoldiqTests', 'Fixtures', 'archive-media.rar');
  const before = fs.readFileSync(archivePath);
  const result = await extractArchive(archivePath, filePath => path.extname(filePath) === '.jpg');
  t.after(() => fs.rmSync(result.tempDirectory, { recursive: true, force: true }));

  assert.equal(result.mediaPaths.length, 1);
  assert.equal(path.basename(result.mediaPaths[0]), 'test.jpg');
  assert.equal(fs.readFileSync(result.mediaPaths[0], 'utf8'), 'test text document\r\n');
  assert.deepEqual(fs.readFileSync(archivePath), before);
});
