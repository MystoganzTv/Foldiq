// planner.js — Builds a list of planned file moves based on scan results + config
const fs = require('fs');
const path = require('path');

const MONTHS = [
  'January','February','March','April','May','June',
  'July','August','September','October','November','December',
];

const US_STATE_CODES = new Map(Object.entries({
  Alabama: 'AL', Alaska: 'AK', Arizona: 'AZ', Arkansas: 'AR', California: 'CA', Colorado: 'CO', Connecticut: 'CT', Delaware: 'DE', Florida: 'FL', Georgia: 'GA', Hawaii: 'HI', Idaho: 'ID', Illinois: 'IL', Indiana: 'IN', Iowa: 'IA', Kansas: 'KS', Kentucky: 'KY', Louisiana: 'LA', Maine: 'ME', Maryland: 'MD', Massachusetts: 'MA', Michigan: 'MI', Minnesota: 'MN', Mississippi: 'MS', Missouri: 'MO', Montana: 'MT', Nebraska: 'NE', Nevada: 'NV', 'New Hampshire': 'NH', 'New Jersey': 'NJ', 'New Mexico': 'NM', 'New York': 'NY', 'North Carolina': 'NC', 'North Dakota': 'ND', Ohio: 'OH', Oklahoma: 'OK', Oregon: 'OR', Pennsylvania: 'PA', 'Rhode Island': 'RI', 'South Carolina': 'SC', 'South Dakota': 'SD', Tennessee: 'TN', Texas: 'TX', Utah: 'UT', Vermont: 'VT', Virginia: 'VA', Washington: 'WA', 'West Virginia': 'WV', Wisconsin: 'WI', Wyoming: 'WY',
}));

function pad(n) { return String(n).padStart(2, '0'); }

function safeLocationPart(value) {
  if (typeof value !== 'string') return null;
  const cleaned = value
    .replace(/[<>:"/\\|?*\u0000-\u001F]/g, ' ')
    .replace(/[. ]+$/g, '')
    .replace(/\s+/g, ' ')
    .trim();
  return cleaned || null;
}

function locationParts(file) {
  const location = file.location || {};
  return {
    country: safeLocationPart(location.country),
    state: safeLocationPart(location.state),
    city: safeLocationPart(location.city),
  };
}

function locationDaySuffix(file) {
  const { city, state, country } = locationParts(file);
  const stateLabel = country === 'United States' ? (US_STATE_CODES.get(state) || state) : state;
  if (city && stateLabel && city.toLowerCase() !== stateLabel.toLowerCase()) return `${city} ${stateLabel}`;
  return city || stateLabel || country || null;
}

function buildDestPath(file, config) {
  if (file.userSetAside) {
    return path.join(config.outputFolder, 'Duplicates', 'To Review', file.name);
  }
  if (config.duplicateHandling === 'separate' && file.isDuplicate) {
    return path.join(config.outputFolder, 'Duplicates', 'Exact Duplicates', file.name);
  }
  if (config.duplicateHandling === 'separate' && file.isProbableDuplicate) {
    return path.join(config.outputFolder, 'Duplicates', 'To Review', file.name);
  }
  const date = new Date(file.date);
  const latest = Date.now() + 24 * 60 * 60 * 1000;
  const hasValidDate = !(
    !file.date ||
    Number.isNaN(date.getTime()) ||
    date.getFullYear() < 1900 ||
    date.getTime() > latest
  );

  if (config.organizationMode === 'location') {
    const { country, state, city } = locationParts(file);
    if (!config.useGPSLocation || (!country && !state && !city)) {
      return path.join(
        config.outputFolder,
        'Unknown Location',
        hasValidDate ? String(date.getFullYear()) : 'Unknown Date',
        file.name,
      );
    }
    const parts = [config.outputFolder, country || 'Unknown Country'];
    if (state) parts.push(state);
    if (city && city !== state) parts.push(city);
    parts.push(file.name);
    return path.join(...parts);
  }

  if (!hasValidDate) {
    return path.join(config.outputFolder, 'Unknown Date', file.name);
  }
  const y  = date.getFullYear();
  const m  = date.getMonth();
  const d  = date.getDate();

  const yearFolder  = String(y);
  const monthFolder = `${y}-${pad(m + 1)} ${MONTHS[m]}`;
  const dayFolder   = `${y}-${pad(m + 1)}-${pad(d)}`;

  let parts = [config.outputFolder, yearFolder];
  if (config.groupByMonth) parts.push(monthFolder);
  if (config.groupByDay) {
    const location = config.organizationMode === 'smart' && config.useGPSLocation
      ? locationDaySuffix(file)
      : null;
    parts.push(location ? `${dayFolder} ${location}` : dayFolder);
  }
  parts.push(file.name);

  return path.join(...parts);
}

function resolveCollision(destPath, usedPaths) {
  if (!usedPaths.has(destPath) && !fs.existsSync(destPath)) {
    usedPaths.add(destPath);
    return destPath;
  }

  const ext  = path.extname(destPath);
  const base = ext ? destPath.slice(0, -ext.length) : destPath;
  let i = 1;
  while (true) {
    const candidate = `${base}_${i}${ext}`;
    if (!usedPaths.has(candidate) && !fs.existsSync(candidate)) {
      usedPaths.add(candidate);
      return candidate;
    }
    i++;
  }
}

function buildPlan(files, config) {
  const usedPaths = new Set();
  const moves = [];

  for (const file of files) {
    if (file.userExcluded) {
      moves.push({
        ...file,
        action: 'skip',
        included: false,
        reason: 'user-choice',
        destPath: null,
      });
      continue;
    }

    // The user may leave duplicate extras untouched. Originals always remain in
    // the normal organized structure.
    if (!file.userSetAside && config.duplicateHandling === 'skip' && (file.isDuplicate || file.isProbableDuplicate)) {
      moves.push({
        ...file,
        action: 'skip',
        included: false,
        reason: 'duplicate',
        destPath: null,
      });
      continue;
    }

    const rawDest = buildDestPath(file, config);
    const destPath = resolveCollision(rawDest, usedPaths);

    moves.push({
      ...file,
      // Extracted files are temporary copies. The original remains inside the archive,
      // so they must behave as copies even when the user selected Move.
      action:   file.archiveSourcePath ? 'copy' : (config.copyMode ? 'copy' : 'move'),
      included: true,
      destPath,
      reason:   null,
    });
  }

  return moves;
}

module.exports = { buildPlan, buildDestPath, resolveCollision, locationParts, locationDaySuffix };
