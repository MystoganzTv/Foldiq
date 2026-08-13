import { useEffect, useRef, useState } from 'react';
import s from './Screen.module.css';

const STAT_CARDS = [
  { key: 'photos',    label: 'Photos',         color: '#EFF6FF', iconColor: '#3B82F6' },
  { key: 'videos',    label: 'Videos',          color: '#F5F3FF', iconColor: '#8B5CF6' },
  { key: 'zips',      label: 'Archives Extracted', color: '#F0FDFA', iconColor: '#14B8A6' },
  { key: 'dupes',     label: 'Exact Dupes',     color: '#FFF7ED', iconColor: '#F97316' },
  { key: 'probDupes', label: 'Same Image',       color: '#FEFCE8', iconColor: '#EAB308' },
  { key: 'similar',   label: 'Similar Photos',   color: '#EEF2FF', iconColor: '#6366F1' },
  { key: 'noDate',    label: 'Missing Date',    color: '#FEF2F2', iconColor: '#EF4444' },
  { key: 'total',     label: 'Total Files',     color: '#F0FDF4', iconColor: '#22C55E' },
];

export default function ScanScreen({ go, folders, setFiles, config }) {
  const [progress, setProgress] = useState({ current: 0, total: 0, file: '' });
  const [done,     setDone]     = useState(false);
  const [stats,    setStats]    = useState(null);
  const [warnings, setWarnings] = useState([]);
  const [error,    setError]    = useState('');
  const [elapsed,  setElapsed]  = useState(0);
  const [scannedFiles, setScannedFiles] = useState([]);
  const [selectedCategory, setSelectedCategory] = useState(null);
  const [cancelling, setCancelling] = useState(false);
  const [showDiagnosticConsent, setShowDiagnosticConsent] = useState(false);
  const [creatingSupportEmail, setCreatingSupportEmail] = useState(false);
  const startedAt = useRef(Date.now());

  useEffect(() => {
    let active = true;
    startedAt.current = Date.now();
    const timer = setInterval(() => setElapsed(Date.now() - startedAt.current), 1000);
    window.foldiq.onScanProgress(p => setProgress(p));
    window.foldiq.startScan(folders, {
      includeVideos: config.includeVideos,
      includeArchives: config.includeArchives,
    }).then(result => {
      if (!active) return;
      const files = Array.isArray(result) ? result : result.files;
      setFiles(files);
      setScannedFiles(files);
      const photoExts = new Set(['.jpg','.jpeg','.png','.heic','.heif','.tiff','.tif','.webp','.cr2','.cr3','.nef','.arw','.dng','.raf','.orf','.rw2']);
      const videoExts = new Set(['.mov','.mp4','.m4v','.avi','.mkv']);
      setStats({
        photos:    files.filter(f => photoExts.has(f.ext)).length,
        videos:    files.filter(f => videoExts.has(f.ext)).length,
        zips:      Array.isArray(result) ? 0 : result.archivesExtracted,
        dupes:     files.filter(f => f.isDuplicate).length,
        probDupes: files.filter(f => f.probableMatchKind === 'same').length,
        similar:   files.filter(f => f.probableDuplicateGroupID && f.probableMatchKind !== 'same').length,
        noDate:    files.filter(f => !f.date).length,
        fileDate:  files.filter(f => !f.date && f.fileModifiedDate).length,
        embeddedDates: files.filter(f => f.date && f.dateSource !== 'filename').length,
        filenameDates: files.filter(f => f.date && f.dateSource === 'filename').length,
        total:     files.length,
      });
      setWarnings(Array.isArray(result) ? [] : result.warnings);
      setDone(true);
      clearInterval(timer);
    }).catch(scanError => {
      if (!active) return;
      setError(scanError?.message || 'The scan could not be completed.');
      setDone(true);
      clearInterval(timer);
    });
    return () => {
      active = false;
      clearInterval(timer);
      window.foldiq.removeAllListeners('scan:progress');
    };
  }, [config.includeArchives, config.includeVideos, folders, setFiles]);

  async function cancelScan() {
    setCancelling(true);
    try { await window.foldiq.cancelScan(); } finally { go('welcome'); }
  }

  async function createSupportEmail() {
    setCreatingSupportEmail(true);
    try {
      await window.foldiq.createDiagnosticsEmail();
      setShowDiagnosticConsent(false);
    } finally {
      setCreatingSupportEmail(false);
    }
  }

  const pct = progress.total > 0 ? Math.round((progress.current / progress.total) * 100) : 0;
  const openingArchives = progress.phase === 'archive' || progress.phase === 'archive-list';
  const hasDeterminateProgress = progress.total > 0;
  const phaseLabel = {
    cleanup: 'Preparing workspace',
    archive: 'Extracting archive',
    'archive-list': 'Archive ready',
    indexing: 'Indexing files',
    metadata: 'Reading capture dates',
    duplicates: 'Checking exact duplicates',
    similarity: 'Finding visually similar photos',
    finalizing: 'Preparing results',
  }[progress.phase] || 'Scanning files';

  return (
    <div className={s.screen}>
      <div className={s.scrollArea}>
        <div style={{ textAlign: 'center', padding: '16px 0 24px' }}>
          {!done && (
            <div className={s.scanStatusIcon} aria-hidden="true">
              <svg className={s.applySpinner} width="48" height="48" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
                <polyline points="23 4 23 10 17 10"/><polyline points="1 20 1 14 7 14"/>
                <path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15"/>
              </svg>
            </div>
          )}
          <h1 className={s.title}>
            {done ? (error ? 'Scan Failed' : 'Scan Complete') : openingArchives ? 'Opening Archives…' : 'Scanning…'}
          </h1>
          <p className={s.sub} style={{ margin: '0 auto' }}>
            {done
              ? error
                ? 'Foldiq could not complete this scan.'
                : folders.map(f => f.split(/[\\/]/).pop()).join(', ')
              : openingArchives
                ? 'The original compressed files remain untouched.'
                : 'Reading metadata from every file…'}
          </p>
        </div>

        {!done && (
          <div className={s.progressBlock} style={{ maxWidth: 500, margin: '0 auto', width: '100%' }}>
            <div className={`${s.progressBar} ${!hasDeterminateProgress ? s.indeterminateBar : ''}`}>
              {hasDeterminateProgress
                ? <div className={s.progressFill} style={{ width: `${pct}%` }} />
                : <div />}
            </div>
            <p className={s.progressLabel} style={{ textAlign: 'center' }}>
              {hasDeterminateProgress
                ? `${progress.current.toLocaleString()} / ${progress.total.toLocaleString()} — ${progress.file}`
                : progress.file || 'Preparing scan…'}
            </p>
            <p className={s.scanPhase}>{phaseLabel}</p>
            <p className={s.scanElapsed}>Elapsed {formatDuration(elapsed)}</p>
            {openingArchives && (
              <p className={s.scanHint}>
                Large archives can take several minutes. Foldiq is working locally and the original archive stays untouched.
              </p>
            )}
            <div className={s.scanActions}>
              <button className={s.btnDanger} disabled={cancelling} onClick={cancelScan}>{cancelling ? 'Cancelling…' : 'Cancel Scan'}</button>
            </div>
          </div>
        )}

        {done && stats && (
          <>
            {warnings.length > 0 && (
              <div style={{ maxWidth: 760, margin: '0 auto 18px', padding: '12px 16px', borderRadius: 10, background: '#FFF7ED', color: '#9A3412', fontSize: 13 }}>
                {warnings.map(warning => (
                  <div key={`${warning.archive}-${warning.message}`}>
                    {warning.archive.split(/[\\/]/).pop()}: {warning.message}
                  </div>
                ))}
                <button className={s.supportDiagnosticsButton} onClick={() => setShowDiagnosticConsent(true)}>Send diagnostics to developer</button>
              </div>
            )}
            <div className={s.statsGrid}>
              {STAT_CARDS.map(card => (
                <button key={card.key} className={`${s.statCard} ${s.statCardButton}`} onClick={() => setSelectedCategory(card)}>
                  <div className={s.statIcon} style={{ background: card.color }}>
                    <StatIcon name={card.key} color={card.iconColor} />
                  </div>
                  <div>
                    <div className={s.statNum}>{stats[card.key].toLocaleString()}</div>
                    <div className={s.statLabel}>{card.label}</div>
                  </div>
                </button>
              ))}
            </div>
            <div className={s.dateEvidenceSummary}>
              <strong>Date evidence</strong>
              <span>{stats.embeddedDates.toLocaleString()} embedded</span>
              <span>{stats.filenameDates.toLocaleString()} from filenames</span>
              <span>{stats.noDate.toLocaleString()} missing</span>
              {stats.fileDate > 0 && <small>{stats.fileDate.toLocaleString()} missing dates have an optional file-timestamp estimate available in Organization Settings.</small>}
            </div>
          </>
        )}
        {done && error && (
          <div style={{ maxWidth: 620, margin: '24px auto', padding: 16, borderRadius: 10, background: '#FEF2F2', color: '#991B1B', textAlign: 'center' }}>
            <p>{error}</p>
            <button className={s.supportDiagnosticsButton} onClick={() => setShowDiagnosticConsent(true)}>Send diagnostics to developer</button>
          </div>
        )}
      </div>

      {done && (
        <div className={s.bottomBar}>
          <button className={s.btnSecondary} onClick={() => go('welcome')}>Change Folders</button>
          <button className={s.btnPrimary} disabled={!stats || stats.total === 0} onClick={() => go('settings')}>Configure Organization →</button>
        </div>
      )}

      {selectedCategory && (
        <CategoryModal
          card={selectedCategory}
          files={filesForCategory(selectedCategory.key, scannedFiles)}
          onClose={() => setSelectedCategory(null)}
        />
      )}

      {showDiagnosticConsent && (
        <div className={s.modalBackdrop} onMouseDown={event => { if (event.target === event.currentTarget) setShowDiagnosticConsent(false); }}>
          <section className={s.modalCard} role="dialog" aria-modal="true" aria-label="Send diagnostics to developer">
            <div className={s.modalHeader}><h2>Send diagnostics to developer?</h2><button onClick={() => setShowDiagnosticConsent(false)}>×</button></div>
            <div className={s.modalBody}>
              <div className={s.diagnosticPrivacyNotice}>
                <p>Foldiq will open your default email app with a short technical summary.</p>
                <ul>
                  <li>Includes the Foldiq version, Windows version, scan stages, timing, and error codes.</li>
                  <li>Does not include photos, filenames, or folder paths.</li>
                  <li>Nothing is sent until you review the email and press Send.</li>
                </ul>
              </div>
              <div className={s.modalActions}>
                <button className={s.btnSecondary} onClick={() => setShowDiagnosticConsent(false)}>Cancel</button>
                <button className={s.btnPrimary} disabled={creatingSupportEmail} onClick={createSupportEmail}>{creatingSupportEmail ? 'Opening email…' : 'Create support email'}</button>
              </div>
            </div>
          </section>
        </div>
      )}
    </div>
  );
}

