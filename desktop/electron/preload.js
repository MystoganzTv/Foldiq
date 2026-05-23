const { contextBridge, ipcRenderer } = require('electron');

// Expose a safe API to the renderer (React app)
contextBridge.exposeInMainWorld('foldiq', {
  // Dialogs
  selectFolders:  ()           => ipcRenderer.invoke('dialog:selectFolders'),
  selectOutput:   ()           => ipcRenderer.invoke('dialog:selectOutput'),

  // Scan
  startScan:      (folders)    => ipcRenderer.invoke('scan:start', { folders }),
  onScanProgress: (cb)         => ipcRenderer.on('scan:progress', (_, p) => cb(p)),

  // Plan
  buildPlan:      (files, cfg) => ipcRenderer.invoke('plan:build', { files, config: cfg }),

  // Apply
  startApply:     (plan, cfg)  => ipcRenderer.invoke('apply:start', { plan, config: cfg }),
  onApplyProgress:(cb)         => ipcRenderer.on('apply:progress', (_, p) => cb(p)),
  undoApply:      (manifest)   => ipcRenderer.invoke('apply:undo', { manifestPath: manifest }),

  // Shell
  openFolder:     (p)          => ipcRenderer.invoke('shell:openFolder', { folderPath: p }),

  // Report
  exportCSV:      (rows)       => ipcRenderer.invoke('report:exportCSV', { rows }),

  // Cleanup listeners
  removeAllListeners: (channel) => ipcRenderer.removeAllListeners(channel),
});
