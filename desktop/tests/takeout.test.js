const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');

const {
  SidecarIndex,
  sidecarCandidateNames,
  matchSidecarName,
  parseSidecar,
} = require('../electron/services/takeout');
const { metadataResult, isMediaOrSidecar, TAKEOUT_DATE_SOURCE } = require('../electron/services/scanner');

function names(...list) {
  return new Map(list.map(name => [name.toLowerCase(), name]));
}

function sidecarJSON({ title = 'IMG_1234.jpg', timestamp = '1565788330', latitude = 0, longitude = 0 } = {}) {
  return JSON.stringify({
    title,
    photoTakenTime: { timestamp, formatted: 'ignored' },
    geoData: { latitude, longitude, altitude: 0 },
  });
}

test('candidate names cover old, new, numbered and edited exports', () => {
  assert.deepEqual(sidecarCandidateNames('IMG_1234.jpg').slice(0, 3), [
    'img_1234.jpg.supplemental-metadata.json',
    'img_1234.jpg.json',
    'img_1234.json',
  ]);
  assert.ok(sidecarCandidateNames('IMG_1234(1).jpg').includes('img_1234.jpg(1).json'));
  assert.ok(sidecarCandidateNames('IMG_1234(1).jpg').includes('img_1234.jpg.supplemental-metadata(1).json'));
  assert.ok(sidecarCandidateNames('IMG_1234-edited.jpg').includes('img_1234.jpg.json'));
});

test('exact sidecar names win and numbered copies do not take the original JSON', () => {
  const directory = names('IMG_1234.jpg.supplemental-metadata.json', 'IMG_1234.jpg(1).json');
  assert.equal(matchSidecarName('IMG_1234.jpg', directory).name, 'IMG_1234.jpg.supplemental-metadata.json');
  assert.equal(matchSidecarName('IMG_1234(1).jpg', directory).name, 'IMG_1234.jpg(1).json');
  assert.equal(matchSidecarName('IMG_9999.jpg', directory), null);
});

test('truncated sidecar names match only long names and report that they need confirmation', () => {
  const longName = 'PXL_20240814_153210123.NIGHT.PORTRAIT-01.COVER.jpg';
  const truncated = 'PXL_20240814_153210123.NIGHT.PORTRAIT-01.COVER.j.json';
  const match = matchSidecarName(longName, names(truncated));
  assert.deepEqual(match, { name: truncated, truncated: true });

  const supplemental = 'IMG_20200101_123456789_HDR.jpg.supplemental-metad.json';
  assert.equal(matchSidecarName('IMG_20200101_123456789_HDR.jpg', names(supplemental)).name, supplemental);

  // Short prefixes are never treated as truncation.
  assert.equal(matchSidecarName('IMG_1234_extra.jpg', names('IMG_1234.json')), null);
});

test('parseSidecar reads capture time and ignores Google placeholder coordinates', () => {
  const parsed = parseSidecar(JSON.parse(sidecarJSON()));
  assert.equal(parsed.date.toISOString(), '2019-08-14T13:12:10.000Z');
  assert.equal(parsed.latitude, null);

  const located = parseSidecar(JSON.parse(sidecarJSON({ latitude: 38.97, longitude: -77.38 })));
  assert.equal(located.latitude, 38.97);
  assert.equal(located.longitude, -77.38);

  assert.equal(parseSidecar({ photoTakenTime: { timestamp: '0' } }), null);
  assert.equal(parseSidecar({ photoTakenTime: { timestamp: String(Math.floor(Date.now() / 1000) + 10 * 86400) } }), null);
  assert.equal(parseSidecar(null), null);
});