function filesForCategory(key, files) {
  const photos = new Set(['.jpg','.jpeg','.png','.heic','.heif','.tiff','.tif','.webp','.cr2','.cr3','.nef','.arw','.dng','.raf','.orf','.rw2']);
  const videos = new Set(['.mov','.mp4','.m4v','.avi','.mkv']);
  if (key === 'photos') return files.filter(file => photos.has(file.ext));
  if (key === 'videos') return files.filter(file => videos.has(file.ext));
  if (key === 'dupes') return files.filter(file => file.isDuplicate);
  if (key === 'probDupes') return files.filter(file => file.probableMatchKind === 'same');
  if (key === 'similar') return files.filter(file => file.probableDuplicateGroupID && file.probableMatchKind !== 'same');
  if (key === 'noDate') return files.filter(file => !file.date);
  if (key === 'fileDate') return files.filter(file => !file.date && file.fileModifiedDate);
  if (key === 'zips') return files.filter(file => file.archiveSourcePath);
  return files;
}

function CategoryModal({ card, files, onClose }) {
  return (
    <div className={s.modalBackdrop} onMouseDown={event => { if (event.target === event.currentTarget) onClose(); }}>
      <section className={s.modalCard} role="dialog" aria-modal="true" aria-label={card.label}>
        <div className={s.modalHeader}><h2>{card.label} — {files.length.toLocaleString()}</h2><button onClick={onClose}>×</button></div>
        <div className={s.modalBody}>
          {card.key === 'probDupes' && (
            <div className={s.diagnosticPrivacyNotice}>
              <p><strong>Same Image compares photo content locally.</strong></p>
              <p>The best copy stays organized; other strong copies follow your Duplicate handling setting.</p>
            </div>
          )}
          {card.key === 'similar' && (
            <div className={s.diagnosticPrivacyNotice}>
              <p><strong>Bursts, edited versions, and visually similar photos.</strong></p>
              <p>These suggestions are always Review only. Foldiq never separates or moves them automatically.</p>
            </div>
          )}
          <div className={s.scanFileDrilldown}>
            {files.length === 0 && <p>No matching files.</p>}
            {files.slice(0, 500).map(file => (
              <button key={file.path} onClick={() => window.foldiq.revealFile(file.archiveSourcePath || file.path)}>
                <strong>{file.name}</strong>
                <span>{file.probableDuplicateGroupID
                  ? `${matchKindLabel(file)} · ${file.probableMatchScore}% · ${file.probableMatchReasons}`
                  : file.path}</span>
              </button>
            ))}
            {files.length > 500 && <p>Showing the first 500 files.</p>}
          </div>
          <div className={s.modalActions}><button className={s.btnPrimary} onClick={onClose}>Done</button></div>
        </div>
      </section>
    </div>
  );
}

