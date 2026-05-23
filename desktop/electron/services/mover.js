// mover.js — Executes planned moves/copies with undo manifest
const fs   = require('fs');
const path = require('path');

function ensureDir(dir) {
  fs.mkdirSync(dir, { recursive: true });
}

function manifestPath(outputFolder) {
  const ts = new Date().toISOString().replace(/[:.]/g, '-');
  return path.join(outputFolder, `.foldiq-undo-${ts}.json`);
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

      if (item.action === 'copy') {
        fs.copyFileSync(item.path, item.destPath);
      } else {
        fs.renameSync(item.path, item.destPath);
      }

      manifest.moves.push({ src: item.path, dest: item.destPath, action: item.action });
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
  fs.writeFileSync(mPath, JSON.stringify(manifest, null, 2), 'utf-8');

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

  for (const entry of [...manifest.moves].reverse()) {
    try {
      fs.mkdirSync(path.dirname(entry.src), { recursive: true });
      if (entry.action === 'copy') {
        fs.rmSync(entry.dest, { force: true });
      } else {
        fs.renameSync(entry.dest, entry.src);
      }
    } catch (err) {
      errors.push({ file: entry.src, error: err.message });
    }
  }

  fs.rmSync(mPath, { force: true });
  return { restored: manifest.moves.length, errors };
}

function cleanEmptyFolders(roots) {
  for (const root of roots) {
    removeEmpty(root);
  }
}

function removeEmpty(dir) {
  if (!fs.existsSync(dir)) return;
  let entries;
  try { entries = fs.readdirSync(dir); } catch { return; }
  for (const e of entries) removeEmpty(path.join(dir, e));
  try {
    entries = fs.readdirSync(dir);
    if (entries.length === 0) fs.rmdirSync(dir);
  } catch {}
}

module.exports = { apply, undo };
