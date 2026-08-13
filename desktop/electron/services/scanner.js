// scanner.js — Recursively scans folders for media files and extracts metadata
const fs   = require('fs');
const path = require('path');
const crypto = require('crypto');
const { spawn } = require('child_process');
const { exiftoolPath } = require('exiftool-vendored');
const { extractArchive } = require('./archive');
const { isArchive } = require('./sources');
const { VisualHashWorker } = require('./visual-hash');
const {
  detectSmartDuplicates,
  markExactDuplicates,
  visualCandidateIndexes,
} = require('./smart-duplicates');

const SUPPORTED = new Set([
  '.jpg', '.jpeg', '.png', '.heic', '.heif',
  '.tiff', '.tif', '.webp',
  '.cr2', '.cr3', '.nef', '.arw', '.dng', '.raf', '.orf', '.rw2',
  '.mov', '.mp4', '.m4v', '.avi', '.mkv',
]);
const EARLIEST_YEAR = 1900;
const MAX_FUTURE_OFFSET_MS = 24 * 60 * 60 * 1000;
const METADATA_BATCH_SIZE = 40;
const METADATA_CONCURRENCY = 2;
const HASH_CONCURRENCY = 2;
// Two HEIC/TIFF decoder workers cut visual comparison time substantially while
// keeping peak decoded-image memory bounded on ordinary Windows machines.
const VISUAL_HASH_CONCURRENCY = 2;
const METADATA_TIMEOUT_MS = 15 * 1000;
const METADATA_READ_ARGS = [
  '-fast',
  // Keep coordinates and duration machine-readable. Without -n ExifTool emits
  // GPS values as DMS text (for example `38 deg ... N`), which Number()
  // correctly rejects and caused valid Windows GPS metadata to disappear.
  '-n',
  '-api', 'largefilesupport=1',
  '-DateTimeOriginal',
  '-DateTimeDigitized',
  '-MediaCreateDate',
  '-TrackCreateDate',
  '-CreationDate',
  '-CreateDate',
  '-Make', '-Model', '-ImageWidth', '-ImageHeight',
  '-GPSLatitude', '-GPSLongitude', '-Duration',
];
let diagnosticsLogPath = null;

function configureDiagnostics(logPath) {
  diagnosticsLogPath = logPath;
  if (!logPath) return;
  try {
    fs.mkdirSync(path.dirname(logPath), { recursive: true });
    fs.writeFileSync(logPath, `${JSON.stringify({ at: new Date().toISOString(), event: 'app-start' })}\n`);
  } catch {}
}

function diagnostic(event, details = {}) {
  if (!diagnosticsLogPath) return;
  try {
    fs.appendFileSync(diagnosticsLogPath, `${JSON.stringify({ at: new Date().toISOString(), event, ...details })}\n`);
  } catch {}
}

function abortError() {
  const error = new Error('Scan cancelled');
  error.name = 'AbortError';
  return error;
}

function throwIfAborted(signal) {
  if (signal?.aborted) throw abortError();
}

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

async function walkDir(root, mediaPaths, archivePaths, signal, onDirectory = () => {}) {
  const pending = [root];
  while (pending.length > 0) {
    throwIfAborted(signal);
    const dir = pending.pop();
    let entries;
    try { entries = await fs.promises.readdir(dir, { withFileTypes: true }); }
    catch { continue; }
    onDirectory(dir);

    for (const entry of entries) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) pending.push(full);
      else if (entry.isFile() && isMedia(full)) mediaPaths.add(full);
      else if (entry.isFile() && isArchive(full)) archivePaths.add(full);
    }
    // Yield between folders so Electron can paint progress and process Cancel.
    await new Promise(resolve => setImmediate(resolve));
  }
}

