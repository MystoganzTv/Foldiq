// takeout.js — Reads capture dates and GPS from Google Takeout sidecar files.
//
// Google Photos exports strip or rewrite much of the original metadata and put
// the real capture time in a JSON file next to each photo. The naming of that
// JSON file has changed over the years and is truncated for long names:
//
//   IMG_1234.jpg.json                          (older exports)
//   IMG_1234.jpg.supplemental-metadata.json    (2024 and later)
//   IMG_1234.jpg.supplemental-metad.json       (truncated to ~51 characters)
//   IMG_1234.jpg(1).json  /  IMG_1234.jpg.supplemental-metadata(1).json
//                                              (for IMG_1234(1).jpg)
//   IMG_1234.jpg.json                          (also used by IMG_1234-edited.jpg)
//
// Takeout also splits large libraries across several ZIP files, and a photo's
// JSON can land in a different ZIP than the photo. Sidecars found inside
// archives are therefore indexed by their path *inside* the archive, so the
// match works across every archive in the same scan.

const fs = require('fs');
const path = require('path');

const MAX_SIDECAR_BYTES = 1024 * 1024;
// Google truncates the JSON filename to 51 characters (46 before ".json").
// A truncated key is only trusted when it is long enough to have been cut.
const TRUNCATED_KEY_MIN_LENGTH = 40;
const EARLIEST_YEAR = 1900;
const MAX_FUTURE_OFFSET_MS = 24 * 60 * 60 * 1000;
const EDITED_SUFFIX = /-(?:edited|bearbeitet|modifié|modifie|editado|modificato|bewerkt)$/i;

function isSidecarPath(filePath) {
  return path.extname(filePath).toLowerCase() === '.json';
}

function splitNumberSuffix(stem) {
  const match = stem.match(/^(.*?)(\(\d+\))$/);
  return match ? { base: match[1], number: match[2] } : { base: stem, number: '' };
}

/** Exact JSON filenames to try for a media file, most specific first (lowercase). */
function sidecarCandidateNames(mediaName) {
  const ext = path.extname(mediaName);
  const stem = path.basename(mediaName, ext);
  const { base, number } = splitNumberSuffix(stem);
  const original = base.replace(EDITED_SUFFIX, '');
  const names = [];
  const add = name => { const lower = name.toLowerCase(); if (!names.includes(lower)) names.push(lower); };

  for (const candidate of original === base ? [base] : [base, original]) {
    if (number) {
      add(`${candidate}${ext}.supplemental-metadata${number}.json`);
      add(`${candidate}${ext}${number}.json`);
      add(`${candidate}${number}${ext}.json`);
    }
    add(`${candidate}${ext}.supplemental-metadata.json`);
    add(`${candidate}${ext}.json`);
    add(`${candidate}.json`);
  }
  return names;
}

function normalizedTitle(name) {
  const ext = path.extname(name);
  const { base } = splitNumberSuffix(path.basename(name, ext));
  return `${base.replace(EDITED_SUFFIX, '')}${ext}`.normalize('NFC').toLowerCase();
}

/**
 * Finds the sidecar for `mediaName` among `jsonNames` (lowercase name → real
 * name). Returns { name, truncated } or null. Truncated matches must later be
 * confirmed against the JSON "title" field.
 */
function matchSidecarName(mediaName, jsonNames) {
  for (const candidate of sidecarCandidateNames(mediaName)) {
    if (jsonNames.has(candidate)) return { name: jsonNames.get(candidate), truncated: false };
  }

  const ext = path.extname(mediaName);
  const { base, number } = splitNumberSuffix(path.basename(mediaName, ext));
  const original = base.replace(EDITED_SUFFIX, '');
  const targets = [...new Set([base, original])]
    .map(candidate => `${candidate}${ext}.supplemental-metadata`.toLowerCase());

  let best = null;
  for (const [lowerName, realName] of jsonNames) {
    const withoutJSON = lowerName.slice(0, -'.json'.length);
    const split = splitNumberSuffix(withoutJSON);
    if (split.number.toLowerCase() !== number.toLowerCase()) continue;
    const key = split.base;
    if (key.length < TRUNCATED_KEY_MIN_LENGTH) continue;
    if (!targets.some(target => target.startsWith(key))) continue;
    if (!best || key.length > best.keyLength) best = { name: realName, truncated: true, keyLength: key.length };
  }
  return best ? { name: best.name, truncated: true } : null;
}

