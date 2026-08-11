// mover.js — Executes planned moves/copies with undo manifest
const fs   = require('fs');
const path = require('path');
const crypto = require('crypto');

function ensureDir(dir) {
  fs.mkdirSync(dir, { recursive: true });
}

function manifestPath(outputFolder) {
  const ts = new Date().toISOString().replace(/[:.]/g, '-');
  return path.join(outputFolder, `.foldiq-undo-${ts}.json`);
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
  const moves   = plan.filter(f => f.action !== 'skip');
  const skipped = plan.filter(f => f.action === 'skip');
  const manifest = { moves: [], skipped, createdAt: new Date().toISOString() };
  const errors = [];
  const mPath  = manifestPath(config.outputFolder);

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
      errors.push({ file: item.name, error: err.message });
    }
  }

  // Clean up empty source folders if moving
  if (!config.copyMode) {
    cleanEmptyFolders(config.sourceFolders || []);
  }

  // Write manifest for undo
  ensureDir(path.dirname(mPath));
  writeManifestAtomic(mPath, manifest);

  return {
    moved:        manifest.moves.length,
    skipped:      skipped.length,
    errors,
    manifestPath: mPath,
  };
}

async function undo(mPath) {
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

function cleanEmptyFolders(roots) {
  for (const root of roots) {
    removeEmpty(root, true);
  }
}

function removeEmpty(dir, preserveRoot = false) {
  if (!fs.existsSync(dir)) return;
  let entries;
  try { entries = fs.readdirSync(dir); } catch { return; }
  for (const e of entries) removeEmpty(path.join(dir, e), false);
  try {
    entries = fs.readdirSync(dir);
    if (!preserveRoot && entries.length === 0) fs.rmdirSync(dir);
  } catch {}
}

module.exports = {
  apply,
  undo,
  hashFile,
  moveWithoutOverwrite,
  assertDestinationAvailable,
};