test('SidecarIndex finds sidecars on disk and across separate Takeout archives', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'foldiq-takeout-'));
  try {
    const album = path.join(root, 'Takeout', 'Google Photos', 'Photos from 2019');
    fs.mkdirSync(album, { recursive: true });
    fs.writeFileSync(path.join(album, 'IMG_1234.jpg'), 'image');
    fs.writeFileSync(path.join(album, 'IMG_1234.jpg.json'), sidecarJSON());

    const disk = new SidecarIndex();
    disk.add(path.join(album, 'IMG_1234.jpg.json'));
    const found = await disk.lookup(path.join(album, 'IMG_1234.jpg'));
    assert.equal(found.date.toISOString(), '2019-08-14T13:12:10.000Z');
    assert.equal(await disk.lookup(path.join(root, 'IMG_1234.jpg')), null);

    // takeout-001.zip holds the photo, takeout-002.zip holds its JSON.
    const archiveA = path.join(root, 'a');
    const archiveB = path.join(root, 'b');
    const inner = path.join('Takeout', 'Google Photos', 'Trip');
    fs.mkdirSync(path.join(archiveA, inner), { recursive: true });
    fs.mkdirSync(path.join(archiveB, inner), { recursive: true });
    fs.writeFileSync(path.join(archiveA, inner, 'IMG_1234.jpg'), 'image');
    fs.writeFileSync(path.join(archiveB, inner, 'IMG_1234.jpg.supplemental-metadata.json'), sidecarJSON({ latitude: 40.4, longitude: -3.7 }));

    const archives = new SidecarIndex();
    archives.add(path.join(archiveB, inner, 'IMG_1234.jpg.supplemental-metadata.json'), archiveB);
    const crossArchive = await archives.lookup(path.join(archiveA, inner, 'IMG_1234.jpg'), archiveA);
    assert.equal(crossArchive.latitude, 40.4);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('a truncated match is rejected when the JSON title names a different photo', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'foldiq-takeout-'));
  try {
    const sidecarPath = path.join(root, 'PXL_20240814_153210123.NIGHT.PORTRAIT-01.COVER.j.json');
    fs.writeFileSync(sidecarPath, sidecarJSON({ title: 'PXL_20240814_153210123.NIGHT.PORTRAIT-01.COVER.jpg' }));
    const index = new SidecarIndex();
    index.add(sidecarPath);
    assert.ok(await index.lookup(path.join(root, 'PXL_20240814_153210123.NIGHT.PORTRAIT-01.COVER.jpg')));
    assert.equal(await index.lookup(path.join(root, 'PXL_20240814_153210123.NIGHT.PORTRAIT-01.COVER.jpeg')), null);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('metadataResult prefers camera metadata, then the Takeout sidecar, then the filename', () => {
  const sidecar = { date: new Date('2019-08-14T13:12:10Z'), latitude: 38.97, longitude: -77.38 };

  const withCamera = metadataResult('photo.jpg', { DateTimeOriginal: '2019:08:14 09:12:10' }, new Date(), sidecar);
  assert.equal(withCamera.dateInfo.source, 'camera metadata');
  assert.equal(withCamera.latitude, 38.97, 'GPS still comes from the sidecar when the file has none');

  const withoutCamera = metadataResult('IMG_20100101_000000.jpg', {}, new Date(), sidecar);
  assert.equal(withoutCamera.dateInfo.source, TAKEOUT_DATE_SOURCE);
  assert.equal(withoutCamera.dateInfo.date.toISOString(), '2019-08-14T13:12:10.000Z');

  const withFileGPS = metadataResult('photo.jpg', { GPSLatitude: 1.5, GPSLongitude: 2.5 }, new Date(), sidecar);
  assert.equal(withFileGPS.latitude, 1.5);

  assert.equal(metadataResult('IMG_20100101_000000.jpg', {}).dateInfo.source, 'filename');
});

test('archives release Takeout sidecars alongside media', () => {
  assert.equal(isMediaOrSidecar('Takeout/Google Photos/IMG_1.jpg.json'), true);
  assert.equal(isMediaOrSidecar('IMG_1.jpg'), true);
  assert.equal(isMediaOrSidecar('notes.txt'), false);
});
