const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const zlib = require('node:zlib');

const { extractZip, safeRelativePath } = require('../electron/services/archive');
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

test('source filtering accepts folders and ZIPs but rejects unrelated files', (t) => {
  const directory = tempDir(t);
  const zipPath = path.join(directory, 'photos.ZIP');
  const textPath = path.join(directory, 'notes.txt');
  fs.writeFileSync(zipPath, createZip([]));
  fs.writeFileSync(textPath, 'notes');

  assert.deepEqual(
    filterSupportedSources([directory, zipPath, textPath, zipPath]),
    [directory, zipPath]
  );
});

test('safe ZIP paths accept nested media paths', () => {
  assert.equal(safeRelativePath('album/2026/photo.jpg'), path.join('album', '2026', 'photo.jpg'));
});