async function collectSource(sourcePath, mediaPaths, archivePaths, signal, onDirectory) {
  let stat;
  try { stat = await fs.promises.stat(sourcePath); } catch { return; }

  if (stat.isDirectory()) {
    await walkDir(sourcePath, mediaPaths, archivePaths, signal, onDirectory);
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

function metadataResult(filePath, tags = {}, now = new Date()) {
  const metadataInfo = dateFromTrustedMetadata(tags, now);
  const filenameDate = dateFromFilename(filePath, now);
  const dateInfo = resolveDateCandidates(metadataInfo, filenameDate);
  const number = value => Number.isFinite(Number(value)) ? Number(value) : null;
  return {
    dateInfo,
    cameraMake: typeof tags.Make === 'string' ? tags.Make : null,
    cameraModel: typeof tags.Model === 'string' ? tags.Model : null,
    pixelWidth: number(tags.ImageWidth),
    pixelHeight: number(tags.ImageHeight),
    latitude: number(tags.GPSLatitude),
    longitude: number(tags.GPSLongitude),
    durationSeconds: number(tags.Duration),
  };
}

async function resolveExiftoolExecutable({
  platform = process.platform,
  resourcesPath = process.resourcesPath,
  projectRoot = path.resolve(__dirname, '..', '..'),
} = {}) {
  if (platform === 'win32') {
    const candidates = [
      resourcesPath && path.join(resourcesPath, 'exiftool', 'exiftool.exe'),
      path.join(projectRoot, '.vendor', 'exiftool-win', 'exiftool.exe'),
    ].filter(Boolean);
    const executable = candidates.find(candidate => fs.existsSync(candidate));
    if (!executable) {
      const error = new Error('The Windows metadata engine is missing from this Foldiq installation');
      error.code = 'EXIFTOOL_RUNTIME_MISSING';
      throw error;
    }
    return executable;
  }

  return Promise.resolve(typeof exiftoolPath === 'function' ? exiftoolPath() : exiftoolPath);
}

async function runMetadataBatch(filePaths, { signal, batchNumber = 0 } = {}) {
  throwIfAborted(signal);
  if (filePaths.some(filePath => /[\r\n]/.test(filePath))) {
    const error = new Error('A filename contains an unsupported line break');
    error.code = 'METADATA_UNSUPPORTED_PATH';
    throw error;
  }
  const executable = await resolveExiftoolExecutable();
  // Windows limits CreateProcess command lines to roughly 32K characters. Large NAS
  // libraries easily exceed that with 40 full paths, so stream the paths via
  // ExifTool's argument-file input instead.
  const args = ['-json', '-charset', 'filename=utf8', ...METADATA_READ_ARGS, '-@', '-'];
  const timeoutMs = Math.min(60_000, Math.max(METADATA_TIMEOUT_MS, filePaths.length * 1_500));
  diagnostic('metadata-batch-start', { batchNumber, count: filePaths.length });

  return new Promise((resolve, reject) => {
    const child = spawn(executable, args, { windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] });
    let stdout = '';
    let stderr = '';
    let settled = false;
    const finish = (callback, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      signal?.removeEventListener('abort', onAbort);
      callback(value);
    };
    const onAbort = () => {
      child.kill();
      finish(reject, abortError());
    };
    const timeout = setTimeout(() => {
      child.kill();
      const error = new Error(`Metadata batch timed out after ${timeoutMs / 1000} seconds`);
      error.code = 'METADATA_TIMEOUT';
      finish(reject, error);
    }, timeoutMs);

    signal?.addEventListener('abort', onAbort, { once: true });
    child.stdout.on('data', chunk => {
      stdout += chunk.toString('utf8');
      if (stdout.length > 32 * 1024 * 1024) onAbort();
    });
    child.stdin.on('error', () => {});
    child.stdin.end(`${filePaths.join('\n')}\n`);
    child.stderr.on('data', chunk => { stderr = (stderr + chunk.toString('utf8')).slice(-8192); });
    child.on('error', error => finish(reject, error));
    child.on('close', code => {
      if (settled) return;
      try {
        if (code !== 0 && !stdout.trim()) throw new Error(stderr.trim() || `ExifTool exited with code ${code}`);
        const rows = JSON.parse(stdout || '[]');
        diagnostic('metadata-batch-finish', { batchNumber, count: filePaths.length, returned: rows.length, code });
        finish(resolve, rows);
      } catch (error) {
        finish(reject, error);
      }
    });
  });
}

async function readMetadataWithRecovery(filePaths, {
  signal,
  batchNumber = 0,
  runner = runMetadataBatch,
  onRetry = () => {},
} = {}) {
  throwIfAborted(signal);
  try {
    return {
      rows: await runner(filePaths, { signal, batchNumber }),
      failedCount: 0,
      splitCount: 0,
    };
  } catch (error) {
    if (error.name === 'AbortError') throw error;
    if (filePaths.length <= 1) {
      diagnostic('metadata-file-error', { batchNumber, message: error.message });
      return { rows: [], failedCount: 1, splitCount: 0 };
    }

    diagnostic('metadata-batch-retry', { batchNumber, count: filePaths.length, message: error.message });
    onRetry(filePaths.length);
    const middle = Math.ceil(filePaths.length / 2);
    const left = await readMetadataWithRecovery(filePaths.slice(0, middle), {
      signal, batchNumber, runner, onRetry,
    });
    const right = await readMetadataWithRecovery(filePaths.slice(middle), {
      signal, batchNumber, runner, onRetry,
    });
    return {
      rows: [...left.rows, ...right.rows],
      failedCount: left.failedCount + right.failedCount,
      splitCount: left.splitCount + right.splitCount + 1,
    };
  }
}

async function extractDateInfo(filePath, now = new Date()) {
  try {
    const rows = await runMetadataBatch([filePath]);
    return metadataResult(filePath, rows[0], now).dateInfo;
  } catch {
    return metadataResult(filePath, {}, now).dateInfo;
  }
}

async function extractDate(filePath, now = new Date()) {
  return (await extractDateInfo(filePath, now))?.date ?? null;
}

async function mapWithConcurrency(items, concurrency, worker) {
  const results = new Array(items.length);
  let nextIndex = 0;

  async function runWorker(workerIndex) {
    while (true) {
      const index = nextIndex++;
      if (index >= items.length) return;
      results[index] = await worker(items[index], index, workerIndex);
    }
  }

  const workerCount = Math.min(items.length, Math.max(1, concurrency));
  await Promise.all(Array.from({ length: workerCount }, (_, workerIndex) => runWorker(workerIndex)));
  return results;
}

async function scan(folders, onProgress, options = {}) {
  const { signal, includeVideos = true, includeArchives = true } = options;
  const progress = typeof onProgress === 'function' ? onProgress : () => {};
  const startedAt = Date.now();
  diagnostic('scan-start', { sourceCount: folders.length, includeVideos, includeArchives });
  throwIfAborted(signal);
  progress({ phase: 'cleanup', current: 0, total: 0, file: 'Preparing temporary workspace…' });
  await cleanupTempDirs();
  const mediaPaths = new Set();
  const archivePaths = new Set();
  for (const folder of folders) {
    await collectSource(folder, mediaPaths, archivePaths, signal, directory => {
      progress({ phase: 'discovering', current: mediaPaths.size, total: 0, file: `Looking in ${path.basename(directory)}…` });
    });
  }
  if (!includeArchives) archivePaths.clear();
  if (!includeVideos) {
    for (const filePath of mediaPaths) {
      if (['.mov', '.mp4', '.m4v', '.avi', '.mkv'].includes(path.extname(filePath).toLowerCase())) mediaPaths.delete(filePath);
    }
  }

  const allFiles = Array.from(mediaPaths, filePath => ({ filePath }));
  const warnings = [];
  let archivesExtracted = 0;

  const archiveList = Array.from(archivePaths);
  for (let archiveIndex = 0; archiveIndex < archiveList.length; archiveIndex++) {
    throwIfAborted(signal);
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
      }, signal);
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
      if (signal?.aborted) throw abortError();
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
    throwIfAborted(signal);
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
  const metadataBatches = [];
  for (let index = 0; index < preparedFiles.length; index += METADATA_BATCH_SIZE) {
    metadataBatches.push(preparedFiles.slice(index, index + METADATA_BATCH_SIZE));
  }
  let metadataCompleted = 0;
  const metadataWarnings = [];
  const batchResults = await mapWithConcurrency(
    metadataBatches,
    METADATA_CONCURRENCY,
    async (batch, batchIndex) => {
      throwIfAborted(signal);
      progress({
        phase: 'metadata',
        current: metadataCompleted,
        total,
        file: `Reading capture dates in batch ${batchIndex + 1} of ${metadataBatches.length}`,
      });
      const recovery = await readMetadataWithRecovery(
        batch.map(item => item.candidate.filePath),
        {
          signal,
          batchNumber: batchIndex + 1,
          onRetry: count => progress({
            phase: 'metadata',
            current: metadataCompleted,
            total,
            file: `Recovering dates from a slow group of ${count} files…`,
          }),
        }
      );
      const rows = recovery.rows;
      if (recovery.failedCount > 0) {
        metadataWarnings.push(`${recovery.failedCount} file${recovery.failedCount === 1 ? '' : 's'} could not be read in metadata batch ${batchIndex + 1}`);
      }
      const byPath = new Map(rows.map(row => [
        path.resolve(row.SourceFile || '').toLowerCase(), row,
      ]));
      const result = batch.map(item => metadataResult(
        item.candidate.filePath,
        byPath.get(path.resolve(item.candidate.filePath).toLowerCase()) || {}
      ));
      metadataCompleted += batch.length;
      progress({
        phase: 'metadata',
        current: metadataCompleted,
        total,
        file: `Metadata read: ${metadataCompleted.toLocaleString()} of ${total.toLocaleString()}`,
      });
      return result;
    }
  );
  const metadataResults = batchResults.flat();
  if (metadataWarnings.length > 0) {
    warnings.push({ archive: 'Metadata', message: metadataWarnings.join(' ') });
  }

  const duplicateCandidates = preparedFiles
    .map((prepared, index) => ({ prepared, index }))
    .filter(({ prepared }) => sizeCounts.get(prepared.stat.size) > 1);
  let hashesCompleted = 0;
  const hashResults = await mapWithConcurrency(
    duplicateCandidates,
    HASH_CONCURRENCY,
    async ({ prepared }) => {
      throwIfAborted(signal);
      const name = path.basename(prepared.candidate.filePath);
      progress({
        phase: 'duplicates',
        current: hashesCompleted,
        total: duplicateCandidates.length,
        file: `Checking possible duplicate: ${name}`,
      });
      const hash = await hashFile(prepared.candidate.filePath);
      hashesCompleted++;
      progress({
        phase: 'duplicates',
        current: hashesCompleted,
        total: duplicateCandidates.length,
        file: `Possible duplicates checked: ${hashesCompleted.toLocaleString()} of ${duplicateCandidates.length.toLocaleString()}`,
      });
      return hash;
    }
  );
  const hashesByIndex = new Map(
    duplicateCandidates.map((candidate, resultIndex) => [candidate.index, hashResults[resultIndex]])
  );

  const files = [];
  for (let i = 0; i < preparedFiles.length; i++) {
    const { candidate, stat } = preparedFiles[i];
    const filePath = candidate.filePath;
    const ext = path.extname(filePath).toLowerCase();
    const metadata = metadataResults[i] || metadataResult(filePath);
    const dateInfo = metadata.dateInfo;
    const hash = hashesByIndex.get(i) ?? null;
    progress({
      phase: 'finalizing',
      current: i,
      total,
      file: `Preparing result: ${path.basename(filePath)}`,
    });

    const id = files.length;

    const file = {
      id,
      path:        filePath,
      name:        path.basename(filePath),
      ext,
      size:        stat.size,
      date:        dateInfo?.date.toISOString() ?? null,
      dateSource:  dateInfo?.source ?? null,
      dateTag:     dateInfo?.tag ?? null,
      cameraMake: metadata.cameraMake,
      cameraModel: metadata.cameraModel,
      pixelWidth: metadata.pixelWidth,
      pixelHeight: metadata.pixelHeight,
      latitude: metadata.latitude,
      longitude: metadata.longitude,
      durationSeconds: metadata.durationSeconds,
      hash,
      isDuplicate: false,
      duplicateOf: null,
      archiveSourcePath: candidate.archiveSourcePath ?? null,
      archiveTempDirectory: candidate.archiveTempDirectory ?? null,
      fileModifiedDate: isPlausibleDate(stat.mtime) ? stat.mtime.toISOString() : null,
    };

    files.push(file);
    progress({ phase: 'finalizing', current: i + 1, total, file: file.name });
  }

  // Elect the best original for every exact group after all metadata is known.
  // This fixes Windows choosing whichever path happened to be scanned first.
  markExactDuplicates(files);

  const visualIndexes = Array.from(visualCandidateIndexes(
    files.filter(file => !file.isDuplicate)
  ));
  const nonExactFiles = files.filter(file => !file.isDuplicate);
  let visualCompleted = 0;
  const visualWorkers = Array.from(
    { length: Math.min(VISUAL_HASH_CONCURRENCY, Math.max(1, visualIndexes.length)) },
    () => new VisualHashWorker()
  );
  try {
    await mapWithConcurrency(visualIndexes, VISUAL_HASH_CONCURRENCY, async (visualIndex, _index, workerIndex) => {
      throwIfAborted(signal);
      const file = nonExactFiles[visualIndex];
      progress({
        phase: 'similarity',
        current: visualCompleted,
        total: visualIndexes.length,
        file: `Comparing image: ${file.name}`,
      });
      file.visualHashes = await visualWorkers[workerIndex].compute(file.path, file.pixelWidth, file.pixelHeight, signal);
      visualCompleted++;
      progress({
        phase: 'similarity',
        current: visualCompleted,
        total: visualIndexes.length,
        file: `Images compared: ${visualCompleted.toLocaleString()} of ${visualIndexes.length.toLocaleString()}`,
      });
    });
  } finally {
    await Promise.all(visualWorkers.map(worker => worker.close()));
  }

  const smartResult = detectSmartDuplicates(files);
  for (const file of files) delete file.visualHashes;

  diagnostic('scan-finish', {
    files: files.length,
    smartDuplicateGroups: smartResult.groups,
    smartMatchedFiles: smartResult.matchedFiles,
    warnings: warnings.length,
    elapsedMs: Date.now() - startedAt,
  });
  return { files, archivesExtracted, warnings, diagnosticsAvailable: Boolean(diagnosticsLogPath) };
}

function detectProbableDuplicates(files) {
  return detectSmartDuplicates(files);
}

async function end() {
  await cleanupTempDirs();
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
  metadataResult,
  resolveExiftoolExecutable,
  runMetadataBatch,
  readMetadataWithRecovery,
  detectProbableDuplicates,
  configureDiagnostics,
  mapWithConcurrency,
  METADATA_CONCURRENCY,
  HASH_CONCURRENCY,
  VISUAL_HASH_CONCURRENCY,
  METADATA_TIMEOUT_MS,
  end,
};
