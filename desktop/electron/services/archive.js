// archive.js — Safely extracts supported media from ZIP archives.
const fs = require('fs');
const os = require('os');
const path = require('path');
const { Transform } = require('stream');
const { pipeline } = require('stream/promises');
const unzipper = require('unzipper');

const MAX_ARCHIVE_ENTRIES = 100_000;
const MAX_UNCOMPRESSED_BYTES = 500 * 1024 * 1024 * 1024;
const DISK_RESERVE_BYTES = 1024 * 1024 * 1024;

function safeRelativePath(entryPath) {
  if (typeof entryPath !== 'string' || entryPath.includes('\0')) {
    throw new Error('ZIP contains an invalid filename');
  }

  const normalized = entryPath.replace(/\\/g, '/');
  if (normalized.startsWith('/') || /^[A-Za-z]:/.test(normalized)) {
    throw new Error(`ZIP contains an unsafe absolute path: ${entryPath}`);
  }

  const parts = normalized.split('/').filter(part => part && part !== '.');
  if (parts.length === 0 || parts.some(part => part === '..')) {
    throw new Error(`ZIP contains an unsafe path: ${entryPath}`);
  }

  return parts.join(path.sep);
}

function isSymbolicLink(entry) {
  const attributes = entry.vars?.externalFileAttributes ?? 0;
  const mode = (attributes >>> 16) & 0xffff;
  return (mode & 0o170000) === 0o120000;
}

function availableDiskBytes(directory) {
  try {
    const stats = fs.statfsSync(directory);
    return Number(stats.bavail) * Number(stats.bsize);
  } catch {
    return null;
  }
}

async function extractZip(zipPath, isMedia) {
  const tempDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'foldiq-zip-'));

  try {
    const archive = await unzipper.Open.file(zipPath);
    if (archive.files.length > MAX_ARCHIVE_ENTRIES) {
      throw new Error(`ZIP has too many entries (${archive.files.length.toLocaleString()})`);
    }

    const mediaEntries = [];
    let declaredBytes = 0;

    for (const entry of archive.files) {
      const relativePath = safeRelativePath(entry.path);
      if ((entry.vars?.flags ?? 0) & 0x01) {
        throw new Error('Password-protected ZIP files are not supported');
      }
      if (isSymbolicLink(entry)) {
        throw new Error(`ZIP contains a symbolic link: ${entry.path}`);
      }
      if (entry.type !== 'File' || !isMedia(relativePath)) continue;

      const size = Number(entry.vars?.uncompressedSize ?? entry.size ?? 0);
      if (!Number.isSafeInteger(size) || size < 0) {
        throw new Error(`ZIP contains an invalid file size: ${entry.path}`);
      }
      declaredBytes += size;
      if (declaredBytes > MAX_UNCOMPRESSED_BYTES) {
        throw new Error('ZIP media is too large to extract safely');
      }
      mediaEntries.push({ entry, relativePath });
    }

    const freeBytes = availableDiskBytes(tempDirectory);
    if (freeBytes !== null && declaredBytes > Math.max(0, freeBytes - DISK_RESERVE_BYTES)) {
      throw new Error('Not enough free disk space to extract this ZIP safely');
    }

    const mediaPaths = [];
    let extractedBytes = 0;

    for (const { entry, relativePath } of mediaEntries) {
      const destination = path.join(tempDirectory, relativePath);
      const relativeDestination = path.relative(tempDirectory, destination);
      if (relativeDestination.startsWith('..') || path.isAbsolute(relativeDestination)) {
        throw new Error(`ZIP contains an unsafe path: ${entry.path}`);
      }

      fs.mkdirSync(path.dirname(destination), { recursive: true });
      const sizeGuard = new Transform({
        transform(chunk, encoding, callback) {
          extractedBytes += chunk.length;
          if (extractedBytes > MAX_UNCOMPRESSED_BYTES) {
            callback(new Error('ZIP media expanded beyond the safe extraction limit'));
            return;
          }
          callback(null, chunk);
        },
      });

      await pipeline(entry.stream(), sizeGuard, fs.createWriteStream(destination, { flags: 'wx' }));
      const modified = entry.vars?.lastModifiedDateTime;
      if (modified instanceof Date && !Number.isNaN(modified.getTime())) {
        try { fs.utimesSync(destination, modified, modified); } catch {}
      }
      mediaPaths.push(destination);
    }

    return { tempDirectory, mediaPaths };
  } catch (error) {
    fs.rmSync(tempDirectory, { recursive: true, force: true });
    throw error;
  }
}

module.exports = {
  extractZip,
  safeRelativePath,
  MAX_ARCHIVE_ENTRIES,
  MAX_UNCOMPRESSED_BYTES,
};