function formatDuration(milliseconds) {
  const seconds = Math.max(0, Math.floor(milliseconds / 1000));
  const minutes = Math.floor(seconds / 60);
  return `${minutes}:${String(seconds % 60).padStart(2, '0')}`;
}

function StatIcon({ name, color }) {
  const p = { width: 22, height: 22, fill: 'none', stroke: color, strokeWidth: 1.8, strokeLinecap: 'round', strokeLinejoin: 'round' };
  const icons = {
    photos:    <svg {...p}><rect x="3" y="3" width="18" height="18" rx="2"/><circle cx="8.5" cy="8.5" r="1.5"/><polyline points="21 15 16 10 5 21"/></svg>,
    videos:    <svg {...p}><polygon points="23 7 16 12 23 17 23 7"/><rect x="1" y="5" width="15" height="14" rx="2"/></svg>,
    zips:      <svg {...p}><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/><line x1="12" y1="12" x2="12" y2="18"/><line x1="9" y1="15" x2="15" y2="15"/></svg>,
    dupes:     <svg {...p}><rect x="8" y="8" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>,
    probDupes: <svg {...p}><circle cx="12" cy="12" r="10"/><line x1="8" y1="12" x2="16" y2="12"/></svg>,
    similar:   <svg {...p}><rect x="3" y="5" width="14" height="14" rx="2"/><path d="M8 5V3h13v14h-4"/><circle cx="8" cy="10" r="1"/><path d="m5 17 4-4 2 2 2-2 4 4"/></svg>,
    noDate:    <svg {...p}><circle cx="12" cy="12" r="10"/><line x1="12" y1="8" x2="12" y2="12"/><line x1="12" y1="16" x2="12.01" y2="16"/></svg>,
    noMeta:    <svg {...p}><circle cx="12" cy="12" r="10"/><line x1="12" y1="8" x2="12" y2="12"/><line x1="12" y1="16" x2="12.01" y2="16"/></svg>,
    fileDate:  <svg {...p}><circle cx="12" cy="12" r="9"/><polyline points="12 7 12 12 16 14"/></svg>,
    total:     <svg {...p}><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/><line x1="16" y1="13" x2="8" y2="13"/><line x1="16" y1="17" x2="8" y2="17"/><polyline points="10 9 9 9 8 9"/></svg>,
  };
  return icons[name] || null;
}

function matchKindLabel(file) {
  if (file.probableMatchKind === 'same') return file.isProbableDuplicate ? 'Same image' : 'Best copy';
  if (file.probableMatchKind === 'burst') return 'Burst · Review only';
  if (file.probableMatchKind === 'edited') return 'Edited version · Review only';
  return 'Visually similar · Review only';
}
