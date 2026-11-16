// watcher.js — "Auto-organize new files": watches one folder while Foldiq is
// open and organizes photos and videos that arrive in it, using the same scan,
// plan and apply steps (and the same Undo manifests) as a manual run.
//
// Safety rules:
//   • Only files that appear after the watch was turned on are touched.
//   • A file is processed only after two looks, one settle period apart, see
//     the same size and modification time, so a copy in progress is never
//     moved half-written (cameras and Explorer keep the photo's old mtime, so
//     the age of the file alone proves nothing).
//   • Nothing inside the output folder is ever picked up again.
//   • Every run writes a normal Undo manifest.

const fs = require('fs');
const path = require('path');

const MEDIA_EXTENSIONS = new Set([
  '.jpg', '.jpeg', '.png', '.heic', '.heif', '.tiff', '.tif', '.webp',
  '.cr2', '.cr3', '.nef', '.arw', '.dng', '.raf', '.orf', '.rw2',
  '.mov', '.mp4', '.m4v', '.avi', '.mkv',
]);
const VIDEO_EXTENSIONS = new Set(['.mov', '.mp4', '.m4v', '.avi', '.mkv']);
const DEFAULT_SETTLE_MS = 15_000;
const MAX_LEDGER_ENTRIES = 20_000;
const MAX_HISTORY = 20;

function isPathInside(directory, candidate) {
  const relative = path.relative(path.resolve(directory), path.resolve(candidate));
  return relative === '' || (!relative.startsWith('..') && !path.isAbsolute(relative));
}

function defaultState() {
  return { enabled: false, folder: '', enabledAt: null, ledger: [], history: [] };
}

function readState(filePath) {
  try {
    const value = JSON.parse(fs.readFileSync(filePath, 'utf8'));
    return {
      enabled: value.enabled === true,
      folder: typeof value.folder === 'string' && !value.folder.includes('\0') ? value.folder : '',
      enabledAt: Number.isFinite(value.enabledAt) ? value.enabledAt : null,
      ledger: Array.isArray(value.ledger) ? value.ledger.filter(item => typeof item === 'string').slice(-MAX_LEDGER_ENTRIES) : [],
      history: Array.isArray(value.history) ? value.history.slice(0, MAX_HISTORY) : [],
    };
  } catch {
    return defaultState();
  }
}

function writeState(filePath, state) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  const tempPath = `${filePath}.${process.pid}.tmp`;
  fs.writeFileSync(tempPath, JSON.stringify({
    ...state,
    ledger: state.ledger.slice(-MAX_LEDGER_ENTRIES),
    history: state.history.slice(0, MAX_HISTORY),
  }, null, 2), 'utf8');
  fs.renameSync(tempPath, filePath);
  return state;
}

/** Reasons a watch cannot start, or null when the folders are usable. */
function validateWatch({ folder, outputFolder }) {
  if (!folder) return 'Choose a folder to watch.';
  if (!outputFolder) return 'Choose an output folder in Organization Settings first.';
  if (isPathInside(outputFolder, folder)) return 'The watched folder cannot be inside the output folder.';
  try {
    if (!fs.statSync(folder).isDirectory()) return 'The watched folder no longer exists.';
  } catch {
    return 'The watched folder no longer exists.';
  }
  return null;
}

function ledgerKey(filePath, stat) {
  return `${path.resolve(filePath).toLowerCase()}|${stat.size}|${Math.round(stat.mtimeMs)}`;
}

class FolderWatcher {
  /**
   * @param {object} options
   * @param {string} options.folder           folder to watch
   * @param {() => object} options.getConfig  current organization settings (outputFolder, mode…)
   * @param {string} options.statePath        where enabledAt, the ledger and history live
   * @param {(files: string[], config: object) => Promise<object>} options.organize
   *        runs scan → plan → apply for the given paths and returns the apply result
   * @param {() => boolean} [options.isBusy]  true while a manual scan or apply runs
   * @param {(event: object) => void} [options.onEvent]
   */
  constructor({
    folder,
    getConfig,
    statePath,
    organize,
    isBusy = () => false,
    onEvent = () => {},
    discardManifest = () => {},
    settleMs = DEFAULT_SETTLE_MS,
    watchFactory = (target, listener) => fs.watch(target, { recursive: true }, listener),
    now = () => Date.now(),
  }) {
    this.folder = path.resolve(folder);
    this.getConfig = getConfig;
    this.statePath = statePath;
    this.organize = organize;
    this.isBusy = isBusy;
    this.onEvent = onEvent;
    this.discardManifest = discardManifest;
    this.settleMs = settleMs;
    this.watchFactory = watchFactory;
    this.now = now;
    this.observed = new Map();
    this.pending = new Set();
    this.timer = null;
    this.running = false;
    this.rerun = false;
    this.handle = null;
    this.stopped = true;
  }

  start() {
    this.stopped = false;
    const state = readState(this.statePath);
    this.enabledAt = state.enabledAt ?? this.now();
    this.handle = this.watchFactory(this.folder, (eventType, filename) => {
      if (!filename) return;
      this.notice(path.join(this.folder, filename.toString()));
    });
    this.handle?.on?.('error', error => this.onEvent({ type: 'error', message: error.message }));
    // Catch files that arrived while Foldiq was closed.
    this.sweep().catch(() => {});
  }

