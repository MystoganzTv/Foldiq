const assert = require('node:assert/strict');
const test = require('node:test');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { EventEmitter } = require('events');
const crashReporter = require('../electron/services/crash-reporter');
const { buildDiagnosticSummary } = require('../electron/services/diagnostics');
const telemetry = require('../electron/services/telemetry');

function tempLog() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'foldiq-crash-'));
  return path.join(dir, 'logs', 'crashes.jsonl');
}

test('stack traces lose every local path but keep the file names', () => {
  const stack = [
    'TypeError: Cannot read properties of undefined',
    '    at planFiles (C:\\Users\\maria\\AppData\\Local\\Programs\\Foldiq\\resources\\app.asar\\electron\\services\\planner.js:120:5)',
    '    at /home/maria/foldiq/electron/main.js:40:3',
  ].join('\n');
  const redacted = crashReporter.redactStack(stack);
  assert.equal(redacted.includes('maria'), false);
  assert.equal(redacted.includes('AppData'), false);
  assert.match(redacted, /planner\.js:120:5/);
  assert.match(redacted, /main\.js:40:3/);
});

test('error messages that mention a photo path are redacted', () => {
  const record = crashReporter.buildCrashRecord({
    kind: 'main_uncaught_exception',
    error: new Error('ENOENT: no such file, open \'C:\\Users\\maria\\Pictures\\IMG_0001.jpg\''),
    appVersion: '1.0.22',
  });
  assert.equal(record.message.includes('maria'), false);
  assert.equal(record.message.includes('IMG_0001'), false);
  assert.equal(record.kind, 'main_uncaught_exception');
});

test('the crash log keeps only the most recent entries', () => {
  const logPath = tempLog();
  for (let i = 0; i < crashReporter.MAX_LOG_LINES + 5; i++) {
    crashReporter.appendCrashRecord(logPath, { at: String(i), event: 'crash', kind: 'test' });
  }
  const lines = fs.readFileSync(logPath, 'utf8').trim().split('\n');
  assert.equal(lines.length, crashReporter.MAX_LOG_LINES);
  assert.equal(JSON.parse(lines.at(-1)).at, String(crashReporter.MAX_LOG_LINES + 4));
});

test('install logs main-process, renderer and child-process crashes and pings once per crash', () => {
  const logPath = tempLog();
  const processRef = new EventEmitter();
  const app = new EventEmitter();
  const pings = [];
  const reloaded = [];
  const mainErrors = [];
  crashReporter.install({
    processRef,
    app,
    logPath,
    appVersion: '1.0.22',
    sendAnonymousCrash: uptime => pings.push(uptime),
    onRendererGone: contents => reloaded.push(contents),
    onMainError: record => mainErrors.push(record),
  });

  processRef.emit('uncaughtException', new Error('boom'));
  processRef.emit('unhandledRejection', 'nope');
  app.emit('render-process-gone', {}, 'window-contents', { reason: 'crashed', exitCode: 3 });
  app.emit('render-process-gone', {}, 'window-contents', { reason: 'clean-exit', exitCode: 0 });
  app.emit('child-process-gone', {}, { type: 'Utility', reason: 'oom', exitCode: 1 });

  const kinds = fs.readFileSync(logPath, 'utf8').trim().split('\n').map(line => JSON.parse(line).kind);
  assert.deepEqual(kinds, ['main_uncaught_exception', 'main_unhandled_rejection', 'renderer_gone', 'child_process_gone']);
  assert.equal(pings.length, 4);
  assert.deepEqual(reloaded, ['window-contents']);
  assert.equal(mainErrors.length, 1);
});

test('crash records show up in the diagnostics a customer sends to support', () => {
  const logPath = tempLog();
  crashReporter.appendCrashRecord(logPath, crashReporter.buildCrashRecord({
    kind: 'renderer_gone', details: { reason: 'crashed', exitCode: 5 }, appVersion: '1.0.22',
  }));
  const summary = buildDiagnosticSummary({ logContent: crashReporter.readCrashLog(logPath), appVersion: '1.0.22' });
  assert.match(summary, /crash/);
  assert.match(summary, /kind=renderer_gone/);
  assert.match(summary, /reason=crashed/);
});

test('the anonymous crash ping is opt-in and carries no error details', async () => {
  let called = false;
  assert.equal(await telemetry.sendCrash({ enabled: false, fetchImpl: async () => { called = true; } }), false);
  assert.equal(called, false);

  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'foldiq-crash-ping-'));
  let body;
  const sent = await telemetry.sendCrash({
    enabled: true,
    idPath: path.join(dir, 'id'),
    appVersion: '1.0.22',
    uptimeMs: 45000,
    fetchImpl: async (_url, options) => { body = JSON.parse(options.body); return { ok: true }; },
  });
  assert.equal(sent, true);
  assert.equal(body.eventName, 'app_crashed');
  assert.equal(body.success, false);
  assert.equal(body.durationBucket, '30s_2m');
  assert.equal(body.itemCountBucket, '0');
  assert.deepEqual(Object.keys(body).sort(), ['appVersion', 'durationBucket', 'eventId', 'eventName', 'installId', 'itemCountBucket', 'platform', 'success'].sort());
});