function plausibleDate(seconds) {
  const value = Number(seconds);
  if (!Number.isFinite(value) || value <= 0) return null;
  const date = new Date(value * 1000);
  if (Number.isNaN(date.getTime()) || date.getFullYear() < EARLIEST_YEAR) return null;
  if (date.getTime() > Date.now() + MAX_FUTURE_OFFSET_MS) return null;
  return date;
}

function coordinates(geo) {
  if (!geo || typeof geo !== 'object') return null;
  const latitude = Number(geo.latitude);
  const longitude = Number(geo.longitude);
  if (!Number.isFinite(latitude) || !Number.isFinite(longitude)) return null;
  // Takeout writes 0.0 / 0.0 when a photo has no location.
  if (latitude === 0 && longitude === 0) return null;
  if (Math.abs(latitude) > 90 || Math.abs(longitude) > 180) return null;
  return { latitude, longitude };
}

/** Parses the fields Foldiq uses from a Takeout JSON document. */
function parseSidecar(json) {
  if (!json || typeof json !== 'object') return null;
  const date = plausibleDate(json.photoTakenTime?.timestamp);
  const location = coordinates(json.geoData) || coordinates(json.geoDataExif);
  if (!date && !location) return null;
  return {
    date,
    latitude: location?.latitude ?? null,
    longitude: location?.longitude ?? null,
    title: typeof json.title === 'string' ? json.title : null,
  };
}

async function readSidecarFile(filePath) {
  try {
    const stat = await fs.promises.stat(filePath);
    if (!stat.isFile() || stat.size > MAX_SIDECAR_BYTES) return null;
    return parseSidecar(JSON.parse(await fs.promises.readFile(filePath, 'utf8')));
  } catch {
    return null;
  }
}

class SidecarIndex {
  constructor() {
    this.directories = new Map();
    this.parsed = new Map();
  }

  static directoryKey(filePath, archiveTempDirectory = null) {
    const directory = path.dirname(filePath);
    if (archiveTempDirectory) {
      const relative = path.relative(archiveTempDirectory, directory).split(path.sep).join('/');
      return `archive:${relative.normalize('NFC').toLowerCase()}`;
    }
    return `disk:${path.resolve(directory).normalize('NFC').toLowerCase()}`;
  }

  add(filePath, archiveTempDirectory = null) {
    const key = SidecarIndex.directoryKey(filePath, archiveTempDirectory);
    if (!this.directories.has(key)) this.directories.set(key, new Map());
    const directory = this.directories.get(key);
    const name = path.basename(filePath).normalize('NFC');
    // Keep the first copy when the same relative path appears in two archives.
    if (!directory.has(name.toLowerCase())) directory.set(name.toLowerCase(), filePath);
  }

  get size() {
    let count = 0;
    for (const directory of this.directories.values()) count += directory.size;
    return count;
  }

  async lookup(mediaPath, archiveTempDirectory = null) {
    const directory = this.directories.get(SidecarIndex.directoryKey(mediaPath, archiveTempDirectory));
    if (!directory || directory.size === 0) return null;
    const mediaName = path.basename(mediaPath).normalize('NFC');
    const match = matchSidecarName(mediaName, directory);
    if (!match) return null;
    const sidecarPath = match.name;
    if (!this.parsed.has(sidecarPath)) this.parsed.set(sidecarPath, await readSidecarFile(sidecarPath));
    const sidecar = this.parsed.get(sidecarPath);
    if (!sidecar) return null;
    if (match.truncated && (!sidecar.title || normalizedTitle(sidecar.title) !== normalizedTitle(mediaName))) {
      return null;
    }
    return sidecar;
  }
}

module.exports = {
  SidecarIndex,
  isSidecarPath,
  sidecarCandidateNames,
  matchSidecarName,
  parseSidecar,
  readSidecarFile,
  normalizedTitle,
  TRUNCATED_KEY_MIN_LENGTH,
};
