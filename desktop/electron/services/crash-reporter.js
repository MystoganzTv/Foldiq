const fs = require('fs');
const path = require('path');
const { redactMessage } = require('./diagnostics');

// Crash reporting for the Windows app.
//
// Every crash is written to a local log (logs/crashes.jsonl) with the error and a
// path-free stack, so it reaches the owner through the existing "Send diagnostics"
// support flow. If — and only if — the user opted in to anonymous usage data, a
// single anonymous `app_crashed` event is also sent so crashes show up in the
// owner dashboard. No file names, folder paths or photo data ever leave the device.

const MAX_LOG_LINES = 50;
const MAX_STACK_LINES = 12;

function redactStack(stack) {
  return String(stack ?? '')
    .split(/\r?\n/)
    .slice(0, MAX_STACK_LINES)
    .map(line => line
      // Windows and POSIX absolute paths, keeping only the file name for context.
      .replace(/(?:[A-Za-z]:)?[\\/](?:[^\\/\s():]+[\\/])+([^\\/\s():]+)/g, '…/$1')
      .trim()
      .slice(0, 200))
    .filter(Boolean)
    .join(' | ');
}

function describeError(error) {
  if (error instanceof Error) {
    return { message: redactMessage(`${error.name}: ${error.message}`), stack: redactStack(error.stack) };
  }
  return { message: redactMessage(typeof error === 'string' ? error : JSON.stringify(error ?? null)), stack: '' };
}

function buildCrashRecord({ kind, error, details = {}, appVersion, now = new Date() }) {
  const record = { at: now.toISOString(), event: 'crash', kind: String(kind), appVersion: String(appVersion || 'unknown') };
  if (error !== undefined) Object.assign(record, describeError(error));
  for (const [key, value] of Object.entries(details)) {
    if (['reason', 'exitCode', 'type', 'name'].includes(key) && value !== undefined) {
      record[key] = redactMessage(String(value)).slice(0, 80);
    }
  }
  return record;
}

// Appends one crash and keeps only the most recent MAX_LOG_LINES entries.
function appendCrashRecord(logPath, record) {
  try {
    fs.mkdirSync(path.dirname(logPath), { recursive: true });
    let lines = [];
    try { lines = fs.readFileSync(logPath, 'utf8').split(/\r?\n/).filter(Boolean); } catch {}
    lines.push(JSON.stringify(record));
    fs.writeFileSync(logPath, `${lines.slice(-MAX_LOG_LINES).join('\n')}\n`, 'utf8');
    return true;
  } catch {
    return false;
  }
}

function readCrashLog(logPath) {
  try { return fs.readFileSync(logPath, 'utf8'); } catch { return ''; }
}

// Wires the process- and window-level crash hooks.
//   app, telemetry: injected so the module can be tested without Electron.
//   onRendererGone(webContents): called after a window's renderer died, to recover.
function install({ processRef = process, app, logPath, appVersion, sendAnonymousCrash, onRendererGone, onMainError }) {
  const startedAt = Date.now();

  function report(kind, error, details) {
    const record = buildCrashRecord({ kind, error, details, appVersion });
    appendCrashRecord(logPath, record);
    try { void sendAnonymousCrash?.(Date.now() - startedAt); } catch {}
    return record;
  }

  processRef.on('uncaughtException', error => {
    const record = report('main_uncaught_exception', error);
    try { onMainError?.(record); } catch {}
  });

  processRef.on('unhandledRejection', reason => {
    report('main_unhandled_rejection', reason);
  });

  app?.on?.('render-process-gone', (_event, webContents, details = {}) => {
    // A clean exit is not a crash (e.g. the window was closed).
    if (details.reason === 'clean-exit') return;
    report('renderer_gone', undefined, { reason: details.reason, exitCode: details.exitCode });
    try { onRendererGone?.(webContents, details); } catch {}
  });

  app?.on?.('child-process-gone', (_event, details = {}) => {
    if (details.reason === 'clean-exit') return;
    report('child_process_gone', undefined, {
      reason: details.reason, exitCode: details.exitCode, type: details.type, name: details.name,
    });
  });

  return { report };
}

module.exports = {
  appendCrashRecord,
  buildCrashRecord,
  install,
  readCrashLog,
  redactStack,
  MAX_LOG_LINES,
};
