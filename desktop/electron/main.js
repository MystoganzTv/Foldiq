const { app, BrowserWindow, ipcMain, dialog, shell, nativeImage, clipboard, Notification } = require('electron');
const path = require('path');
const isDev = process.env.NODE_ENV === 'development' || !app.isPackaged;

const scanner  = require('./services/scanner');
const planner  = require('./services/planner');
const mover    = require('./services/mover');
const { rowsToCSV } = require('./services/csv');
const { filterSupportedSources } = require('./services/sources');
const { buildDiagnosticSummary, buildSupportWebURL } = require('./services/diagnostics');
const geocoder = require('./services/geocoder');
const preferences = require('./services/preferences');
const rating = require('./services/rating');
const telemetry = require('./services/telemetry');
const watcher = require('./services/watcher');
const crashReporter = require('./services/crash-reporter');

let mainWindow;
let activeManifestPaths = [];
let activeOutputFolder = null;
let activeScanController = null;
let allowedPreviewPaths = new Set();
let allowedSourceRoots = [];
const thumbnailCache = new Map();
let manualOperations = 0;
let folderWatcher = null;
let lastWatchEvent = null;

async function trackManualOperation(work) {
  manualOperations++;
  try { return await work(); } finally { manualOperations--; }
}

function undoDirectory() {
  return path.join(app.getPath('userData'), 'undo');
}

function ratingStatePath() {
  return path.join(app.getPath('userData'), 'rating.json');
}

function diagnosticsPath() {
  return path.join(app.getPath('userData'), 'logs', 'scan-diagnostics.jsonl');
}

function preferencesPath() {
  return path.join(app.getPath('userData'), 'settings.json');
}

function locationCachePath() {
  return path.join(app.getPath('userData'), 'location-cache.json');
}

function watchStatePath() {
  return path.join(app.getPath('userData'), 'auto-organize.json');
}

function telemetryIdPath() {
  return path.join(app.getPath('userData'), 'anonymous-install-id');
}

function crashLogPath() {
  return path.join(app.getPath('userData'), 'logs', 'crashes.jsonl');
}

function readDiagnosticLogs() {
  let logContent = '';
  try { logContent = require('fs').readFileSync(diagnosticsPath(), 'utf8'); } catch {}
  const crashes = crashReporter.readCrashLog(crashLogPath());
  return crashes ? `${logContent}\n${crashes}` : logContent;
}

let rendererReloads = [];

// Installed before anything else can throw, so even a crash during startup is logged.
crashReporter.install({
  app,
  logPath: crashLogPath(),
  appVersion: app.getVersion(),
  sendAnonymousCrash: uptimeMs => {
    let enabled = false;
    try { enabled = preferences.readPreferences(preferencesPath()).shareAnonymousUsageData; } catch {}
    return telemetry.sendCrash({ enabled, idPath: telemetryIdPath(), appVersion: app.getVersion(), uptimeMs });
  },
  onRendererGone: webContents => {
    // The window went blank: reload it instead of leaving the user on an empty screen.
    // At most 3 reloads a minute, so a page that crashes on load can't loop forever.
    const now = Date.now();
    rendererReloads = rendererReloads.filter(at => now - at < 60000);
    if (rendererReloads.length >= 3) return;
    rendererReloads.push(now);
    if (mainWindow && !mainWindow.isDestroyed() && webContents === mainWindow.webContents) {
      if (isDev) mainWindow.loadURL('http://localhost:5173');
      else mainWindow.loadFile(path.join(__dirname, '../dist/index.html'));
      offerCrashDiagnostics();
    }
  },
  // Same behaviour as Electron's default handler (the app keeps running), but with
  // a message a customer can act on instead of a raw stack trace.
  onMainError: () => offerCrashDiagnostics(),
});

let crashPromptOpen = false;