  stop() {
    this.stopped = true;
    clearTimeout(this.timer);
    this.timer = null;
    try { this.handle?.close?.(); } catch {}
    this.handle = null;
    this.pending.clear();
    this.observed.clear();
  }

  isCandidate(filePath) {
    const extension = path.extname(filePath).toLowerCase();
    if (!MEDIA_EXTENSIONS.has(extension)) return false;
    const config = this.getConfig() || {};
    if (config.includeVideos === false && VIDEO_EXTENSIONS.has(extension)) return false;
    if (config.outputFolder && isPathInside(config.outputFolder, filePath)) return false;
    return isPathInside(this.folder, filePath);
  }

  notice(filePath) {
    if (this.stopped || !this.isCandidate(filePath)) return;
    this.pending.add(path.resolve(filePath));
    this.schedule();
  }

  schedule(delay = this.settleMs) {
    if (this.stopped) return;
    clearTimeout(this.timer);
    this.timer = setTimeout(() => { this.flush().catch(() => {}); }, delay);
    this.timer.unref?.();
  }

  async sweep() {
    const pending = [this.folder];
    while (pending.length > 0) {
      const directory = pending.pop();
      let entries = [];
      try { entries = await fs.promises.readdir(directory, { withFileTypes: true }); } catch { continue; }
      for (const entry of entries) {
        const full = path.join(directory, entry.name);
        const config = this.getConfig() || {};
        if (entry.isDirectory()) {
          if (!config.outputFolder || !isPathInside(config.outputFolder, full)) pending.push(full);
        } else if (entry.isFile() && this.isCandidate(full)) {
          try {
            const stat = await fs.promises.stat(full);
            if (stat.mtimeMs >= this.enabledAt || stat.birthtimeMs >= this.enabledAt) this.pending.add(full);
          } catch {}
        }
      }
    }
    if (this.pending.size > 0) this.schedule();
  }

  /** Splits pending files into those ready now and those still being written. */
  async settledFiles(now = this.now()) {
    const ledger = new Set(readState(this.statePath).ledger);
    const ready = [];
    const waiting = [];
    for (const filePath of this.pending) {
      let stat;
      try { stat = await fs.promises.stat(filePath); } catch { this.observed.delete(filePath); continue; }
      if (!stat.isFile() || ledger.has(ledgerKey(filePath, stat))) {
        this.observed.delete(filePath);
        continue;
      }
      const previous = this.observed.get(filePath);
      const same = previous && previous.size === stat.size && previous.mtimeMs === stat.mtimeMs;
      const unchanged = same && now - previous.at >= this.settleMs / 2;
      if (stat.size === 0 || !unchanged) {
        if (!same) this.observed.set(filePath, { size: stat.size, mtimeMs: stat.mtimeMs, at: now });
        waiting.push(filePath);
        continue;
      }
      this.observed.delete(filePath);
      ready.push({ filePath, key: ledgerKey(filePath, stat) });
    }
    return { ready, waiting };
  }

  async flush() {
    if (this.stopped) return null;
    if (this.running || this.isBusy()) {
      this.rerun = true;
      this.schedule(Math.max(this.settleMs, 5_000));
      return null;
    }
    this.running = true;
    try {
      const { ready, waiting } = await this.settledFiles();
      this.pending = new Set(waiting);
      if (waiting.length > 0) this.schedule();
      if (ready.length === 0) return null;

      const config = this.getConfig() || {};
      const problem = validateWatch({ folder: this.folder, outputFolder: config.outputFolder });
      if (problem) {
        this.onEvent({ type: 'error', message: problem });
        return null;
      }

      this.onEvent({ type: 'running', files: ready.length });
      const result = await this.organize(ready.map(item => item.filePath), config);
      const state = readState(this.statePath);
      state.ledger.push(...ready.map(item => item.key));
      const entry = {
        at: Date.now(),
        organized: result?.moved ?? 0,
        errors: result?.errors?.length ?? 0,
        manifestPath: result?.manifestPath ?? null,
      };
      state.history.unshift(entry);
      // Runs that fall off the history can no longer be undone from the app,
      // so their manifests are removed instead of piling up.
      for (const dropped of state.history.slice(MAX_HISTORY)) {
        if (dropped?.manifestPath) {
          try { this.discardManifest(dropped.manifestPath); } catch {}
        }
      }
      state.history = state.history.slice(0, MAX_HISTORY);
      writeState(this.statePath, state);
      this.onEvent({ type: 'organized', ...entry });
      return entry;
    } catch (error) {
      this.onEvent({ type: 'error', message: error?.message || 'Auto-organize could not finish.' });
      return null;
    } finally {
      this.running = false;
      if (this.rerun && !this.stopped) {
        this.rerun = false;
        if (this.pending.size > 0) this.schedule();
      }
    }
  }
}

module.exports = {
  FolderWatcher,
  readState,
  writeState,
  defaultState,
  validateWatch,
  ledgerKey,
  isPathInside,
  MAX_HISTORY,
};
