const { app, BrowserWindow, ipcMain, dialog, shell } = require('electron');
const path = require('path');
const isDev = process.env.NODE_ENV === 'development' || !app.isPackaged;

const scanner  = require('./services/scanner');
const planner  = require('./services/planner');
const mover    = require('./services/mover');
const { rowsToCSV } = require('./services/csv');
const { filterSupportedSources } = require('./services/sources');

let mainWindow;
let activeManifestPath = null;

function undoDirectory() {
  return path.join(app.getPath('userData'), 'undo');
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

// Pick ZIP archive(s) directly. Windows cannot combine file and directory
// selection in one native dialog, so folders and ZIPs use separate pickers.
ipcMain.handle('dialog:selectArchives', async () => {
  const result = await dialog.showOpenDialog(mainWindow, {
    properties: ['openFile', 'multiSelections'],
    title: 'Select ZIP archives to organize',
    filters: [{ name: 'ZIP archives', extensions: ['zip'] }],
  });
  return result.canceled ? [] : filterSupportedSources(result.filePaths);
});

ipcMain.handle('sources:filterSupported', async (event, { sourcePaths }) => {
  assertArray(sourcePaths, 'source paths', 100).forEach(sourcePath => assertString(sourcePath, 'source path'));
  return filterSupportedSources(sourcePaths);
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
ipcMain.handle('scan:start', async (event, { folders }) => {
  assertArray(folders, 'folders', 100).forEach(folder => assertString(folder, 'folder'));
  const onProgress = (p) => mainWindow.webContents.send('scan:progress', p);
  return await scanner.scan(folders, onProgress);
});

// Build organization plan
ipcMain.handle('plan:build', async (event, { files, config }) => {
  assertArray(files, 'files');
  if (!config || typeof config !== 'object') throw new Error('Invalid plan configuration');
  assertString(config.outputFolder, 'output folder');
  return planner.buildPlan(files, config);
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
  activeManifestPath = result.manifestPath;
  if (result.errors.length === 0) scanner.cleanupTempDirs();
  return result;
});

// Undo last operation
ipcMain.handle('apply:undo', async (event, { manifestPath }) => {
  assertString(manifestPath, 'manifest path');
  const result = await mover.undo(manifestPath, undoDirectory());
  if (!result.manifestPath) activeManifestPath = null;
  return result;
});

ipcMain.handle('apply:discardUndo', async (event, { manifestPath }) => {
  assertString(manifestPath, 'manifest path');
  mover.discardManifest(manifestPath, undoDirectory());
  if (activeManifestPath === manifestPath) activeManifestPath = null;
  return true;
});

// Open folder in Explorer/Finder
ipcMain.handle('shell:openFolder', async (event, { folderPath }) => {
  assertString(folderPath, 'folder path');
  await shell.openPath(folderPath);
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
