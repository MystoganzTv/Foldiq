// mover.js — Executes planned moves/copies with undo manifest
const fs   = require('fs');
const path = require('path');
const crypto = require('crypto');

function ensureDir(dir) {
  fs.mkdirSync(dir, { recursive: true });
}

function manifestPath(manifestDirectory) {
  const ts = new Date().toISOString().replace(/[:.]/g, '-');
  return path.join(manifestDirectory, `foldiq-undo-${ts}-${crypto.randomUUID()}.json`);
}

function isPathInside(directory, candidate) {
  const relative = path.relative(path.resolve(directory), path.resolve(candidate));
  return relative !== '' && !relative.startsWith('..') && !path.isAbsolute(relative);
}

function assertInternalManifest(mPath, manifestDirectory) {
  if (
    !isPathInside(manifestDirectory, mPath) ||
    !/^foldiq-undo-[A-Za-z0-9.-]+\.json$/.test(path.basename(mPath))
  ) {
    throw new Error('Invalid internal Undo manifest path');
  }
}

function discardManifest(mPath, manifestDirectory) {
  assertInternalManifest(mPath, manifestDirectory);
  fs.rmSync(mPath, { force: true });
}

function cleanupManifests(manifestDirectory) {
  let entries = [];
  try { entries = fs.readdirSync(manifestDirectory, { withFileTypes: true }); } catch { return; }
  for (const entry of entries) {
    if (entry.isFile() && /^foldiq-undo-[A-Za-z0-9.-]+\.json$/.test(entry.name)) {
      fs.rmSync(path.join(manifestDirectory, entry.name), { force: true });
    }
  }
}

function hashFile(filePath) {
  return new Promise((resolve, reject) => {
    const hash = crypto.createHash('sha256');
    const stream = fs.createReadStream(filePath);
    stream.on('data', chunk => hash.update(chunk));
    stream.on('error', reject);
    stream.on('end', () => resolve(hash.digest('hex')));
  });
}

function assertDestinationAvailable(destPath) {
  if (fs.existsSync(destPath)) {
    throw new Error(`Destination already exists; Foldiq will not overwrite it: ${destPath}`);
  }
}

async function moveWithoutOverwrite(src, dest) {
  assertDestinationAvailable(dest);

  try {
    fs.renameSync(src, dest);
    return;
  } catch (error) {
    if (error.code !== 'EXDEV') throw error;
  }

  fs.copyFileSync(src, dest, fs.constants.COPYFILE_EXCL);
  try {
    const [sourceHash, destinationHash] = await Promise.all([hashFile(src), hashFile(dest)]);
    if (sourceHash !== destinationHash) {
      throw new Error(`Cross-volume copy verification failed for ${path.basename(src)}`);
    }
    fs.unlinkSync(src);
  } catch (error) {
    try { fs.rmSync(dest, { force: true }); } catch {}
    throw error;
  }
}

function writeManifestAtomic(mPath, manifest) {
  const tempPath = `${mPath}.${process.pid}.tmp`;
  fs.writeFileSync(tempPath, JSON.stringify(manifest, null, 2), {
    encoding: 'utf-8',
    flag: 'wx',
  });
  fs.renameSync(tempPath, mPath);
}

async function apply(plan, config, onProgress) {
  if (!config.manifestDirectory) throw new Error('Internal Undo storage is not configured');
  const moves   = plan.filter(f => f.action !== 'skip' && f.included !== false);
  const skipped = plan.filter(f => f.action === 'skip' || f.included === false);
  const manifest = { moves: [], skipped, createdAt: new Date().toISOString() };
  const errors = [];
  const mPath  = manifestPath(config.manifestDirectory);

  for (let i = 0; i < moves.length; i++) {
    const item = moves[i];
    onProgress({ current: i + 1, total: moves.length, file: item.name });

    try {
      ensureDir(path.dirname(item.destPath));
      assertDestinationAvailable(item.destPath);
      const sourceHash = await hashFile(item.path);
      const sourceSize = fs.statSync(item.path).size;

      if (item.action === 'copy') {
        fs.copyFileSync(item.path, item.destPath, fs.constants.COPYFILE_EXCL);
      } else {
        await moveWithoutOverwrite(item.path, item.destPath);
      }

      manifest.moves.push({
        src: item.path,
        dest: item.destPath,
        action: item.action,
        sha256: sourceHash,
        size: sourceSize,
      });
    } catch (err) {
      errors.push({
        file: item.name,
        path: item.path,
        destPath: item.destPath,
        action: item.action,
        error: err.message,
      });
    }
  }

  // Write manifest for undo
  ensureDir(path.dirname(mPath));
  writeManifestAtomic(mPath, manifest);

  return {
    moved:        manifest.moves.length,
    skipped:      skipped.length,
    errors,
    manifestPath: mPath,
    manifestPaths: [mPath],
    completed: manifest.moves.map(entry => ({
      path: entry.src,
      destPath: entry.dest,
      action: entry.action,
    })),
  };
}

