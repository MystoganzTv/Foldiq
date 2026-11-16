// Builds a believable library for Store screenshots: a few thousand photos and
// videos from a phone backup, an old laptop and a Google Takeout export, with
// duplicates, missing dates and a handful of trips. Nothing here touches disk;
// the plan comes from Foldiq's real planner, so destinations are exactly what
// the app would produce on Windows.
const path = require('path');
const planner = require('../../electron/services/planner');

const OUTPUT = 'D:\\Photos\\Organized';
const SOURCES = {
  phone: 'D:\\Photos\\Phone backup\\DCIM\\Camera',
  laptop: 'D:\\Photos\\Old laptop\\Pictures',
  takeout: 'D:\\Photos\\Google Takeout\\Google Photos',
};
const FOLDERS = [SOURCES.phone, SOURCES.laptop, 'D:\\Photos\\Google Takeout'];

const TRIPS = [
  { start: '2019-08-03', days: 6, city: 'Lisbon', state: 'Lisbon', country: 'Portugal' },
  { start: '2021-07-14', days: 4, city: 'Denver', state: 'Colorado', country: 'United States' },
  { start: '2023-12-20', days: 5, city: 'Madrid', state: 'Community of Madrid', country: 'Spain' },
  { start: '2024-05-18', days: 3, city: 'Asheville', state: 'North Carolina', country: 'United States' },
  { start: '2025-04-11', days: 4, city: 'Kyoto', state: 'Kyoto', country: 'Japan' },
];

// Small deterministic PRNG so every run produces the same screenshots.
function rng(seed) {
  let value = seed >>> 0;
  return () => {
    value = (value + 0x6D2B79F5) >>> 0;
    let t = value;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function buildFiles() {
  const random = rng(20261116);
  const pick = list => list[Math.floor(random() * list.length)];
  const files = [];
  const start = Date.UTC(2016, 2, 1);
  const end = Date.UTC(2025, 9, 30);

  function add(file) {
    files.push({
      id: files.length,
      hash: `h${files.length}`,
      isDuplicate: false,
      duplicateOf: null,
      archiveSourcePath: null,
      archiveTempDirectory: null,
      latitude: null,
      longitude: null,
      ...file,
    });
  }

  let counter = 1042;
  for (let i = 0; i < 3180; i++) {
    const trip = random() < 0.16 ? pick(TRIPS) : null;
    const time = trip
      ? Date.parse(`${trip.start}T09:00:00Z`) + Math.floor(random() * trip.days) * 86400000 + Math.floor(random() * 36000) * 1000
      : start + Math.floor(random() * (end - start));
    const date = new Date(time);
    const isVideo = random() < 0.09;
    const source = random() < 0.62 ? 'phone' : random() < 0.6 ? 'laptop' : 'takeout';
    const stamp = date.toISOString().slice(0, 10).replace(/-/g, '');
    const name = source === 'phone'
      ? `${isVideo ? 'VID' : 'IMG'}_${stamp}_${String(100000 + Math.floor(random() * 899999))}.${isVideo ? 'mp4' : 'jpg'}`
      : source === 'laptop'
        ? `${isVideo ? 'MOV' : 'DSC'}_${counter++}.${isVideo ? 'mov' : pick(['jpg', 'jpg', 'jpg', 'heic', 'png'])}`
        : `PXL_${stamp}_${String(Math.floor(random() * 99999999)).padStart(8, '0')}.${isVideo ? 'mp4' : 'jpg'}`;
    const folder = source === 'takeout'
      ? `${SOURCES.takeout}\\Photos from ${date.getUTCFullYear()}`
      : SOURCES[source];
    const missingDate = random() < 0.025;
    add({
      path: `${folder}\\${name}`,
      name,
      ext: path.extname(name).toLowerCase(),
      size: Math.floor((isVideo ? 18e6 + random() * 160e6 : 1.6e6 + random() * 4.2e6)),
      date: missingDate ? null : date.toISOString(),
      dateSource: missingDate ? null : source === 'takeout' ? 'Google Takeout' : isVideo ? 'video metadata' : 'camera metadata',
      dateTag: missingDate ? null : isVideo ? 'MediaCreateDate' : 'DateTimeOriginal',
      cameraMake: source === 'laptop' ? 'Canon' : 'Google',
      cameraModel: source === 'laptop' ? 'EOS Rebel T6' : 'Pixel 8',
      pixelWidth: isVideo ? 1920 : 4032,
      pixelHeight: isVideo ? 1080 : 3024,
      durationSeconds: isVideo ? Math.floor(4 + random() * 90) : null,
      fileModifiedDate: new Date(Date.UTC(2024, 0, 6)).toISOString(),
      location: trip ? { city: trip.city, state: trip.state, country: trip.country } : null,
    });
  }

  // Exact duplicates: the same photo backed up twice.
  const originals = files.filter(file => file.date && file.ext === '.jpg').slice(0, 2400);
  for (let i = 0; i < 186; i++) {
    const original = originals[Math.floor(random() * originals.length)];
    const copyName = original.name.replace(/\.jpg$/, ' (1).jpg');
    add({ ...original, path: `${SOURCES.laptop}\\Backup 2022\\${copyName}`, name: copyName, isDuplicate: true, duplicateOf: original.path });
  }

  // Same image, different file (re-saved or resized): flagged for review.
  const phoneOriginals = originals.filter(file => file.path.startsWith(SOURCES.phone));
  for (let i = 0; i < 24; i++) {
    const original = phoneOriginals[(i * 37) % phoneOriginals.length];
    const copyName = original.name.replace(/\.jpg$/, '-edited.jpg');
    const group = `same-${i}`;
    original.probableDuplicateGroupID = group;
    original.probableMatchKind = 'same';
    original.probableMatchScore = 98;
    add({
      ...original,
      path: `${SOURCES.laptop}\\Edited\\${copyName}`,
      name: copyName,
      size: Math.floor(original.size * 0.7),
      probableDuplicateGroupID: group,
      probableMatchKind: 'same',
      probableMatchScore: 98,
      isProbableDuplicate: true,
      probableMatchReasons: 'Same image at a lower resolution',
    });
  }
  return files;
}

const CONFIG = {
  outputFolder: OUTPUT,
  organizationMode: 'smart',
  groupByMonth: true,
  groupByDay: true,
  copyMode: false,
  duplicateHandling: 'separate',
  includeVideos: true,
  includeArchives: true,
  useGPSLocation: true,
  renameByDate: false,
  shareAnonymousUsageData: false,
};

function buildFixture() {
  const files = buildFiles();
  const plan = planner.buildPlan(files, CONFIG);
  return { folders: FOLDERS, output: OUTPUT, config: CONFIG, files, plan };
}

module.exports = { buildFixture };
