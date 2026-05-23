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

  function startOver() {
    setFolders([]); setFiles([]); setPlan([]); setResult(null);
    go('welcome');
  }

  if (!result) return null;

  if (undone) return (
    <div className={s.screen}>
      <div className={s.centerBlock}>
        <svg width="64" height="64" viewBox="0 0 24 24" fill="none" stroke="#10B981" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
          <path d="M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8"/><path d="M3 3v5h5"/>
        </svg>
        <h1 className={s.title}>Undo Complete</h1>
        <p className={s.sub}>All files restored to their original locations.</p>
        <button className={s.btnPrimary} style={{ marginTop: 24 }} onClick={startOver}>Start Over</button>
      </div>
    </div>
  );

  return (
    <div className={s.screen}>
      <div className={s.scrollArea}>
        <div>
          <h1 className={s.title}>Organization Report</h1>
          <p className={s.sub}>Your photo library is now organized.</p>
        </div>

        <div className={s.statsGrid} style={{ gridTemplateColumns: 'repeat(3,1fr)' }}>
          <div className={s.statCard}>
            <div className={s.statIcon} style={{ background: '#EFF6FF' }}>
              <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="#3B82F6" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
                <path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/>
              </svg>
            </div>
            <div>
              <div className={s.statNum}>{result.moved.toLocaleString()}</div>
              <div className={s.statLabel}>Files {config.copyMode ? 'copied' : 'moved'}</div>
            </div>
          </div>
          <div className={s.statCard}>
            <div className={s.statIcon} style={{ background: '#FEFCE8' }}>
              <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="#EAB308" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
                <circle cx="12" cy="12" r="10"/><line x1="8" y1="12" x2="16" y2="12"/>
              </svg>
            </div>
            <div>
              <div className={s.statNum}>{result.skipped.toLocaleString()}</div>
              <div className={s.statLabel}>Skipped</div>
            </div>
          </div>
          <div className={s.statCard}>
            <div className={s.statIcon} style={{ background: result.errors.length > 0 ? '#FEF2F2' : '#F0FDF4' }}>
              <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke={result.errors.length > 0 ? '#EF4444' : '#22C55E'} strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
                {result.errors.length > 0
                  ? <><circle cx="12" cy="12" r="10"/><line x1="12" y1="8" x2="12" y2="12"/><line x1="12" y1="16" x2="12.01" y2="16"/></>
                  : <><path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"/><polyline points="22 4 12 14.01 9 11.01"/></>
                }
              </svg>
            </div>
            <div>
              <div className={`${s.statNum} ${result.errors.length > 0 ? s.red : s.green}`}>{result.errors.length}</div>
              <div className={s.statLabel}>Errors</div>
            </div>
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
      </div>

      <div className={s.bottomBar}>
        <button className={s.btnDanger} onClick={handleUndo} disabled={undoing}>
          {undoing ? 'Undoing…' : '↩ Undo'}
        </button>
        <div className={s.bottomBarRight}>
          <button className={s.btnSecondary} onClick={() => window.foldiq.openFolder(config.outputFolder)}>Open Folder</button>
          <button className={s.btnPrimary} onClick={startOver}>Start Over</button>
        </div>
      </div>
    </div>
  );
}
