import { useEffect, useState } from 'react';
import s from './Screen.module.css';

export default function ReportScreen({ go, result, config, plan, setFolders, setFiles, setPlan, setResult }) {
  const [undoing, setUndoing] = useState(false);
  const [undone,  setUndone]  = useState(false);
  const [restarting, setRestarting] = useState(false);
  const [retrying, setRetrying] = useState(false);
  const [retryProgress, setRetryProgress] = useState({ current: 0, total: 0 });
  const [undoError, setUndoError] = useState('');
  const [undoProgress, setUndoProgress] = useState({ current: 0, total: 0, file: '' });
  const [emptyFolderCount, setEmptyFolderCount] = useState(0);
  const [cleaning, setCleaning] = useState(false);
  const [foldersRemoved, setFoldersRemoved] = useState(null);
  const [showReviewInvite, setShowReviewInvite] = useState(false);
  const completed = result?.completed || [];
  const copied = completed.filter(file => file.action === 'copy').length;
  const moved = completed.filter(file => file.action === 'move').length;

  useEffect(() => {
    if (!result || config.copyMode) return;
    window.foldiq.countEmptyFolders().then(setEmptyFolderCount).catch(() => {});
  }, [config.copyMode, result]);

  // Counted once per finished run, and only when nothing failed. The invitation
  // sits at the bottom of the report so it is read after Undo, not before it.
  useEffect(() => {
    if (!result || result.errors.length > 0 || completed.length === 0) return;
    let cancelled = false;
    window.foldiq.recordOrganizationSuccess(completed.length)
      .then(shouldShow => { if (!cancelled) setShowReviewInvite(shouldShow === true); })
      .catch(() => {});
    return () => { cancelled = true; };
  }, [result]);

  useEffect(() => {
    if (!retrying) return undefined;
    window.foldiq.onApplyProgress(progress => setRetryProgress(progress));
    return () => window.foldiq.removeAllListeners('apply:progress');
  }, [retrying]);

  useEffect(() => {
    if (!undoing) return undefined;
    window.foldiq.onUndoProgress(progress => setUndoProgress(progress));
    return () => window.foldiq.removeAllListeners('undo:progress');
  }, [undoing]);

  async function exportReport() {
    const completedPaths = new Set(completed.map(file => `${file.path}\n${file.destPath}`));
    const errorPaths = new Set(result.errors.map(file => `${file.path}\n${file.destPath}`));
    await window.foldiq.exportCSV(plan.map(file => ({
      file: file.name,
      source: file.archiveSourcePath || file.path,
      destination: file.destPath || '',
      operation: file.action,
      included: file.included !== false,
      date: file.date || '',
      duplicate: file.isDuplicate
        ? 'exact'
        : file.isProbableDuplicate
          ? 'strong-visual-match'
          : file.probableDuplicateGroupID
            ? `review-only-${file.probableMatchKind || 'similar'}`
            : '',
      status: file.action === 'skip' || file.included === false
        ? 'untouched'
        : errorPaths.has(`${file.path}\n${file.destPath}`)
          ? 'error'
          : completedPaths.has(`${file.path}\n${file.destPath}`) ? 'completed' : 'not processed',
    })));
  }

  async function handleUndo() {
    setUndoing(true);
    setUndoProgress({ current: 0, total: 0, file: 'Preparing safe Undo…' });
    setUndoError('');
    try {
      const manifests = result.manifestPaths || [result.manifestPath].filter(Boolean);
      const undoResult = await window.foldiq.undoAll(manifests);
      if (undoResult.errors.length > 0) {
        setUndoError(undoResult.errors[0]?.error || 'Some files could not be restored safely.');
        setResult(current => ({ ...current, manifestPaths: undoResult.manifestPaths }));
      } else {
        setUndone(true);
      }
    } catch (error) {
      setUndoError(error?.message || 'Undo could not be completed safely.');
    } finally {
      setUndoing(false);
    }
  }

  async function retryFailed() {
    const failedKeys = new Set(result.errors.map(error => `${error.path || ''}\n${error.destPath || ''}`));
    const failedNames = new Set(result.errors.map(error => error.file));
    const retryPlan = plan.filter(file => (
      failedKeys.has(`${file.path || ''}\n${file.destPath || ''}`) ||
      (!result.errors.some(error => error.path) && failedNames.has(file.name))
    ));
    if (retryPlan.length === 0) return;

    setRetrying(true);
    setRetryProgress({ current: 0, total: retryPlan.length });
    try {
      const retried = await window.foldiq.retryApply(retryPlan, config);
      setResult(current => ({
        ...current,
        moved: current.moved + retried.moved,
        errors: retried.errors,
        completed: [...(current.completed || []), ...(retried.completed || [])],
        manifestPaths: [...(current.manifestPaths || [current.manifestPath].filter(Boolean)), ...retried.manifestPaths],
      }));
    } finally {
      setRetrying(false);
    }
  }

  async function removeEmptyFolders() {
    setCleaning(true);
    try {
      const removed = await window.foldiq.removeEmptyFolders();
      setFoldersRemoved(removed);
      setEmptyFolderCount(0);
    } finally {
      setCleaning(false);
    }
  }

  async function startOver() {
    setRestarting(true);
    try {
      const manifests = result.manifestPaths || [result.manifestPath].filter(Boolean);
      if (manifests.length > 0) await window.foldiq.discardUndoAll(manifests);
    } finally {
      setFolders([]); setFiles([]); setPlan([]); setResult(null);
      go('welcome');
    }
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
        <button className={s.btnPrimary} style={{ marginTop: 24 }} onClick={startOver} disabled={restarting}>
          {restarting ? 'Cleaning Up…' : 'Start Over'}
        </button>
      </div>
    </div>
  );

  return (
    <div className={s.screen}>
      <div className={s.scrollArea}>
        <div>
          <h1 className={s.title}>Organization Report</h1>
          <p className={s.sub}>{result.errors.length > 0
            ? 'The completed files are safe, but some files still need attention.'
            : 'Your photo library is now organized.'}</p>
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
              <div className={s.statLabel}>Files organized</div>
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

        <div className={s.reportSummaryBar}>
          <span><strong>{copied.toLocaleString()}</strong> copied</span>
          <span><strong>{moved.toLocaleString()}</strong> moved</span>
          <span><strong>{result.skipped.toLocaleString()}</strong> untouched</span>
        </div>

        <details className={s.detailedReportDisclosure}>
          <summary>Need a detailed file report?</summary>
          <p>Optional: save a spreadsheet-compatible list of every source, destination, operation, and error. Most users do not need this.</p>
          <button className={s.btnOutline} onClick={exportReport}>Save Detailed Report (.CSV)</button>
        </details>

        {undoing && (
          <div className={s.undoProgressCard} role="status" aria-live="polite">
            <div><strong>Undoing organization safely…</strong><span>{undoProgress.total > 0 ? `${undoProgress.current.toLocaleString()} of ${undoProgress.total.toLocaleString()}` : 'Preparing…'}</span></div>
            <div className={s.progressBar}>
              <div className={s.progressFill} style={{ width: `${undoProgress.total > 0 ? Math.round((undoProgress.current / undoProgress.total) * 100) : 0}%` }} />
            </div>
            <p>{undoProgress.phase === 'verifying' ? 'Verifying before restoring' : 'Restored'} · {undoProgress.file || 'Please wait…'}</p>
            <small>Large files or network drives can take longer. Foldiq remains responsive while it verifies that files were not changed.</small>
          </div>
        )}

        {result.errors.length > 0 && (
          <div className={s.errorList}>
            <div className={s.errorListHeader}>
              <p className={s.errorTitle}>⚠ Files with errors</p>
              <button className={s.btnOutline} onClick={retryFailed} disabled={retrying}>
                {retrying
                  ? `Retrying ${retryProgress.current || 0} of ${retryProgress.total || result.errors.length}…`
                  : `↻ Retry ${result.errors.length === 1 ? 'Failed File' : 'Failed Files'}`}
              </button>
            </div>
            {result.errors.map((e, i) => (
              <div key={i} className={s.errorRow}>
                <span className={s.errorFile}>{e.file}</span>
                <span className={s.errorMsg}>{e.error}</span>
              </div>
            ))}
          </div>
        )}

        {!config.copyMode && (emptyFolderCount > 0 || foldersRemoved != null) && (
          <div className={s.cleanupCard}>
            <div>
              <strong>{foldersRemoved != null ? 'Empty-folder cleanup complete' : `${emptyFolderCount.toLocaleString()} empty folder${emptyFolderCount === 1 ? '' : 's'} found`}</strong>
              <p>{foldersRemoved != null
                ? `${foldersRemoved.toLocaleString()} empty folder${foldersRemoved === 1 ? '' : 's'} removed.`
                : 'These folders contain no files. Your selected source folders and organized output are always preserved.'}</p>
            </div>
            {foldersRemoved == null && (
              <button className={s.btnOutline} onClick={removeEmptyFolders} disabled={cleaning}>
                {cleaning ? 'Removing…' : 'Remove Empty Folders'}
              </button>
            )}
          </div>
        )}

        {showReviewInvite && !undone && (
          <div className={s.reviewCard}>
            <div>
              <strong>Did Foldiq get this right?</strong>
              <p>Foldiq is built by one person. A few honest lines about how it went is the main way other people hear about it.</p>
            </div>
            <div className={s.reviewCardActions}>
              <button className={s.btnOutline} onClick={() => { setShowReviewInvite(false); window.foldiq.dismissReviewInvite().catch(() => {}); }}>
                Not now
              </button>
              <button className={s.btnPrimary} onClick={() => { setShowReviewInvite(false); window.foldiq.openReviewForm().catch(() => {}); }}>
                ★ Leave a Review
              </button>
            </div>
          </div>
        )}

        {undoError && <div className={s.reportInlineError}>{undoError}</div>}
      </div>

      <div className={s.bottomBar}>
        <button className={s.btnDanger} onClick={handleUndo} disabled={undoing}>
          {undoing ? 'Undoing…' : '↩ Undo'}
        </button>
        <div className={s.bottomBarRight}>
          <button className={s.btnSecondary} onClick={() => window.foldiq.openFolder(config.outputFolder)}>Open Folder</button>
          <button className={s.btnPrimary} onClick={startOver} disabled={restarting || undoing}>
            {restarting ? 'Cleaning Up…' : 'Start Over'}
          </button>
        </div>
      </div>
    </div>
  );
}
