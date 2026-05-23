// planner.js — Builds a list of planned file moves based on scan results + config
const path = require('path');

const MONTHS = [
  'January','February','March','April','May','June',
  'July','August','September','October','November','December',
];

function pad(n) { return String(n).padStart(2, '0'); }

function buildDestPath(file, config) {
  const date = new Date(file.date);
  const y  = date.getFullYear();
  const m  = date.getMonth();
  const d  = date.getDate();

  const yearFolder  = String(y);
  const monthFolder = `${y}-${pad(m + 1)} ${MONTHS[m]}`;
  const dayFolder   = `${y}-${pad(m + 1)}-${pad(d)}`;

  let parts = [config.outputFolder, yearFolder];
  if (config.groupByMonth) parts.push(monthFolder);
  if (config.groupByDay)   parts.push(dayFolder);
  parts.push(file.name);

  return path.join(...parts);
}

function resolveCollision(destPath, usedPaths) {
  if (!usedPaths.has(destPath)) { usedPaths.add(destPath); return destPath; }

  const ext  = path.extname(destPath);
  const base = destPath.slice(0, -ext.length);
  let i = 1;
  while (true) {
    const candidate = `${base}_${i}${ext}`;
    if (!usedPaths.has(candidate)) { usedPaths.add(candidate); return candidate; }
    i++;
  }
}

function buildPlan(files, config) {
  const usedPaths = new Set();
  const moves = [];

  for (const file of files) {
    // Skip duplicates if configured
    if (config.skipDuplicates && file.isDuplicate) {
      moves.push({ ...file, action: 'skip', reason: 'duplicate', destPath: null });
      continue;
    }

    const rawDest = buildDestPath(file, config);
    const destPath = resolveCollision(rawDest, usedPaths);

    moves.push({
      ...file,
      action:   config.copyMode ? 'copy' : 'move',
      destPath,
      reason:   null,
    });
  }

  return moves;
}

module.exports = { buildPlan };
