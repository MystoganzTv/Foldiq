const test = require('node:test');
const assert = require('node:assert/strict');
const { buildSupportEmailURL, parseEvents, redactMessage } = require('../electron/services/diagnostics');

test('diagnostic parser ignores malformed log lines', () => {
  assert.deepEqual(parseEvents('{"event":"app-start"}\nnot-json\n{"event":"scan-start"}\n'), [
    { event: 'app-start' },
    { event: 'scan-start' },
  ]);
});

test('support email contains useful diagnostics without local paths', () => {
  const logContent = [
    JSON.stringify({ at: '2026-08-12T18:00:00Z', event: 'scan-start', sourceCount: 1, includeVideos: true }),
    JSON.stringify({ at: '2026-08-12T18:00:15Z', event: 'metadata-batch-error', batchNumber: 2, message: 'Failed at C:\\Users\\Jane Doe\\Pictures\\private.heic' }),
  ].join('\n');
  const url = buildSupportEmailURL({ logContent, appVersion: '1.0.12', platform: 'win32', arch: 'x64', osRelease: '10.0' });
  const decoded = decodeURIComponent(url);

  assert.match(decoded, /^mailto:support@foldiq\.app\?/);
  assert.match(decoded, /metadata-batch-error/);
  assert.match(decoded, /Windows version|System: win32 x64/);
  assert.match(decoded, /\[local path\]/);
  assert.doesNotMatch(decoded, /Jane Doe|private\.heic|Pictures/);
  assert.match(decoded, /no photos, filenames, or folder paths are included/i);
});

test('diagnostic message redaction removes Unix home paths', () => {
  assert.equal(redactMessage('Error /Users/enrique/Photos/private.heic'), 'Error [local path]');
});
