// scanner.js — Recursively scans folders for media files and extracts metadata
const fs   = require('fs');
const path = require('path');
const crypto = require('crypto');
const { exiftool } = require('exiftool-vendored');
const { extractArchive } = require('./archive');
const { isArchive } = require('./sources');

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
    } else if (entry.isFile() && isArchive(full)) {
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
  } else if (stat.isFile() && isArchive(sourcePath)) {
    archivePaths.add(sourcePath);
  }
}

async function cleanupTempDirs() {
  const directories = Array.from(tempDirectories);
  tempDirectories.clear();
  await Promise.all(directories.map(async directory => {
    try { await fs.promises.rm(directory, { recursive: true, force: true }); } catch {}
  }));
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

function dateFromTrustedMetadata(tags = {}, now = new Date()) {
  const candidates = [
    ['DateTimeOriginal', 'camera metadata'],
    ['DateTimeDigitized', 'camera metadata'],
    ['MediaCreateDate', 'video metadata'],
    ['TrackCreateDate', 'video metadata'],
    ['CreationDate', 'video metadata'],
    ['CreateDate', 'embedded metadata'],
  ];

  for (const [tag, source] of candidates) {
    const date = metadataDate(tags[tag], now);
    if (date) return { date, source, tag };
  }
  return null;
}

function resolveDateCandidates(metadataInfo, filenameDate) {
  if (!filenameDate) return metadataInfo;
  if (!metadataInfo) return { date: filenameDate, source: 'filename', tag: null };

  // Messaging and export apps sometimes replace embedded creation metadata with
  // the forwarding/export date. A much older date encoded in the filename is a
  // safer capture-date signal in that case (same policy as the macOS app).
  const ninetyDays = 90 * 24 * 60 * 60 * 1000;
  if (metadataInfo.date.getTime() - filenameDate.getTime() > ninetyDays) {
    return { date: filenameDate, source: 'filename', tag: null };
  }
  return metadataInfo;
}

async function extractDateInfo(filePath, now = new Date()) {
  let metadataInfo = null;
  try {
    const tags = await exiftool.read(filePath);
    metadataInfo = dateFromTrustedMetadata(tags, now);
  } catch {}

  const filenameDate = dateFromFilename(filePath, now);
  return resolveDateCandidates(metadataInfo, filenameDate);
}

async function extractDate(filePath, now = new Date()) {
  return (await extractDateInfo(filePath, now))?.date ?? null;
}

async function scan(folders, onProgress) {
  const progress = typeof onProgress === 'function' ? onProgress : () => {};
  progress({ phase: 'cleanup', current: 0, total: 0, file: 'Preparing temporary workspace…' });
  await cleanupTempDirs();
  const mediaPaths = new Set();
  const archivePaths = new Set();
  for (const folder of folders) collectSource(folder, mediaPaths, archivePaths);

  const allFiles = Array.from(mediaPaths, filePath => ({ filePath }));
  const warnings = [];
  let archivesExtracted = 0;

  const archiveList = Array.from(archivePaths);
  for (let archiveIndex = 0; archiveIndex < archiveList.length; archiveIndex++) {
    const archivePath = archiveList[archiveIndex];
    const archiveName = path.basename(archivePath);
    progress({
      phase: 'archive',
      current: archiveIndex,
      total: archiveList.length,
      file: `Reading ${archiveName}…`,
    });
    try {
      const extracted = await extractArchive(archivePath, isMedia, archiveProgress => {
        const messages = {
          listing: `Reading the contents of ${archiveName}…`,
          extracting: archiveProgress.file
            ? `Extracting ${archiveProgress.file} from ${archiveName}…`
            : `Extracting media from ${archiveName}…`,
          fallback: `Opening ${archiveName} with the compatibility engine…`,
        };
        progress({
          phase: 'archive',
          current: archiveProgress.current,
          total: archiveProgress.total,
          file: messages[archiveProgress.stage] ?? `Opening ${archiveName}…`,
        });
      });
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
    progress({
      phase: 'archive-list',
      current: archiveIndex + 1,
      total: archiveList.length,
      file: archiveName,
    });
  }

  const preparedFiles = [];
  const sizeCounts = new Map();
  for (let i = 0; i < allFiles.length; i++) {
    const candidate = allFiles[i];
    progress({
      phase: 'indexing',
      current: i,
      total: allFiles.length,
      file: `Indexing ${path.basename(candidate.filePath)}…`,
    });
    try {
      const stat = await fs.promises.stat(candidate.filePath);
      if (!stat.isFile()) continue;
      preparedFiles.push({ candidate, stat });
      sizeCounts.set(stat.size, (sizeCounts.get(stat.size) ?? 0) + 1);
    } catch {}
  }

  const total = preparedFiles.length;
  const files = [];
  const hashMap = new Map();

  for (let i = 0; i < preparedFiles.length; i++) {
    const { candidate, stat } = preparedFiles[i];
    const filePath = candidate.filePath;
    const ext  = path.extname(filePath).toLowerCase();
    progress({
      phase: 'media',
      current: i,
      total,
      file: `Analyzing ${path.basename(filePath)}…`,
    });
    const [dateInfo, hash] = await Promise.all([
      extractDateInfo(filePath),
      sizeCounts.get(stat.size) > 1 ? hashFile(filePath) : Promise.resolve(null),
    ]);

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
      date:        dateInfo?.date.toISOString() ?? null,
      dateSource:  dateInfo?.source ?? null,
      dateTag:     dateInfo?.tag ?? null,
      hash,
      isDuplicate: isDuplicate,
      duplicateOf: isDuplicate ? duplicateOf : null,
      archiveSourcePath: candidate.archiveSourcePath ?? null,
      archiveTempDirectory: candidate.archiveTempDirectory ?? null,
    };

    files.push(file);
    progress({ phase: 'media', current: i + 1, total, file: file.name });
  }

  return { files, archivesExtracted, warnings };
}

async function end() {
  await cleanupTempDirs();
  try { await exiftool.end(); } catch {}
}

module.exports = {
  scan,
  hashFile,
  cleanupTempDirs,
  isPlausibleDate,
  metadataDate,
  dateFromFilename,
  dateFromTrustedMetadata,
  resolveDateCandidates,
  extractDateInfo,
  extractDate,
  end,
};
