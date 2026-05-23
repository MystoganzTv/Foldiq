import { useState } from 'react';
import s from './Screen.module.css';

export default function ReportScreen({ go, result, config, setFolders, setFiles, setPlan, setResult }) {
  const [undoing, setUndoing] = useState(false);
  const [undone,  setUndone]  = useState(false);

  async function handleUndo() {
    setUndoing(true);
    await window.foldiq.undoApply(result.manifestPath);
    setUndone(true);
    setUndoing(false);
  }

  async function openFolder() {
    await window.foldiq.openFolder(config.outputFolder);
  }

  async function exportCSV() {
    const rows = (result?.errors || []).map(e => ({ file: e.file, error: e.error }));
    await window.foldiq.exportCSV(rows);
  }

  function startOver() {
    setFolders([]);
    setFiles([]);
    setPlan([]);
    setResult(null);
    go('welcome');
  }

  if (!result) return null;

  return (
    <div className={s.screen}>
      <div className={s.header}>
        <h1 className={s.title}>{undone ? 'Undo Complete' : 'Organization Report'}</h1>
        <p className={s.sub}>{undone ? 'All files restored to their original locations.' : 'Your photo library is now organized.'}</p>
      </div>

      {!undone && (
        <>
          <div className={s.statsGrid}>
            <div className={s.statCard}>
              <div className={s.statNum}>{result.moved.toLocaleString()}</div>
              <div className={s.statLabel}>Files {config.copyMode ? 'copied' : 'moved'}</div>
            </div>
            <div className={s.statCard}>
              <div className={s.statNum}>{result.skipped.toLocaleString()}</div>
              <div className={s.statLabel}>Skipped</div>
            </div>
            <div className={s.statCard}>
              <div className={`${s.statNum} ${result.errors.length > 0 ? s.red : s.green}`}>
                {result.errors.length}
              </div>
              <div className={s.statLabel}>Errors</div>
            </div>
          </div>

          {result.errors.length > 0 && (
            <div className={s.errorList}>
              <p className={s.errorTitle}>⚠ Files with errors</p>
              {result.errors.map((e, i) => (
                <div key={i} className={s.errorRow}>
                  <span className={s.errorFile}>{e.file}</span>
                  <span className={s.errorMsg}>{e.error}</span>
                </div>
              ))}
            </div>
          )}

          <div className={s.actions}>
            <button className={s.btnSecondary} onClick={openFolder}>Open Folder</button>
            {result.errors.length > 0 && (
              <button className={s.btnOutline} onClick={exportCSV}>Export CSV</button>
            )}
            <button
              className={s.btnDanger}
              onClick={handleUndo}
              disabled={undoing}
            >
              {undoing ? 'Undoing…' : '↩ Undo'}
            </button>
          </div>
        </>
      )}

      <div className={s.actions} style={{ marginTop: undone ? 32 : 16 }}>
        <button className={s.btnPrimary} onClick={startOver}>Start Over</button>
      </div>
    </div>
  );
}
