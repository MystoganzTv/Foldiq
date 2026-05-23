const { app, BrowserWindow, ipcMain, dialog, shell } = require('electron');
const path = require('path');
const isDev = process.env.NODE_ENV === 'development' || !app.isPackaged;

const scanner  = require('./services/scanner');
const planner  = require('./services/planner');
const mover    = require('./services/mover');

let mainWindow;

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
    },
  });

  if (isDev) {
    mainWindow.loadURL('http://localhost:5173');
    mainWindow.webContents.openDevTools();
  } else {
    mainWindow.loadFile(path.join(__dirname, '../dist/index.html'));
  }
}

app.whenReady().then(createWindow);
app.on('window-all-closed', () => { if (process.platform !== 'darwin') app.quit(); });
app.on('activate', () => { if (BrowserWindow.getAllWindows().length === 0) createWindow(); });

// ── IPC Handlers ──────────────────────────────────────────────────────────────

// Pick folder(s) via dialog
ipcMain.handle('dialog:selectFolders', async () => {
  const result = await dialog.showOpenDialog(mainWindow, {
    properties: ['openDirectory', 'multiSelections'],
    title: 'Select folders to organize',
  });
  return result.canceled ? [] : result.filePaths;
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
  const onProgress = (p) => mainWindow.webContents.send('scan:progress', p);
  return await scanner.scan(folders, onProgress);
});

// Build organization plan
ipcMain.handle('plan:build', async (event, { files, config }) => {
  return planner.buildPlan(files, config);
});

// Apply plan — streams progress
ipcMain.handle('apply:start', async (event, { plan, config }) => {
  const onProgress = (p) => mainWindow.webContents.send('apply:progress', p);
  return await mover.apply(plan, config, onProgress);
});

// Undo last operation
ipcMain.handle('apply:undo', async (event, { manifestPath }) => {
  return await mover.undo(manifestPath);
});

// Open folder in Explorer/Finder
ipcMain.handle('shell:openFolder', async (event, { folderPath }) => {
  await shell.openPath(folderPath);
});

// Export CSV report
ipcMain.handle('report:exportCSV', async (event, { rows }) => {
  const result = await dialog.showSaveDialog(mainWindow, {
    title: 'Save Report',
    defaultPath: `Foldiq-Report-${Date.now()}.csv`,
    filters: [{ name: 'CSV', extensions: ['csv'] }],
  });
  if (result.canceled) return null;
  const fs = require('fs');
  const csv = rows.map(r => Object.values(r).join(',')).join('\n');
  fs.writeFileSync(result.filePath, csv, 'utf-8');
  return result.filePath;
});
