// scanner.js — Recursively scans folders for media files and extracts metadata
const fs   = require('fs');
const path = require('path');
const crypto = require('crypto');
const { exiftool } = require('exiftool-vendored');
const { extractZip } = require('./archive');
const { isZip } = require('./sources');

const SUPPORTED = new Set([
  '.jpg', '.jpeg', '.png', '.heic', '.heif',
  '.tiff', '.tif', '.webp',
  '.cr2', '.cr3', '.nef', '.arw', '.dng', '.raf', '.orf', '.rw2',
  '.mov', '.mp4', '.m4v', '.avi', '.mkv',
]);
const EARLIEST_YEAR = 1900;
const MAX_FUTURE_OFFSET_MS = 24 * 60 * 60 * 1000;

function isMedia(filePath) {
  return SUPPORTED.has(path.extname(filePath).toLowerCase());
}

function hashFile(filePath) {
  return new Promise((resolve) => {
    const hash = crypto.createHash('sha256');
    const stream = fs.createReadStream(filePath);

    stream.on('data', chunk => hash.update(chunk));
    stream.on('error', () => resolve(null));
    stream.on('end', () => resolve(hash.digest('hex')));
  });
}

const tempDirectories = new Set();

function walkDir(dir, mediaPaths, archivePaths) {
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); }
  catch { return; }

  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      walkDir(full, mediaPaths, archivePaths);
    } else if (entry.isFile() && isMedia(full)) {
      mediaPaths.add(full);
    } else if (entry.isFile() && isZip(full)) {
      archivePaths.add(full);
    }
  }
}

function collectSource(sourcePath, mediaPaths, archivePaths) {
  let stat;
  try { stat = fs.statSync(sourcePath); } catch { return; }

  if (stat.isDirectory()) {
    walkDir(sourcePath, mediaPaths, archivePaths);
  } else if (stat.isFile() && isMedia(sourcePath)) {
    mediaPaths.add(sourcePath);
  } else if (stat.isFile() && isZip(sourcePath)) {
    archivePaths.add(sourcePath);
  }
}

function cleanupTempDirs() {
  for (const directory of tempDirectories) {
    try { fs.rmSync(directory, { recursive: true, force: true }); } catch {}
  }
  tempDirectories.clear();
}

function dateFromParts(year, month, day, hour = 0, minute = 0, second = 0) {
  const date = new Date(year, month - 1, day, hour, minute, second);
  if (
    date.getFullYear() !== year ||
    date.getMonth() !== month - 1 ||
    date.getDate() !== day ||
    date.getHours() !== hour ||
    date.getMinutes() !== minute ||
    date.getSeconds() !== second
  ) return null;
  return date;
}

function isPlausibleDate(date, now = new Date()) {
  if (!(date instanceof Date) || Number.isNaN(date.getTime())) return false;
  const year = date.getFullYear();
  return year >= EARLIEST_YEAR && date.getTime() <= now.getTime() + MAX_FUTURE_OFFSET_MS;
}

function metadataDate(raw, now = new Date()) {
  if (!raw) return null;

  let date = null;
  if (raw instanceof Date) {
    date = raw;
  } else if (typeof raw.toDate === 'function') {
    try { date = raw.toDate(); } catch {}
  } else if (typeof raw === 'string') {
    const exif = raw.match(/^(\d{4}):(\d{2}):(\d{2})(?:[ T](\d{2}):(\d{2}):(\d{2}))?/);
    if (exif) {
      date = dateFromParts(
        Number(exif[1]), Number(exif[2]), Number(exif[3]),
        Number(exif[4] ?? 0), Number(exif[5] ?? 0), Number(exif[6] ?? 0)
      );
    } else {
      date = new Date(raw);
    }
  }

  return isPlausibleDate(date, now) ? date : null;
}

