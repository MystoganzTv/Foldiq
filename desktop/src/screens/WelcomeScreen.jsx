import { useEffect, useRef, useState } from 'react';
import s from './Screen.module.css';

export default function WelcomeScreen({ go, folders, setFolders, config, setConfig }) {
  const [dragging, setDragging] = useState(false);
  const [showHow, setShowHow] = useState(false);
  const [appInfo, setAppInfo] = useState(null);
  const [pendingUndo, setPendingUndo] = useState([]);
  const [resumingUndo, setResumingUndo] = useState(false);
  const [undoProgress, setUndoProgress] = useState({ current: 0, total: 0, file: '' });
  const [recoveryMessage, setRecoveryMessage] = useState('');
  const listRef = useRef(null);

  useEffect(() => {
    if (!window.foldiq?.getAppInfo) {
      setAppInfo({ version: '1.0.18', platform: 'browser-preview' });
      return;
    }
    window.foldiq.getAppInfo().then(setAppInfo).catch(() => {});
    window.foldiq.getPendingUndo().then(setPendingUndo).catch(() => {});
  }, []);

  useEffect(() => {
    if (!resumingUndo) return undefined;
    window.foldiq.onUndoProgress(progress => setUndoProgress(progress));
    return () => window.foldiq.removeAllListeners('undo:progress');
  }, [resumingUndo]);

  async function resumeUndo() {
    setResumingUndo(true);
    setRecoveryMessage('');
    try {
      const result = await window.foldiq.undoAll(pendingUndo.map(item => item.path));
      const remaining = await window.foldiq.getPendingUndo();
      setPendingUndo(remaining);
      setRecoveryMessage(result.errors.length > 0
        ? `Foldiq restored ${result.restored.toLocaleString()} files. One or more files need attention before Undo can finish.`
        : `Safe Undo complete — ${result.restored.toLocaleString()} files restored.`);
    } catch (error) {
      setRecoveryMessage(error?.message || 'Safe Undo could not continue. Your recovery record was preserved.');
    } finally {
      setResumingUndo(false);
    }
  }

  function addSources(selected) {
    if (selected.length) {
      setFolders(prev => [...new Set([...prev, ...selected])]);
      setTimeout(() => listRef.current?.scrollIntoView({ behavior: 'smooth', block: 'nearest' }), 50);
    }
  }

  async function pickFolders() {
    addSources(await window.foldiq.selectFolders());
  }

  async function pickArchives() {
    addSources(await window.foldiq.selectArchives());
  }

  async function onDrop(e) {
    e.preventDefault();
    setDragging(false);
    const candidates = Array.from(e.dataTransfer.files)
      .map(file => window.foldiq.getPathForFile(file))
      .filter(Boolean);
    addSources(await window.foldiq.filterSources(candidates));
  }

  const hasFolders = folders.length > 0;

  return (
    <div className={s.screen}>
      <div className={`${s.scrollArea} ${s.welcomeContent} ${hasFolders ? s.welcomeWithSources : s.welcomeEmpty}`}>
        {(pendingUndo.length > 0 || recoveryMessage) && (
          <div className={s.recoveryCard} role="status" aria-live="polite">
            <div>
              <strong>{pendingUndo.length > 0 ? 'An interrupted organization needs attention' : 'Recovery complete'}</strong>
              <p>{recoveryMessage || `Foldiq safely recorded ${pendingUndo.reduce((sum, item) => sum + item.files, 0).toLocaleString()} planned files before the interruption. Restore completed files before starting another organization.`}</p>
              {resumingUndo && <small>{undoProgress.total > 0 ? `${undoProgress.current.toLocaleString()} of ${undoProgress.total.toLocaleString()} · ` : ''}{undoProgress.file || 'Preparing safe Undo…'}</small>}
            </div>
            {pendingUndo.length > 0 && <button className={s.btnDanger} onClick={resumeUndo} disabled={resumingUndo}>{resumingUndo ? 'Restoring…' : 'Restore Files Safely'}</button>}
          </div>
        )}
        {/* Hero — compact when folders selected */}
        <div className={`${s.welcomeHero} ${hasFolders ? s.welcomeHeroSelected : ''}`}>
          <svg className={s.welcomeLogo} width={hasFolders ? 52 : 80} height={hasFolders ? 52 : 80} viewBox="0 0 80 80" fill="none">
            <rect width="80" height="80" rx="20" fill="url(#grad)"/>
            <defs>
              <linearGradient id="grad" x1="0" y1="0" x2="80" y2="80" gradientUnits="userSpaceOnUse">
                <stop stopColor="#6366F1"/>
                <stop offset="1" stopColor="#8B5CF6"/>
              </linearGradient>
            </defs>
            <path d="M18 28C18 25.8 19.8 24 22 24H36L42 30H58C60.2 30 62 31.8 62 34V52C62 54.2 60.2 56 58 56H22C19.8 56 18 54.2 18 52V28Z" fill="white" fillOpacity="0.2"/>
            <path d="M20 32C20 29.8 21.8 28 24 28H38L44 34H60C62.2 34 64 35.8 64 38V54C64 56.2 62.2 58 60 58H24C21.8 58 20 56.2 20 54V32Z" fill="white" fillOpacity="0.9"/>
            <circle cx="58" cy="26" r="10" fill="#F59E0B"/>
            <path d="M54 26H62M58 22V30" stroke="white" strokeWidth="2.5" strokeLinecap="round"/>
          </svg>
          {!hasFolders && (
            <>
              <h1 className={s.welcomeTitle}>
                Organize Your Library
              </h1>
              <p className={s.welcomeSubtitle}>
                Clean up and organize thousands of messy<br />photos and videos safely, right on your PC.
              </p>
            </>
          )}
          {hasFolders && (
            <h1 className={s.welcomeSelectedTitle}>
              {folders.length} item{folders.length > 1 ? 's' : ''} selected
            </h1>
          )}
        </div>

        {/* Drop zone — compact when folders already added */}
        <div
          className={`${s.dropzone} ${hasFolders ? s.dropzoneSelected : ''} ${dragging ? s.dragging : ''}`}
          role="button"
          tabIndex={0}
          onClick={pickFolders}
          onKeyDown={event => {
            if (event.key === 'Enter' || event.key === ' ') {
              event.preventDefault();
              pickFolders();
            }
          }}
          onDragOver={e => { e.preventDefault(); setDragging(true); }}
          onDragLeave={() => setDragging(false)}
          onDrop={onDrop}
        >
          {!hasFolders && (
            <div className={s.welcomeDropIcon}>
              <svg width="48" height="48" viewBox="0 0 24 24" fill="none" stroke="#3B82F6" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
                <path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/>
              </svg>
            </div>
          )}
          <p className={s.dropTitle} style={hasFolders ? { fontSize: 14 } : {}}>
            {hasFolders ? '+ Drop more folders or archives, or click to add a folder' : 'Drop folders or ZIP, RAR, or 7z archives here'}
          </p>
          {!hasFolders && <p className={s.dropSub}>Supports ZIP, RAR, 7z, JPG, HEIC, RAW, MOV, MP4 and more</p>}
        </div>

        {/* Selected folders */}
        {hasFolders && (
          <div ref={listRef} className={s.folderList}>
            {folders.map((f, i) => (
              <div key={f} className={s.folderItem}>
                <span className={s.folderIcon}>
                  {['.zip', '.rar', '.7z'].some(ext => f.toLowerCase().endsWith(ext)) ? (
                    <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="#3B82F6" strokeWidth="2">
                      <path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><path d="M14 2v6h6"/><path d="M12 11v7M9.5 14.5h5"/>
                    </svg>
                  ) : (
                    <svg width="18" height="18" viewBox="0 0 24 24" fill="#3B82F6">
                      <path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/>
                    </svg>
                  )}
                </span>
                <span className={s.folderPath}>{f}</span>
                <button
                  className={s.folderRemove}
                  aria-label={`Remove ${f}`}
                  onClick={e => { e.stopPropagation(); setFolders(folders.filter((_, j) => j !== i)); }}
                >✕</button>
              </div>
            ))}
          </div>
        )}

        <div className={s.welcomeScanOptions}>
          <label><input type="checkbox" checked={config.includeVideos} onChange={() => setConfig(c => ({ ...c, includeVideos: !c.includeVideos }))} /> Include videos</label>
          <label><input type="checkbox" checked={config.includeArchives} onChange={() => setConfig(c => ({ ...c, includeArchives: !c.includeArchives }))} /> Include ZIP, RAR, and 7z</label>
          <label title="Sends only anonymous operation counts, duration ranges, app version, and success status. Never photos, filenames, paths, dates, or metadata."><input type="checkbox" checked={config.shareAnonymousUsageData} onChange={() => setConfig(c => ({ ...c, shareAnonymousUsageData: !c.shareAnonymousUsageData }))} /> Help improve Foldiq anonymously</label>
        </div>

        <div className={s.welcomeFooterInfo}>
          <span>Nothing is deleted without your permission.</span>
          <button onClick={() => setShowHow(true)}>How it works</button>
          <span>{appInfo ? `v${appInfo.version} · Windows` : 'Foldiq for Windows'}</span>
        </div>
      </div>

      <div className={s.bottomBar}>
        <div />
        <div className={s.bottomBarRight}>
          <button className={s.btnSecondary} onClick={pickFolders}>+ Add Folders</button>
          <button className={s.btnSecondary} onClick={pickArchives}>+ Add Archives</button>
          <button
            className={s.btnPrimary}
            disabled={folders.length === 0 || pendingUndo.length > 0 || resumingUndo}
            onClick={() => go('scan')}
          >
            Scan Items →
          </button>
        </div>
      </div>

      {showHow && (
        <div className={s.modalBackdrop} onMouseDown={event => { if (event.target === event.currentTarget) setShowHow(false); }}>
          <section className={s.modalCard} role="dialog" aria-modal="true" aria-label="How Foldiq works">
            <div className={s.modalHeader}><h2>How Foldiq works</h2><button onClick={() => setShowHow(false)}>×</button></div>
            <div className={s.modalBody}>
              <div className={s.howSteps}>
                <p><strong>1. Scan locally</strong><span>Foldiq reads folders or compressed archives without uploading your media.</span></p>
                <p><strong>2. Review everything</strong><span>Dates, duplicates, destinations, and operations are shown before changes are made.</span></p>
                <p><strong>3. Organize safely</strong><span>Foldiq never overwrites files. Archive originals remain untouched.</span></p>
                <p><strong>4. Undo if needed</strong><span>A local manifest verifies files before reversing an operation.</span></p>
              </div>
              <div className={s.modalActions}><button className={s.btnPrimary} onClick={() => setShowHow(false)}>Got it</button></div>
            </div>
          </section>
        </div>
      )}
    </div>
  );
}