// Tells the user something went wrong and offers to open the support form with the
// (path-free) diagnostics filled in. Nothing is sent unless they submit that form.
function offerCrashDiagnostics() {
  if (crashPromptOpen || !app.isReady()) return;
  crashPromptOpen = true;
  const window = mainWindow && !mainWindow.isDestroyed() ? mainWindow : undefined;
  const options = {
    type: 'warning',
    title: 'Foldiq',
    message: 'Foldiq ran into a problem',
    detail: 'Something went wrong inside Foldiq.\n\n'
      + 'You can send a diagnostic report so we can fix it. It contains no photos, file names or folder paths.',
    buttons: ['Send diagnostics', 'Close'],
    defaultId: 0,
    cancelId: 1,
  };
  const shown = window ? dialog.showMessageBox(window, options) : dialog.showMessageBox(options);
  shown
    .then(async ({ response }) => {
      if (response !== 0) return;
      const logContent = readDiagnosticLogs();
      await shell.openExternal(buildSupportWebURL({ logContent, appVersion: app.getVersion() }));
    })
    .catch(() => {})
    .finally(() => { crashPromptOpen = false; });
}

function recordAnonymousOperation(eventName, startedAt, itemCount, success) {
  const enabled = preferences.readPreferences(preferencesPath()).shareAnonymousUsageData;
  void telemetry.send({
    enabled,
    idPath: telemetryIdPath(),
    appVersion: app.getVersion(),
    eventName,
    success,
    elapsedMs: Date.now() - startedAt,
    itemCount,
  });
}

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1100,
    height: 740,
    minWidth: 860,
    minHeight: 600,
    titleBarStyle: process.platform === 'darwin' ? 'hiddenInset' : 'default',
    backgroundColor: '#F8FAFC',
    icon: path.join(__dirname, '../assets/icon.png'),
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });

  if (isDev) {
    mainWindow.loadURL('http://localhost:5173');
    mainWindow.webContents.openDevTools();
  } else {
    mainWindow.loadFile(path.join(__dirname, '../dist/index.html'));
  }
}

app.whenReady().then(() => {
  if (process.platform === 'win32') app.setAppUserModelId('app.foldiq.desktop');
  scanner.configureDiagnostics(diagnosticsPath());
  createWindow();
  const watchState = watcher.readState(watchStatePath());
  if (watchState.enabled) startFolderWatcher(watchState.folder);
});
app.on('window-all-closed', () => { if (process.platform !== 'darwin') app.quit(); });
app.on('activate', () => { if (BrowserWindow.getAllWindows().length === 0) createWindow(); });
app.on('before-quit', () => {
  folderWatcher?.stop();
  scanner.end();
});

// ── Auto-organize ────────────────────────────────────────────────────────────

async function organizeWatchedFiles(filePaths, config) {
  const scanResult = await scanner.scan(filePaths, () => {}, {
    includeVideos: config.includeVideos !== false,
    includeArchives: false,
    keepTempDirs: true,
  });
  if (scanResult.files.length === 0) return { moved: 0, errors: [], manifestPath: null };
  const useLocations = config.useGPSLocation === true && ['smart', 'location'].includes(config.organizationMode);
  const located = await geocoder.enrichFiles(scanResult.files, {
    enabled: useLocations,
    cachePath: locationCachePath(),
    appVersion: app.getVersion(),
  });
  const plan = planner.buildPlan(located.files, config);
  return mover.apply(plan, { ...config, manifestDirectory: undoDirectory() }, () => {});
}

function sendWatchEvent(event) {
  lastWatchEvent = { ...event, at: event.at ?? Date.now() };
  mainWindow?.webContents.send('watch:event', lastWatchEvent);
  if (event.type === 'organized' && event.organized > 0 && Notification.isSupported()) {
    const notification = new Notification({
      title: `Foldiq organized ${event.organized.toLocaleString()} new file${event.organized === 1 ? '' : 's'}`,
      body: event.errors > 0
        ? `${event.errors} file${event.errors === 1 ? '' : 's'} could not be organized. Open Foldiq for details.`
        : 'Open Foldiq to see them or undo.',
    });
    notification.on('click', () => { mainWindow?.show(); mainWindow?.focus(); });
    notification.show();
  }
}

