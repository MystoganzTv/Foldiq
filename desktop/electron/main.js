const { app, BrowserWindow, ipcMain, dialog, shell, nativeImage, clipboard } = require('electron');
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

let mainWindow;
let activeManifestPaths = [];
let activeOutputFolder = null;
let activeScanController = null;
let allowedPreviewPaths = new Set();
let allowedSourceRoots = [];
const thumbnailCache = new Map();

function undoDirectory() {
  return path.join(app.getPath('userData'), 'undo');
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
  // Undo is session-only. Clear leftovers from interrupted/previous sessions.
  mover.cleanupManifests(undoDirectory());
  scanner.configureDiagnostics(diagnosticsPath());
  createWindow();
});
app.on('window-all-closed', () => { if (process.platform !== 'darwin') app.quit(); });
app.on('activate', () => { if (BrowserWindow.getAllWindows().length === 0) createWindow(); });
app.on('before-quit', () => {
  scanner.end();
  mover.cleanupManifests(undoDirectory());
});

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

// Scan folders — streams progress via webContents.send
ipcMain.handle('scan:start', async (event, { folders, options = {} }) => {
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
    return result;
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
  assertArray(plan, 'plan');
  if (!config || typeof config !== 'object') throw new Error('Invalid apply configuration');
  assertString(config.outputFolder, 'output folder');
  const onProgress = (p) => mainWindow.webContents.send('apply:progress', p);
  const result = await mover.apply(plan, {
    ...config,
    manifestDirectory: undoDirectory(),
  }, onProgress);
  activeManifestPaths = result.manifestPaths;
  activeOutputFolder = path.resolve(config.outputFolder);
  if (result.errors.length === 0) await scanner.cleanupTempDirs();
  return result;
});

ipcMain.handle('apply:retry', async (event, { plan, config }) => {
  assertArray(plan, 'retry plan');
  if (!config || typeof config !== 'object') throw new Error('Invalid retry configuration');
  assertString(config.outputFolder, 'output folder');
  const onProgress = progress => mainWindow.webContents.send('apply:progress', progress);
  const result = await mover.apply(plan, {
    ...config,
    manifestDirectory: undoDirectory(),
  }, onProgress);
  activeManifestPaths.push(...result.manifestPaths);
  return result;
});

// Undo last operation
ipcMain.handle('apply:undo', async (event, { manifestPath }) => {
  assertString(manifestPath, 'manifest path');
  const result = await mover.undo(manifestPath, undoDirectory());
  if (!result.manifestPath) activeManifestPaths = activeManifestPaths.filter(item => item !== manifestPath);
  return result;
});

ipcMain.handle('apply:undoMany', async (event, { manifestPaths }) => {
  assertArray(manifestPaths, 'manifest paths', 100).forEach(item => assertString(item, 'manifest path'));
  let restored = 0;
  const errors = [];
  const remaining = [...manifestPaths];
  for (const manifestPath of [...manifestPaths].reverse()) {
    const result = await mover.undo(manifestPath, undoDirectory());
    restored += result.restored;
    if (result.errors.length > 0) {
      errors.push(...result.errors);
      break;
    }
    remaining.splice(remaining.indexOf(manifestPath), 1);
    activeManifestPaths = activeManifestPaths.filter(item => item !== manifestPath);
  }
  return { restored, errors, manifestPaths: remaining };
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
  mover.findEmptyFolders(allowedSourceRoots, [activeOutputFolder].filter(Boolean)).length
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

ipcMain.handle('support:openDiagnosticsForm', async () => {
  let logContent = '';
  try { logContent = require('fs').readFileSync(diagnosticsPath(), 'utf8'); } catch {}
  const options = { logContent, appVersion: app.getVersion() };
  clipboard.writeText(buildDiagnosticSummary(options));
  await shell.openExternal(buildSupportWebURL(options));
  return true;
});

ipcMain.handle('support:copyDiagnostics', async () => {
  let logContent = '';
  try { logContent = require('fs').readFileSync(diagnosticsPath(), 'utf8'); } catch {}
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