async function undo(mPath, manifestDirectory = null) {
  if (manifestDirectory) assertInternalManifest(mPath, manifestDirectory);
  if (!fs.existsSync(mPath)) throw new Error('Manifest not found: ' + mPath);

  const manifest = JSON.parse(fs.readFileSync(mPath, 'utf-8'));
  const errors = [];

  let restored = 0;
  for (const entry of [...manifest.moves].reverse()) {
    try {
      if (!fs.existsSync(entry.dest)) {
        throw new Error(`Organized file is missing; nothing was removed: ${entry.dest}`);
      }

      if (!entry.sha256) {
        throw new Error('This manifest predates safe Undo verification; automatic Undo was refused');
      }

      const currentHash = await hashFile(entry.dest);
      if (currentHash !== entry.sha256) {
        throw new Error(`Organized file changed after the operation; automatic Undo was refused: ${entry.dest}`);
      }

      if (entry.action === 'copy') {
        fs.unlinkSync(entry.dest);
      } else {
        if (fs.existsSync(entry.src)) {
          throw new Error(`Original path is occupied; Foldiq will not overwrite it: ${entry.src}`);
        }
        fs.mkdirSync(path.dirname(entry.src), { recursive: true });
        await moveWithoutOverwrite(entry.dest, entry.src);
      }
      restored++;
    } catch (err) {
      errors.push({ file: entry.src, error: err.message });
    }
  }

  if (errors.length === 0) fs.rmSync(mPath, { force: true });
  return { restored, errors, manifestPath: errors.length ? mPath : null };
}

function isSameOrInside(candidate, parent) {
  const relative = path.relative(path.resolve(parent), path.resolve(candidate));
  return relative === '' || (!relative.startsWith('..') && !path.isAbsolute(relative));
}

function findEmptyFolders(roots, skipPaths = []) {
  const empty = [];
  const resolvedSkips = skipPaths.filter(Boolean).map(item => path.resolve(item));

  function visit(directory, preserveRoot) {
    if (resolvedSkips.some(skip => isSameOrInside(directory, skip))) return false;
    let entries;
    try { entries = fs.readdirSync(directory, { withFileTypes: true }); } catch { return false; }
    let hasContent = false;
    for (const entry of entries) {
      const child = path.join(directory, entry.name);
      if (!entry.isDirectory()) {
        hasContent = true;
      } else if (!visit(child, false)) {
        hasContent = true;
      }
    }
    if (!hasContent && !preserveRoot) empty.push(directory);
    return !hasContent;
  }

  for (const root of roots) {
    try {
      if (fs.statSync(root).isDirectory()) visit(root, true);
    } catch {}
  }
  return empty.sort((left, right) => right.length - left.length);
}

function removeEmptyFolders(roots, skipPaths = []) {
  const folders = findEmptyFolders(roots, skipPaths);
  let removed = 0;
  for (const folder of folders) {
    try {
      fs.rmdirSync(folder);
      removed++;
    } catch {}
  }
  return removed;
}

module.exports = {
  apply,
  undo,
  hashFile,
  moveWithoutOverwrite,
  assertDestinationAvailable,
  discardManifest,
  cleanupManifests,
  assertInternalManifest,
  findEmptyFolders,
  removeEmptyFolders,
};