function startFolderWatcher(folder) {
  folderWatcher?.stop();
  folderWatcher = null;
  const problem = watcher.validateWatch({
    folder,
    outputFolder: preferences.readPreferences(preferencesPath()).outputFolder,
  });
  if (problem) {
    sendWatchEvent({ type: 'error', message: problem });
    return problem;
  }
  folderWatcher = new watcher.FolderWatcher({
    folder,
    statePath: watchStatePath(),
    getConfig: () => preferences.readPreferences(preferencesPath()),
    organize: organizeWatchedFiles,
    isBusy: () => manualOperations > 0 || activeScanController != null,
    onEvent: sendWatchEvent,
    discardManifest: manifestPath => mover.discardManifest(manifestPath, undoDirectory()),
  });
  try {
    folderWatcher.start();
  } catch (error) {
    folderWatcher = null;
    sendWatchEvent({ type: 'error', message: error.message });
    return error.message;
  }
  return null;
}

function publicWatchState() {
  const state = watcher.readState(watchStatePath());
  return {
    enabled: state.enabled,
    folder: state.folder,
    active: folderWatcher != null,
    history: state.history.slice(0, 5),
    lastEvent: lastWatchEvent,
  };
}

function assertString(value, label) {
  if (typeof value !== 'string' || value.length === 0 || value.includes('\0')) {
    throw new Error(`Invalid ${label}`);
  }
  return value;
}

function assertArray(value, label, maxLength = 100000) {
  if (!Array.isArray(value) || value.length > maxLength) {
    throw new Error(`Invalid ${label}`);
  }
  return value;
}

// ── IPC Handlers ──────────────────────────────────────────────────────────────

// Pick folder(s) via dialog
ipcMain.handle('dialog:selectFolders', async () => {
  const result = await dialog.showOpenDialog(mainWindow, {
    properties: ['openDirectory', 'multiSelections'],
    title: 'Select folders to organize',
  });
  return result.canceled ? [] : result.filePaths;
});

// Pick archive(s) directly. Windows cannot combine file and directory
// selection in one native dialog, so folders and archives use separate pickers.
ipcMain.handle('dialog:selectArchives', async () => {
  const result = await dialog.showOpenDialog(mainWindow, {
    properties: ['openFile', 'multiSelections'],
    title: 'Select ZIP, RAR, or 7z archives to organize',
    filters: [{ name: 'Compressed archives', extensions: ['zip', 'rar', '7z'] }],
  });
  return result.canceled ? [] : filterSupportedSources(result.filePaths);
});

ipcMain.handle('sources:filterSupported', async (event, { sourcePaths }) => {
  assertArray(sourcePaths, 'source paths', 100).forEach(sourcePath => assertString(sourcePath, 'source path'));
  return filterSupportedSources(sourcePaths);
});

ipcMain.handle('app:info', async () => ({
  version: app.getVersion(),
  platform: process.platform,
}));

ipcMain.handle('preferences:get', async () => preferences.readPreferences(preferencesPath()));

ipcMain.handle('preferences:save', async (event, { value }) => {
  if (!value || typeof value !== 'object') throw new Error('Invalid preferences');
  return preferences.writePreferences(preferencesPath(), value);
});

// Pick output folder
ipcMain.handle('dialog:selectOutput', async () => {
  const result = await dialog.showOpenDialog(mainWindow, {
    properties: ['openDirectory'],
    title: 'Select output folder',
  });
  return result.canceled ? null : result.filePaths[0];
});

ipcMain.handle('watch:get', async () => publicWatchState());

ipcMain.handle('watch:chooseFolder', async () => {
  const result = await dialog.showOpenDialog(mainWindow, {
    properties: ['openDirectory'],
    title: 'Choose a folder to auto-organize',
  });
  return result.canceled ? null : result.filePaths[0];
});

