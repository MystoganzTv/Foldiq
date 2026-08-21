// mover.js — Executes planned moves/copies with undo manifest
const fs   = require('fs');
const path = require('path');
const crypto = require('crypto');

async function ensureDir(dir) {
  await fs.promises.mkdir(dir, { recursive: true });
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

async function listManifests(manifestDirectory, { includeCompleted = false } = {}) {
  let entries = [];
  try { entries = await fs.promises.readdir(manifestDirectory, { withFileTypes: true }); } catch { return []; }
  const manifests = [];
  for (const entry of entries) {
    if (!entry.isFile() || !/^foldiq-undo-[A-Za-z0-9.-]+\.json$/.test(entry.name)) continue;
    const filePath = path.join(manifestDirectory, entry.name);
    try {
      const manifest = JSON.parse(await fs.promises.readFile(filePath, 'utf8'));
      if (!Array.isArray(manifest.moves)) continue;
      const state = manifest.state || 'complete';
      if (!includeCompleted && !['applying', 'undoing', 'needs_attention'].includes(state)) continue;
      manifests.push({
        path: filePath,
        files: Math.max(manifest.moves.length, manifest.operations?.length || 0),
        createdAt: manifest.createdAt || null,
        state,
      });
    } catch {}
  }
  return manifests.sort((left, right) => String(left.createdAt || '').localeCompare(String(right.createdAt || '')));
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

async function exists(filePath) {
  try {
    await fs.promises.access(filePath);
    return true;
  } catch {
    return false;
  }
}

async function assertDestinationAvailable(destPath) {
  if (await exists(destPath)) {
    throw new Error(`Destination already exists; Foldiq will not overwrite it: ${destPath}`);
  }
}

async function moveWithoutOverwrite(src, dest) {
  await assertDestinationAvailable(dest);

  try {
    await fs.promises.rename(src, dest);
    return;
  } catch (error) {
    if (error.code !== 'EXDEV') throw error;
  }

  await fs.promises.copyFile(src, dest, fs.constants.COPYFILE_EXCL);
  try {
    const [sourceHash, destinationHash] = await Promise.all([hashFile(src), hashFile(dest)]);
    if (sourceHash !== destinationHash) {
      throw new Error(`Cross-volume copy verification failed for ${path.basename(src)}`);
    }
    await fs.promises.unlink(src);
  } catch (error) {
    try { await fs.promises.rm(dest, { force: true }); } catch {}
    throw error;
  }
}

async function writeManifestAtomic(mPath, manifest) {
  const tempPath = `${mPath}.${process.pid}.tmp`;
  const handle = await fs.promises.open(tempPath, 'wx');
  try {
    await handle.writeFile(JSON.stringify(manifest, null, 2), 'utf-8');
    await handle.sync();
  } finally {
    await handle.close();
  }
  try {
    await fs.promises.rename(tempPath, mPath);
  } catch (error) {
    try { await fs.promises.rm(tempPath, { force: true }); } catch {}
    throw error;
  }
}

async function apply(plan, config, onProgress, hooks = {}) {
  if (!config.manifestDirectory) throw new Error('Internal Undo storage is not configured');
  const moves   = plan.filter(f => f.action !== 'skip' && f.included !== false);
  const skipped = plan.filter(f => f.action === 'skip' || f.included === false);
  const manifest = {
    version: 2,
    state: 'applying',
    moves: [],
    operations: moves.map(item => ({
      src: item.path,
      dest: item.destPath,
      action: item.action,
      name: item.name,
      // Undo needs to know an extracted file came from an archive: its source is
      // a temp directory that cleanupTempDirs() removes after a successful Apply.
      archiveSourcePath: item.archiveSourcePath || null,
      status: 'pending',
    })),
    skipped,
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
  };
  const errors = [];
  const mPath  = manifestPath(config.manifestDirectory);

  await ensureDir(path.dirname(mPath));
  await writeManifestAtomic(mPath, manifest);

  for (let i = 0; i < moves.length; i++) {
    const item = moves[i];
    const operation = manifest.operations[i];
    onProgress({ current: i + 1, total: moves.length, file: item.name });

    try {
      await ensureDir(path.dirname(item.destPath));
      await assertDestinationAvailable(item.destPath);
      const sourceHash = await hashFile(item.path);
      const sourceSize = (await fs.promises.stat(item.path)).size;

      // Persist intent before touching the source. If the process stops after
      // the file operation but before the completion checkpoint, recovery can
      // still identify the file by this hash and safely reverse it.
      Object.assign(operation, { sha256: sourceHash, size: sourceSize, status: 'ready' });
      manifest.updatedAt = new Date().toISOString();
      await writeManifestAtomic(mPath, manifest);

      if (item.action === 'copy') {
        await fs.promises.copyFile(item.path, item.destPath, fs.constants.COPYFILE_EXCL);
        const copiedHash = await hashFile(item.destPath);
        if (copiedHash !== sourceHash) {
          await fs.promises.rm(item.destPath, { force: true });
          throw new Error(`Copy verification failed for ${item.name}`);
        }
      } else {
        await moveWithoutOverwrite(item.path, item.destPath);
      }

      manifest.moves.push({
        src: item.path,
        dest: item.destPath,
        action: item.action,
        archiveSourcePath: item.archiveSourcePath || null,
        sha256: sourceHash,
        size: sourceSize,
      });
      operation.status = 'complete';
      manifest.updatedAt = new Date().toISOString();
      await writeManifestAtomic(mPath, manifest);
    } catch (err) {
      operation.status = operation.status === 'ready' ? 'ready' : 'error';
      operation.error = err.message;
      errors.push({
        file: item.name,
        path: item.path,
        destPath: item.destPath,
        action: item.action,
        error: err.message,
      });
      manifest.updatedAt = new Date().toISOString();
      await writeManifestAtomic(mPath, manifest);
    }
    if (operation.status === 'complete') {
      await hooks.afterCommit?.({ index: i, item, manifestPath: mPath });
    }
  }

  manifest.state = 'complete';
  manifest.updatedAt = new Date().toISOString();
  await writeManifestAtomic(mPath, manifest);

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

async function undo(mPath, manifestDirectory = null, onProgress = () => {}) {
  if (manifestDirectory) assertInternalManifest(mPath, manifestDirectory);
  if (!fs.existsSync(mPath)) throw new Error('Manifest not found: ' + mPath);

  const manifest = JSON.parse(await fs.promises.readFile(mPath, 'utf-8'));
  const errors = [];
  manifest.state = 'undoing';
  manifest.updatedAt = new Date().toISOString();
  await writeManifestAtomic(mPath, manifest);

  async function moveBackWithoutBlocking(src, dest) {
    if (await exists(dest)) {
      throw new Error(`Original path is occupied; Foldiq will not overwrite it: ${dest}`);
    }
    await fs.promises.mkdir(path.dirname(dest), { recursive: true });
    try {
      await fs.promises.rename(src, dest);
      return;
    } catch (error) {
      if (error.code !== 'EXDEV') throw error;
    }
    await fs.promises.copyFile(src, dest, fs.constants.COPYFILE_EXCL);
    try {
      const [sourceHash, destinationHash] = await Promise.all([hashFile(src), hashFile(dest)]);
      if (sourceHash !== destinationHash) {
        throw new Error(`Cross-volume copy verification failed for ${path.basename(src)}`);
      }
      await fs.promises.unlink(src);
    } catch (error) {
      try { await fs.promises.rm(dest, { force: true }); } catch {}
      throw error;
    }
  }

  let restored = 0;
  const recorded = new Map(manifest.moves.map(entry => [`${entry.src}\n${entry.dest}`, entry]));
  for (const operation of manifest.operations || []) {
    if (!operation.sha256 || !['ready', 'complete'].includes(operation.status)) continue;
    const key = `${operation.src}\n${operation.dest}`;
    if (!recorded.has(key)) recorded.set(key, operation);
  }
  const entries = [...recorded.values()].reverse();
  for (let index = 0; index < entries.length; index++) {
    const entry = entries[index];
    onProgress({ current: index, total: entries.length, file: path.basename(entry.dest), phase: 'verifying' });
    try {
      if (!entry.sha256) {
        throw new Error('This manifest predates safe Undo verification; automatic Undo was refused');
      }

      if (!(await exists(entry.dest))) {
        // Undo may have been interrupted after completing this entry. Treat an
        // already-restored move, or an already-removed copy, as completed so a
        // retry can safely continue from its manifest.
        if (entry.action === 'copy') {
          restored++;
          onProgress({ current: index + 1, total: entries.length, file: path.basename(entry.dest), phase: 'restored' });
          continue;
        }
        if (await exists(entry.src)) {
          const restoredHash = await hashFile(entry.src);
          if (restoredHash === entry.sha256) {
            restored++;
            onProgress({ current: index + 1, total: entries.length, file: path.basename(entry.src), phase: 'restored' });
            continue;
          }
        }
        throw new Error(`Organized file is missing and the original could not be verified: ${entry.dest}`);
      }

      const currentHash = await hashFile(entry.dest);
      if (currentHash !== entry.sha256) {
        throw new Error(`Organized file changed after the operation; automatic Undo was refused: ${entry.dest}`);
      }

      if (entry.action === 'copy') {
        // Undoing a copy deletes the organized duplicate, which is only safe
        // while a recoverable source still exists. Extracted archive media is
        // always recoverable by reopening the untouched archive. A plain copy is
        // not: if the user deleted or replaced the originals after organizing,
        // this copy is the last surviving version, so refuse instead of
        // destroying it.
        if (!entry.archiveSourcePath) {
          if (!(await exists(entry.src))) {
            throw new Error(`The original is missing, so this organized copy is the only version left; automatic Undo was refused: ${entry.dest}`);
          }
          const originalHash = await hashFile(entry.src);
          if (originalHash !== entry.sha256) {
            throw new Error(`The original changed after organization; automatic Undo was refused: ${entry.dest}`);
          }
        }
        await fs.promises.unlink(entry.dest);
      } else {
        if (await exists(entry.src)) {
          const restoredHash = await hashFile(entry.src);
          if (restoredHash === entry.sha256) {
            // A cross-volume Undo may have been interrupted after its verified
            // copy completed but before the organized file was removed.
            await fs.promises.unlink(entry.dest);
            restored++;
            onProgress({ current: index + 1, total: entries.length, file: path.basename(entry.src), phase: 'restored' });
            continue;
          }
        }
        await moveBackWithoutBlocking(entry.dest, entry.src);
      }
      restored++;
      const operation = manifest.operations?.find(item => item.src === entry.src && item.dest === entry.dest);
      if (operation) operation.status = 'undone';
      manifest.updatedAt = new Date().toISOString();
      await writeManifestAtomic(mPath, manifest);
    } catch (err) {
      errors.push({ file: entry.src, error: err.message });
    }
    onProgress({ current: index + 1, total: entries.length, file: path.basename(entry.dest), phase: 'restored' });
  }

  manifest.state = errors.length === 0 ? 'undone' : 'needs_attention';
  manifest.updatedAt = new Date().toISOString();
  await writeManifestAtomic(mPath, manifest);
  if (errors.length === 0) await fs.promises.rm(mPath, { force: true });
  return { restored, errors, manifestPath: errors.length ? mPath : null };
}

function isSameOrInside(candidate, parent) {
  const relative = path.relative(path.resolve(parent), path.resolve(candidate));
  return relative === '' || (!relative.startsWith('..') && !path.isAbsolute(relative));
}

async function findEmptyFolders(roots, skipPaths = []) {
  const empty = [];
  const resolvedSkips = skipPaths.filter(Boolean).map(item => path.resolve(item));

  async function visit(directory, preserveRoot) {
    if (resolvedSkips.some(skip => isSameOrInside(directory, skip))) return false;
    let entries;
    try { entries = await fs.promises.readdir(directory, { withFileTypes: true }); } catch { return false; }
    let hasContent = false;
    for (const entry of entries) {
      const child = path.join(directory, entry.name);
      if (!entry.isDirectory()) {
        hasContent = true;
      } else if (!(await visit(child, false))) {
        hasContent = true;
      }
    }
    if (!hasContent && !preserveRoot) empty.push(directory);
    return !hasContent;
  }

  for (const root of roots) {
    try {
      if ((await fs.promises.stat(root)).isDirectory()) await visit(root, true);
    } catch {}
  }
  return empty.sort((left, right) => right.length - left.length);
}

async function removeEmptyFolders(roots, skipPaths = []) {
  const folders = await findEmptyFolders(roots, skipPaths);
  let removed = 0;
  for (const folder of folders) {
    try {
      await fs.promises.rmdir(folder);
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
  listManifests,
  assertInternalManifest,
  findEmptyFolders,
  removeEmptyFolders,
};
