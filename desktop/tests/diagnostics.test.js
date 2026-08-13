const test = require('node:test');
const assert = require('node:assert/strict');
const { buildDiagnosticSummary, buildSupportWebURL, parseEvents, redactMessage } = require('../electron/services/diagnostics');

test('diagnostic parser ignores malformed log lines', () => {
  assert.deepEqual(parseEvents('{"event":"app-start"}\nnot-json\n{"event":"scan-start"}\n'), [
    { event: 'app-start' },
    { event: 'scan-start' },
  ]);
});

test('browser support form carries the same private diagnostic summary', () => {
  const options = {
    logContent: JSON.stringify({ event: 'scan-error', message: 'Failed at C:\\Users\\Jane\\private.heic' }),
    appVersion: '1.0.18',
    platform: 'win32',
    arch: 'x64',
    osRelease: '10.0',
  };
  const summary = buildDiagnosticSummary(options);
  const url = buildSupportWebURL(options);

  assert.match(url, /^https:\/\/foldiq\.app\/contact\.html\?source=foldiq-windows#diagnostic=/);
  assert.equal(decodeURIComponent(url.split('#diagnostic=')[1]), summary);
  assert.doesNotMatch(summary, /Jane|private\.heic/);
  assert.match(summary, /\[local path\]/);
});

test('diagnostic message redaction removes Unix home paths', () => {
  assert.equal(redactMessage('Error /Users/enrique/Photos/private.heic'), 'Error [local path]');
});
