const fs = require('fs');
const path = require('path');

const DEFAULTS = Object.freeze({
  outputFolder: '',
  organizationMode: 'smart',
  groupByMonth: true,
  groupByDay: true,
  copyMode: false,
  duplicateHandling: 'separate',
  includeVideos: true,
  includeArchives: true,
  useGPSLocation: false,
  shareAnonymousUsageData: false,
});

function normalizePreferences(value = {}) {
  const mode = ['smart', 'year', 'yearmonth', 'full', 'location'].includes(value.organizationMode)
    ? value.organizationMode
    : DEFAULTS.organizationMode;
  const duplicateHandling = ['separate', 'skip', 'organize'].includes(value.duplicateHandling)
    ? value.duplicateHandling
    : DEFAULTS.duplicateHandling;

  return {
    outputFolder: typeof value.outputFolder === 'string' && !value.outputFolder.includes('\0')
      ? value.outputFolder
      : DEFAULTS.outputFolder,
    organizationMode: mode,
    groupByMonth: mode === 'smart' || mode === 'full' || mode === 'yearmonth',
    groupByDay: mode === 'smart' || mode === 'full',
    copyMode: value.copyMode === true,
    duplicateHandling,
    includeVideos: value.includeVideos !== false,
    includeArchives: value.includeArchives !== false,
    useGPSLocation: value.useGPSLocation === true,
    shareAnonymousUsageData: value.shareAnonymousUsageData === true,
  };
}

function readPreferences(filePath) {
  try {
    return normalizePreferences(JSON.parse(fs.readFileSync(filePath, 'utf8')));
  } catch {
    return { ...DEFAULTS };
  }
}

function writePreferences(filePath, value) {
  const normalized = normalizePreferences(value);
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  const tempPath = `${filePath}.${process.pid}.tmp`;
  fs.writeFileSync(tempPath, JSON.stringify(normalized, null, 2), { encoding: 'utf8', flag: 'w' });
  fs.renameSync(tempPath, filePath);
  return normalized;
}

module.exports = { DEFAULTS, normalizePreferences, readPreferences, writePreferences };