ipcMain.handle('watch:configure', async (event, { enabled, folder }) => {
  const current = watcher.readState(watchStatePath());
  const nextFolder = typeof folder === 'string' && folder ? path.resolve(assertString(folder, 'watched folder')) : current.folder;
  if (enabled === true) {
    const problem = watcher.validateWatch({
      folder: nextFolder,
      outputFolder: preferences.readPreferences(preferencesPath()).outputFolder,
    });
    if (problem) return { ...publicWatchState(), error: problem };
    const restarting = !current.enabled || current.folder !== nextFolder;
    watcher.writeState(watchStatePath(), {
      ...current,
      enabled: true,
      folder: nextFolder,
      // Only files that arrive from now on are organized automatically.
      enabledAt: restarting ? Date.now() : current.enabledAt,
      ledger: current.folder === nextFolder ? current.ledger : [],
    });
    const startProblem = startFolderWatcher(nextFolder);
    if (startProblem) return { ...publicWatchState(), error: startProblem };
  } else {
    folderWatcher?.stop();
    folderWatcher = null;
    watcher.writeState(watchStatePath(), { ...current, enabled: false, folder: nextFolder });
  }
  return publicWatchState();
});

ipcMain.handle('watch:undo', async (event, { manifestPath }) => {
  assertString(manifestPath, 'manifest path');
  const state = watcher.readState(watchStatePath());
  if (!state.history.some(item => item.manifestPath === manifestPath)) {
    throw new Error('That auto-organize run is no longer available to undo');
  }
  const result = await trackManualOperation(() => mover.undo(manifestPath, undoDirectory()));
  if (result.errors.length === 0) {
    state.history = state.history.map(item => (
      item.manifestPath === manifestPath ? { ...item, undone: true } : item
    ));
    watcher.writeState(watchStatePath(), state);
  }
  return { restored: result.restored, errors: result.errors, state: publicWatchState() };
});

// Scan folders — streams progress via webContents.send
ipcMain.handle('scan:start', async (event, { folders, options = {} }) => {
  const startedAt = Date.now();
  assertArray(folders, 'folders', 100).forEach(folder => assertString(folder, 'folder'));
  activeScanController?.abort();
  const controller = new AbortController();
  activeScanController = controller;
  const onProgress = (p) => mainWindow.webContents.send('scan:progress', p);
  try {
    const result = await scanner.scan(folders, onProgress, {
      signal: controller.signal,
      includeVideos: options.includeVideos !== false,
      includeArchives: options.includeArchives !== false,
    });
    allowedSourceRoots = folders.map(folder => path.resolve(folder));
    allowedPreviewPaths = new Set(result.files.flatMap(file => (
      [file.path, file.archiveSourcePath].filter(Boolean).map(filePath => path.resolve(filePath))
    )));
    thumbnailCache.clear();
    recordAnonymousOperation('scan_completed', startedAt, result.files.length, true);
    return result;
  } catch (error) {
    if (error?.name !== 'AbortError') recordAnonymousOperation('scan_completed', startedAt, 0, false);
    throw error;
  } finally {
    if (activeScanController === controller) activeScanController = null;
  }
});

ipcMain.handle('scan:cancel', async () => {
  activeScanController?.abort();
  return true;
});

// Generate previews in the trusted main process. Renderer requests are limited
// to files returned by the current scan so this cannot become an arbitrary local
// file-reading bridge if renderer content is ever compromised.
ipcMain.handle('preview:thumbnail', async (event, { filePath }) => {
  const resolvedPath = path.resolve(assertString(filePath, 'preview file path'));
  if (!allowedPreviewPaths.has(resolvedPath)) throw new Error('Preview file is not part of the current scan');
  if (thumbnailCache.has(resolvedPath)) return thumbnailCache.get(resolvedPath);

  try {
    const image = await nativeImage.createThumbnailFromPath(resolvedPath, { width: 640, height: 420 });
    const dataURL = image.isEmpty() ? null : image.toDataURL();
    if (thumbnailCache.size >= 40) thumbnailCache.delete(thumbnailCache.keys().next().value);
    thumbnailCache.set(resolvedPath, dataURL);
    return dataURL;
  } catch {
    thumbnailCache.set(resolvedPath, null);
    return null;
  }
});

