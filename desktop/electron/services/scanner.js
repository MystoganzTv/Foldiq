// scanner.js — Recursively scans folders for media files and extracts metadata
const fs   = require('fs');
const path = require('path');
const crypto = require('crypto');
const { exiftool } = require('exiftool-vendored');

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
  try {
    const buf = fs.readFileSync(filePath);
    return crypto.createHash('md5').update(buf).digest('hex');
  } catch {
    return null;
  }
}

function walkDir(dir, results = []) {
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); }
  catch { return results; }

  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      walkDir(full, results);
    } else if (entry.isFile() && isMedia(full)) {
      results.push(full);
    }
  }
  return results;
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
  // 1. Collect all files
  const allPaths = [];
  for (const folder of folders) walkDir(folder, allPaths);

  const total = allPaths.length;
  const files = [];
  const hashMap = {};

  for (let i = 0; i < allPaths.length; i++) {
    const filePath = allPaths[i];
    const stat = fs.statSync(filePath);
    const ext  = path.extname(filePath).toLowerCase();
    const date = await extractDate(filePath);
    const hash = hashFile(filePath);

    const isDuplicate = hash && hashMap[hash] != null;
    if (hash) hashMap[hash] = (hashMap[hash] ?? i);

    const file = {
      id:          i,
      path:        filePath,
      name:        path.basename(filePath),
      ext,
      size:        stat.size,
      date:        date.toISOString(),
      hash,
      isDuplicate: isDuplicate,
      duplicateOf: isDuplicate ? hashMap[hash] : null,
    };

    files.push(file);
    onProgress({ current: i + 1, total, file: file.name });
  }

  await exiftool.end();
  return files;
}

module.exports = { scan };
