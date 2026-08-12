const fs = require('fs');
const path = require('path');

const ARCHIVE_EXTENSIONS = new Set(['.zip', '.rar', '.7z']);

function isArchive(filePath) {
  return ARCHIVE_EXTENSIONS.has(path.extname(filePath).toLowerCase());
}

function filterSupportedSources(sourcePaths) {
  const supported = [];
  const seen = new Set();

  for (const sourcePath of sourcePaths) {
    if (typeof sourcePath !== 'string' || sourcePath.length === 0 || sourcePath.includes('\0')) continue;

    const resolved = path.resolve(sourcePath);
    const key = process.platform === 'win32' ? resolved.toLowerCase() : resolved;
    if (seen.has(key)) continue;

    try {
      const stat = fs.statSync(resolved);
      if (!stat.isDirectory() && !(stat.isFile() && isArchive(resolved))) continue;
      seen.add(key);
      supported.push(resolved);
    } catch {}
  }

  return supported;
}

module.exports = { ARCHIVE_EXTENSIONS, filterSupportedSources, isArchive };