// Build organization plan
ipcMain.handle('plan:build', async (event, { files, config }) => {
  assertArray(files, 'files');
  if (!config || typeof config !== 'object') throw new Error('Invalid plan configuration');
  assertString(config.outputFolder, 'output folder');
  const useLocations = config.useGPSLocation === true && ['smart', 'location'].includes(config.organizationMode);
  const locationResult = await geocoder.enrichFiles(files, {
    enabled: useLocations,
    cachePath: locationCachePath(),
    appVersion: app.getVersion(),
    onProgress: progress => mainWindow.webContents.send('plan:progress', progress),
  });
  if (locationResult.warnings.length > 0) {
    mainWindow.webContents.send('plan:progress', {
      phase: 'locations',
      warning: 'Some GPS locations could not be named. Those files will use the normal date structure or Unknown Location.',
    });
  }
  return planner.buildPlan(locationResult.files, config);
});

// Apply plan — streams progress
ipcMain.handle('apply:start', async (event, { plan, config }) => {
  const startedAt = Date.now();
  assertArray(plan, 'plan');
  if (!config || typeof config !== 'object') throw new Error('Invalid apply configuration');
  assertString(config.outputFolder, 'output folder');
  const onProgress = (p) => mainWindow.webContents.send('apply:progress', p);
  try {
    const result = await trackManualOperation(() => mover.apply(plan, {
      ...config,
      manifestDirectory: undoDirectory(),
    }, onProgress));
    activeManifestPaths = result.manifestPaths;
    activeOutputFolder = path.resolve(config.outputFolder);
    if (result.errors.length === 0) await scanner.cleanupTempDirs();
    recordAnonymousOperation('apply_completed', startedAt, plan.length, result.errors.length === 0);
    return result;
  } catch (error) {
    recordAnonymousOperation('apply_completed', startedAt, plan.length, false);
    throw error;
  }
});

ipcMain.handle('apply:retry', async (event, { plan, config }) => {
  assertArray(plan, 'retry plan');
  if (!config || typeof config !== 'object') throw new Error('Invalid retry configuration');
  assertString(config.outputFolder, 'output folder');
  const onProgress = progress => mainWindow.webContents.send('apply:progress', progress);
  const result = await trackManualOperation(() => mover.apply(plan, {
    ...config,
    manifestDirectory: undoDirectory(),
  }, onProgress));
  activeManifestPaths.push(...result.manifestPaths);
  return result;
});

// Undo last operation
ipcMain.handle('apply:undo', async (event, { manifestPath }) => {
  const startedAt = Date.now();
  assertString(manifestPath, 'manifest path');
  const result = await trackManualOperation(() => mover.undo(manifestPath, undoDirectory(), progress => {
    mainWindow.webContents.send('undo:progress', progress);
  }));
  if (!result.manifestPath) activeManifestPaths = activeManifestPaths.filter(item => item !== manifestPath);
  recordAnonymousOperation('undo_completed', startedAt, result.restored, result.errors.length === 0);
  return result;
});

ipcMain.handle('apply:undoMany', async (event, { manifestPaths }) => {
  const startedAt = Date.now();
  assertArray(manifestPaths, 'manifest paths', 100).forEach(item => assertString(item, 'manifest path'));
  let restored = 0;
  const errors = [];
  const remaining = [...manifestPaths];
  for (const manifestPath of [...manifestPaths].reverse()) {
    const result = await trackManualOperation(() => mover.undo(manifestPath, undoDirectory(), progress => {
      mainWindow.webContents.send('undo:progress', progress);
    }));
    restored += result.restored;
    if (result.errors.length > 0) {
      errors.push(...result.errors);
      break;
    }
    remaining.splice(remaining.indexOf(manifestPath), 1);
    activeManifestPaths = activeManifestPaths.filter(item => item !== manifestPath);
  }
  recordAnonymousOperation('undo_completed', startedAt, restored, errors.length === 0);
  return { restored, errors, manifestPaths: remaining };
});

