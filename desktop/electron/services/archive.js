// archive.js — Safely extracts supported media from ZIP, RAR, and 7z archives.
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFile } = require('child_process');
const { promisify } = require('util');
const { Transform } = require('stream');
const { pipeline } = require('stream/promises');
const unzipper = require('unzipper');

const execFileAsync = promisify(execFile);
const MAX_ARCHIVE_ENTRIES = 100_000;
const MAX_UNCOMPRESSED_BYTES = 500 * 1024 * 1024 * 1024;
const DISK_RESERVE_BYTES = 1024 * 1024 * 1024;
const MAX_LISTING_BYTES = 128 * 1024 * 1024;

function archiveLabel(archivePath) {
  const extension = path.extname(archivePath).slice(1).toUpperCase();
  return extension || 'archive';
}

function safeRelativePath(entryPath, label = 'Archive') {
  if (typeof entryPath !== 'string' || entryPath.includes('\0')) {
    throw new Error(`${label} contains an invalid filename`);
  }

  if (entryPath.includes('\n') || entryPath.includes('\r')) {
    throw new Error(`${label} contains an unsupported filename`);
  }

  const normalized = entryPath.replace(/\\/g, '/');
  if (normalized.startsWith('/') || /^[A-Za-z]:/.test(normalized)) {
    throw new Error(`${label} contains an unsafe absolute path: ${entryPath}`);
  }

  const parts = normalized.split('/').filter(part => part && part !== '.');
  if (parts.length === 0 || parts.some(part => part === '..')) {
    throw new Error(`${label} contains an unsafe path: ${entryPath}`);
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

function bundledSevenZipPath() {
  const candidates = [];

  if (process.platform === 'win32') {
    if (process.resourcesPath) {
      candidates.push(path.join(process.resourcesPath, '7zip', '7z.exe'));
    }
    candidates.push(path.resolve(__dirname, '..', '..', '.vendor', '7zip-win', '7z.exe'));
  } else {
    try { candidates.push(require('7zip-bin').path7za); } catch {}
  }

  const executable = candidates.find(candidate => candidate && fs.existsSync(candidate));
  if (!executable) {
    throw new Error('The archive extraction engine is missing. Reinstall Foldiq and try again.');
  }

  if (process.platform !== 'win32') {
    try { fs.chmodSync(executable, 0o755); } catch {}
  }
  return executable;
}

function parseTechnicalListing(output) {
  return output
    .split(/\r?\n\r?\n/)
    .map(block => {
      const values = {};
      for (const line of block.split(/\r?\n/)) {
        const separator = line.indexOf(' = ');
        if (separator <= 0) continue;
        values[line.slice(0, separator)] = line.slice(separator + 3);
      }
      return values;
    })
    .filter(values => typeof values.Path === 'string');
}

function looksEncrypted(message) {
  return /password|encrypted|wrong password|can not open encrypted/i.test(message);
}

async function listWithSevenZip(archivePath, executable) {
  try {
    const { stdout } = await execFileAsync(
      executable,
      ['l', '-slt', '-ba', '-sccUTF-8', '--', archivePath],
      { encoding: 'utf8', maxBuffer: MAX_LISTING_BYTES, windowsHide: true }
    );
    return parseTechnicalListing(stdout);
  } catch (error) {
    const detail = [error.stdout, error.stderr, error.message].filter(Boolean).join('\n');
    if (looksEncrypted(detail)) {
      throw new Error('Password-protected archives are not supported');
    }
    throw new Error(`Could not read this ${archiveLabel(archivePath)} archive`);
  }
}

function walkExtractedMedia(directory, isMedia) {
  const mediaPaths = [];
  const pending = [directory];
  let extractedBytes = 0;

  while (pending.length > 0) {
    const current = pending.pop();
    for (const name of fs.readdirSync(current)) {
      const fullPath = path.join(current, name);
      const stat = fs.lstatSync(fullPath);
      if (stat.isSymbolicLink()) {
        throw new Error('Archive contains a symbolic link');
      }
      if (stat.isDirectory()) {
        pending.push(fullPath);
        continue;
      }
      if (!stat.isFile() || !isMedia(fullPath)) continue;
      extractedBytes += stat.size;
      if (extractedBytes > MAX_UNCOMPRESSED_BYTES) {
        throw new Error('Archive media expanded beyond the safe extraction limit');
      }
      mediaPaths.push(fullPath);
    }
  }
  return mediaPaths;
}

async function extractWithSevenZip(archivePath, isMedia, executable = bundledSevenZipPath()) {
  const label = archiveLabel(archivePath);
  const tempDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'foldiq-archive-'));

  try {
    const listedEntries = await listWithSevenZip(archivePath, executable);
    if (listedEntries.length > MAX_ARCHIVE_ENTRIES) {
      throw new Error(`${label} has too many entries (${listedEntries.length.toLocaleString()})`);
    }

    const mediaEntries = [];
    const normalizedDestinations = new Set();
    let declaredBytes = 0;
    for (const entry of listedEntries) {
      const relativePath = safeRelativePath(entry.Path, label);
      const isFolder = entry.Folder === '+' || /D/.test(entry.Attributes ?? '');
      const isLink = entry['Symbolic Link'] != null || entry['Hard Link'] != null;
      if (isLink) throw new Error(`${label} contains a symbolic or hard link: ${entry.Path}`);
      if (isFolder || !isMedia(relativePath)) continue;

      const size = Number(entry.Size ?? 0);
      if (!Number.isSafeInteger(size) || size < 0) {
        throw new Error(`${label} contains an invalid file size: ${entry.Path}`);
      }
      declaredBytes += size;
      if (declaredBytes > MAX_UNCOMPRESSED_BYTES) {
        throw new Error(`${label} media is too large to extract safely`);
      }
      if (entry.Encrypted === '+') {
        throw new Error('Password-protected archives are not supported');
      }
      const destinationKey = process.platform === 'win32'
        ? relativePath.toLowerCase()
        : relativePath;
      if (normalizedDestinations.has(destinationKey)) {
        throw new Error(`${label} contains duplicate media paths`);
      }
      normalizedDestinations.add(destinationKey);
      mediaEntries.push(entry.Path);
    }

    const freeBytes = availableDiskBytes(tempDirectory);
    if (freeBytes !== null && declaredBytes > Math.max(0, freeBytes - DISK_RESERVE_BYTES)) {
      throw new Error(`Not enough free disk space to extract this ${label} safely`);
    }
    if (mediaEntries.length === 0) return { tempDirectory, mediaPaths: [] };

    const listFile = path.join(tempDirectory, '.foldiq-media-list.txt');
    fs.writeFileSync(listFile, mediaEntries.join('\n'), { encoding: 'utf8', flag: 'wx' });
    try {
      await execFileAsync(
        executable,
        ['x', '-y', '-aoa', '-spd', '-scsUTF-8', `-o${tempDirectory}`, '--', archivePath, `@${listFile}`],
        { encoding: 'utf8', maxBuffer: 4 * 1024 * 1024, windowsHide: true }
      );
    } catch (error) {
      const detail = [error.stdout, error.stderr, error.message].filter(Boolean).join('\n');
      if (looksEncrypted(detail)) {
        throw new Error('Password-protected archives are not supported');
      }
      throw new Error(`Could not extract this ${label} archive`);
    } finally {
      try { fs.rmSync(listFile, { force: true }); } catch {}
    }

    return { tempDirectory, mediaPaths: walkExtractedMedia(tempDirectory, isMedia) };
  } catch (error) {
    fs.rmSync(tempDirectory, { recursive: true, force: true });
    throw error;
  }
}

async function extractArchive(archivePath, isMedia) {
  const extension = path.extname(archivePath).toLowerCase();
  if (extension === '.zip') return extractZip(archivePath, isMedia);
  if (extension === '.rar' || extension === '.7z') {
    return extractWithSevenZip(archivePath, isMedia);
  }
  throw new Error(`Unsupported archive format: ${extension || 'unknown'}`);
}

module.exports = {
  extractArchive,
  extractZip,
  extractWithSevenZip,
  safeRelativePath,
  parseTechnicalListing,
  bundledSevenZipPath,
  MAX_ARCHIVE_ENTRIES,
  MAX_UNCOMPRESSED_BYTES,
};
