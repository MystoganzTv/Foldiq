const { contextBridge, ipcRenderer, webUtils } = require('electron');

// Expose a safe API to the renderer (React app)
contextBridge.exposeInMainWorld('foldiq', {
  // Dialogs
  selectFolders:  ()           => ipcRenderer.invoke('dialog:selectFolders'),
  selectArchives: ()           => ipcRenderer.invoke('dialog:selectArchives'),
  selectOutput:   ()           => ipcRenderer.invoke('dialog:selectOutput'),
  getPathForFile: (file)       => webUtils.getPathForFile(file),
  filterSources:  (paths)      => ipcRenderer.invoke('sources:filterSupported', { sourcePaths: paths }),
  getAppInfo:     ()           => ipcRenderer.invoke('app:info'),
  getPreferences: ()           => ipcRenderer.invoke('preferences:get'),
  savePreferences:(value)      => ipcRenderer.invoke('preferences:save', { value }),

  // Scan
  startScan:      (folders, options) => ipcRenderer.invoke('scan:start', { folders, options }),
  cancelScan:     ()           => ipcRenderer.invoke('scan:cancel'),
  onScanProgress: (cb)         => ipcRenderer.on('scan:progress', (_, p) => cb(p)),
  getThumbnail:   (filePath)   => ipcRenderer.invoke('preview:thumbnail', { filePath }),

  // Plan
  buildPlan:      (files, cfg) => ipcRenderer.invoke('plan:build', { files, config: cfg }),
  onPlanProgress: (cb)         => ipcRenderer.on('plan:progress', (_, p) => cb(p)),

  // Apply
  startApply:     (plan, cfg)  => ipcRenderer.invoke('apply:start', { plan, config: cfg }),
  retryApply:     (plan, cfg)  => ipcRenderer.invoke('apply:retry', { plan, config: cfg }),
  onApplyProgress:(cb)         => ipcRenderer.on('apply:progress', (_, p) => cb(p)),
  undoApply:      (manifest)   => ipcRenderer.invoke('apply:undo', { manifestPath: manifest }),
  undoAll:        (manifests)  => ipcRenderer.invoke('apply:undoMany', { manifestPaths: manifests }),
  discardUndo:    (manifest)   => ipcRenderer.invoke('apply:discardUndo', { manifestPath: manifest }),
  discardUndoAll: (manifests)  => ipcRenderer.invoke('apply:discardUndoMany', { manifestPaths: manifests }),
  countEmptyFolders: ()        => ipcRenderer.invoke('cleanup:countEmpty'),
  removeEmptyFolders:()        => ipcRenderer.invoke('cleanup:removeEmpty'),

  // Shell
  openFolder:     (p)          => ipcRenderer.invoke('shell:openFolder', { folderPath: p }),
  revealFile:     (p)          => ipcRenderer.invoke('shell:revealFile', { filePath: p }),
  openAttribution:()           => ipcRenderer.invoke('shell:openAttribution'),
  openDiagnosticsForm: ()    => ipcRenderer.invoke('support:openDiagnosticsForm'),
  copyDiagnostics: ()        => ipcRenderer.invoke('support:copyDiagnostics'),

  // Report
  exportCSV:      (rows)       => ipcRenderer.invoke('report:exportCSV', { rows }),

  // Cleanup listeners
  removeAllListeners: (channel) => ipcRenderer.removeAllListeners(channel),
});