ipcMain.handle('recovery:listUndo', async () => {
  const manifests = await mover.listManifests(undoDirectory());
  activeManifestPaths = manifests.map(item => item.path);
  return manifests;
});

ipcMain.handle('apply:discardUndo', async (event, { manifestPath }) => {
  assertString(manifestPath, 'manifest path');
  mover.discardManifest(manifestPath, undoDirectory());
  activeManifestPaths = activeManifestPaths.filter(item => item !== manifestPath);
  return true;
});

ipcMain.handle('apply:discardUndoMany', async (event, { manifestPaths }) => {
  assertArray(manifestPaths, 'manifest paths', 100).forEach(item => {
    assertString(item, 'manifest path');
    mover.discardManifest(item, undoDirectory());
  });
  activeManifestPaths = activeManifestPaths.filter(item => !manifestPaths.includes(item));
  return true;
});

ipcMain.handle('cleanup:countEmpty', async () => (
  (await mover.findEmptyFolders(allowedSourceRoots, [activeOutputFolder].filter(Boolean))).length
));

ipcMain.handle('cleanup:removeEmpty', async () => (
  mover.removeEmptyFolders(allowedSourceRoots, [activeOutputFolder].filter(Boolean))
));

// Open folder in Explorer/Finder
ipcMain.handle('shell:openFolder', async (event, { folderPath }) => {
  assertString(folderPath, 'folder path');
  await shell.openPath(folderPath);
});

ipcMain.handle('shell:revealFile', async (event, { filePath }) => {
  const resolvedPath = path.resolve(assertString(filePath, 'file path'));
  if (!allowedPreviewPaths.has(resolvedPath)) throw new Error('File is not part of the current scan');
  shell.showItemInFolder(resolvedPath);
});

ipcMain.handle('shell:openAttribution', async () => {
  await shell.openExternal('https://www.openstreetmap.org/copyright');
  return true;
});

// Review invitation. Windows has no store listing to deep-link into, so the
// ask lands on the contact form in review mode.
ipcMain.handle('rating:recordSuccess', async (event, { itemCount } = {}) => {
  const updated = rating.recordSuccessfulOrganization(rating.readRatingState(ratingStatePath()), itemCount);
  rating.writeRatingState(ratingStatePath(), updated);
  return rating.shouldShowInvite(updated);
});

ipcMain.handle('rating:dismissInvite', async () => {
  const current = rating.readRatingState(ratingStatePath());
  rating.writeRatingState(ratingStatePath(), { ...current, dismissedAt: Date.now() });
  return true;
});

ipcMain.handle('rating:openReviewForm', async () => {
  const current = rating.readRatingState(ratingStatePath());
  rating.writeRatingState(ratingStatePath(), { ...current, reviewOpened: true });
  await shell.openExternal(rating.REVIEW_URL);
  return true;
});

ipcMain.handle('support:openDiagnosticsForm', async () => {
  const logContent = readDiagnosticLogs();
  const options = { logContent, appVersion: app.getVersion() };
  clipboard.writeText(buildDiagnosticSummary(options));
  await shell.openExternal(buildSupportWebURL(options));
  return true;
});

ipcMain.handle('support:copyDiagnostics', async () => {
  const logContent = readDiagnosticLogs();
  clipboard.writeText(buildDiagnosticSummary({ logContent, appVersion: app.getVersion() }));
  return true;
});

// Export CSV report
ipcMain.handle('report:exportCSV', async (event, { rows }) => {
  assertArray(rows, 'report rows');
  const result = await dialog.showSaveDialog(mainWindow, {
    title: 'Save Report',
    defaultPath: `Foldiq-Report-${Date.now()}.csv`,
    filters: [{ name: 'CSV', extensions: ['csv'] }],
  });
  if (result.canceled) return null;
  const fs = require('fs');
  const csv = rowsToCSV(rows);
  fs.writeFileSync(result.filePath, csv, 'utf-8');
  return result.filePath;
});
