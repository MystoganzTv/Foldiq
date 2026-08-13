const os = require('os');

const SUPPORT_FORM = 'https://foldiq.app/contact.html?source=foldiq-windows';
const SAFE_FIELDS = [
  'sourceCount', 'includeVideos', 'includeArchives', 'batchNumber', 'count',
  'returned', 'code', 'files', 'warnings', 'elapsedMs',
];

function redactMessage(value) {
  return String(value ?? '')
    .replace(/[A-Za-z]:\\[^\r\n]*/g, '[local path]')
    .replace(/\/(?:Users|home)\/[^\r\n]*/g, '[local path]')
    .replace(/[\r\n]+/g, ' ')
    .slice(0, 300);
}

function parseEvents(logContent) {
  return String(logContent ?? '')
    .split(/\r?\n/)
    .filter(Boolean)
    .flatMap(line => {
      try {
        const event = JSON.parse(line);
        return event && typeof event === 'object' ? [event] : [];
      } catch {
        return [];
      }
    });
}

function selectEvents(events) {
  if (events.length <= 16) return events;
  const firstScan = events.find(event => event.event === 'scan-start');
  const recent = events.slice(-15);
  return firstScan && !recent.includes(firstScan) ? [firstScan, ...recent] : recent;
}

function formatEvent(event) {
  const details = [];
  for (const field of SAFE_FIELDS) {
    if (event[field] !== undefined) details.push(`${field}=${String(event[field]).slice(0, 80)}`);
  }
  if (event.message) details.push(`message=${redactMessage(event.message)}`);
  return `${redactMessage(event.at || 'unknown time')} | ${redactMessage(event.event || 'unknown event')}${details.length ? ` | ${details.join(' ')}` : ''}`;
}

function buildDiagnosticSummary({ logContent, appVersion, platform = process.platform, arch = process.arch, osRelease = os.release() }) {
  const events = selectEvents(parseEvents(logContent));
  return [
    '--- Foldiq diagnostic summary ---',
    `Version: ${redactMessage(appVersion || 'unknown')}`,
    `System: ${redactMessage(platform)} ${redactMessage(arch)} (${redactMessage(osRelease)})`,
    'Privacy: no photos, filenames, or folder paths are included.',
    '',
    ...(events.length ? events.map(formatEvent) : ['No scan events were recorded.']),
  ].join('\n');
}

function buildSupportWebURL(options) {
  return `${SUPPORT_FORM}#diagnostic=${encodeURIComponent(buildDiagnosticSummary(options))}`;
}

module.exports = {
  buildDiagnosticSummary,
  buildSupportWebURL,
  parseEvents,
  redactMessage,
  SUPPORT_FORM,
};