function dateFromFilename(filename, now = new Date()) {
  const name = path.basename(filename, path.extname(filename));
  const match = name.match(/(?:^|\D)((?:19|20)\d{2})[-_]?([01]\d)[-_]?([0-3]\d)(?:[-_T ]?([0-2]\d)([0-5]\d)([0-5]\d))?(?:\D|$)/);
  if (!match) return null;

  const date = dateFromParts(
    Number(match[1]), Number(match[2]), Number(match[3]),
    Number(match[4] ?? 0), Number(match[5] ?? 0), Number(match[6] ?? 0)
  );
  return isPlausibleDate(date, now) ? date : null;
}

async function extractDate(filePath, now = new Date()) {
  try {
    const tags = await exiftool.read(filePath);
    const raw =
      tags.DateTimeOriginal ||
      tags.CreateDate       ||
      tags.MediaCreateDate  ||
      tags.ModifyDate;

    if (raw) {
      const date = metadataDate(raw, now);
      if (date) return date;
    }
  } catch {}

  // Fallback: parse date from filename
  const filenameDate = dateFromFilename(filePath, now);
  if (filenameDate) return filenameDate;

  // Last resort: file mtime
  try {
    const stat = fs.statSync(filePath);
    if (isPlausibleDate(stat.mtime, now)) return stat.mtime;
    if (isPlausibleDate(stat.birthtime, now)) return stat.birthtime;
    return null;
  } catch {
    return null;
  }
}

async function scan(folders, onProgress) {
  cleanupTempDirs();

  const progress = typeof onProgress === 'function' ? onProgress : () => {};
  const mediaPaths = new Set();
  const archivePaths = new Set();
  for (const folder of folders) collectSource(folder, mediaPaths, archivePaths);

  const allFiles = Array.from(mediaPaths, filePath => ({ filePath }));
  const warnings = [];
  let archivesExtracted = 0;

  for (const archivePath of archivePaths) {
    progress({ current: 0, total: 0, file: `Extracting ${path.basename(archivePath)}…` });
    try {
      const extracted = await extractZip(archivePath, isMedia);
      tempDirectories.add(extracted.tempDirectory);
      archivesExtracted++;
      for (const filePath of extracted.mediaPaths) {
        allFiles.push({
          filePath,
          archiveSourcePath: archivePath,
          archiveTempDirectory: extracted.tempDirectory,
        });
      }
    } catch (error) {
      warnings.push({ archive: archivePath, message: error.message });
    }
  }

  const total = allFiles.length;
  const files = [];
  const hashMap = new Map();

  for (let i = 0; i < allFiles.length; i++) {
    const candidate = allFiles[i];
    const filePath = candidate.filePath;
    let stat;
    try {
      stat = fs.statSync(filePath);
    } catch {
      progress({ current: i + 1, total, file: path.basename(filePath) });
      continue;
    }

    const ext  = path.extname(filePath).toLowerCase();
    const date = await extractDate(filePath);
    const hash = await hashFile(filePath);

    const duplicateOf = hash ? hashMap.get(hash) : null;
    const isDuplicate = duplicateOf != null;
    const id = files.length;
    if (hash && !hashMap.has(hash)) hashMap.set(hash, id);

    const file = {
      id,
      path:        filePath,
      name:        path.basename(filePath),
      ext,
      size:        stat.size,
      date:        date?.toISOString() ?? null,
      hash,
      isDuplicate: isDuplicate,
      duplicateOf: isDuplicate ? duplicateOf : null,
      archiveSourcePath: candidate.archiveSourcePath ?? null,
      archiveTempDirectory: candidate.archiveTempDirectory ?? null,
    };

    files.push(file);
    progress({ current: i + 1, total, file: file.name });
  }

  return { files, archivesExtracted, warnings };
}

async function end() {
  cleanupTempDirs();
  try { await exiftool.end(); } catch {}
}

module.exports = {
  scan,
  hashFile,
  cleanupTempDirs,
  isPlausibleDate,
  metadataDate,
  dateFromFilename,
  extractDate,
  end,
};
