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

async function extractDate(filePath) {
  try {
    const tags = await exiftool.read(filePath);
    const raw =
      tags.DateTimeOriginal ||
      tags.CreateDate       ||
      tags.MediaCreateDate  ||
      tags.ModifyDate;

    if (raw) {
      const d = raw instanceof Date ? raw : new Date(String(raw).replace(':', '-').replace(':', '-'));
      if (!isNaN(d.getTime()) && d.getFullYear() > 1990) return d;
    }
  } catch {}

  // Fallback: parse date from filename
  const name = path.basename(filePath);
  const m = name.match(/(\d{4})[_\-]?(\d{2})[_\-]?(\d{2})/);
  if (m) {
    const d = new Date(+m[1], +m[2] - 1, +m[3]);
    if (!isNaN(d.getTime()) && d.getFullYear() > 1990) return d;
  }

  // Last resort: file mtime
  try {
    const stat = fs.statSync(filePath);
    return stat.mtime;
  } catch {
    return new Date();
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
      date:        date.toISOString(),
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

module.exports = { scan, hashFile, cleanupTempDirs, end };
