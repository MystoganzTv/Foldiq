import { useEffect, useMemo, useRef, useState } from 'react';
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
  const [openingSupportForm, setOpeningSupportForm] = useState(false);
  const [diagnosticsCopied, setDiagnosticsCopied] = useState(false);
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

  async function openSupportForm() {
    setOpeningSupportForm(true);
    try {
      await window.foldiq.openDiagnosticsForm();
      setShowDiagnosticConsent(false);
    } finally {
      setOpeningSupportForm(false);
    }
  }

  async function copyDiagnostics() {
    await window.foldiq.copyDiagnostics();
    setDiagnosticsCopied(true);
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
  const phaseDescription = {
    cleanup: 'Preparing a safe temporary workspace…',
    archive: 'Opening compressed media without changing the originals…',
    'archive-list': 'Checking the extracted media list…',
    indexing: 'Finding supported photos and videos…',
    metadata: 'Reading capture dates in efficient batches…',
    duplicates: 'Verifying possible exact copies…',
    similarity: 'Comparing likely bursts and edited versions…',
    finalizing: 'Preparing your scan results…',
  }[progress.phase] || 'Reading your selected media…';

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
                : phaseDescription}
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
          onKeepPhotos={decisions => {
            const updated = scannedFiles.map(file => {
              const decision = decisions.find(item => item.exact
                ? file.duplicateGroupID === item.groupID
                : file.probableDuplicateGroupID === item.groupID);
              if (!decision) return file;
              if (decision.mode === 'untouched') {
                return { ...file, userExcluded: true, userSetAside: false };
              }
              if (decision.mode === 'all') {
                return {
                  ...file,
                  userExcluded: false,
                  userSetAside: false,
                  ...(decision.exact ? { isDuplicate: false } : { isProbableDuplicate: false }),
                };
              }
              const setAside = file.path !== decision.keepPath;
              return {
                ...file,
                userExcluded: false,
                userSetAside: setAside,
                ...(decision.exact ? { isDuplicate: setAside } : { isProbableDuplicate: setAside }),
              };
            });
            setScannedFiles(updated);
            setFiles(updated);
          }}
          onClose={() => setSelectedCategory(null)}
        />
      )}

      {showDiagnosticConsent && (
        <div className={s.modalBackdrop} onMouseDown={event => { if (event.target === event.currentTarget) setShowDiagnosticConsent(false); }}>
          <section className={s.modalCard} role="dialog" aria-modal="true" aria-label="Send diagnostics to developer">
            <div className={s.modalHeader}><h2>Send diagnostics to developer?</h2><button onClick={() => setShowDiagnosticConsent(false)}>×</button></div>
            <div className={s.modalBody}>
              <div className={s.diagnosticPrivacyNotice}>
                <p>Foldiq will open a secure support form in your web browser. No email app or Outlook account is required.</p>
                <ul>
                  <li>Includes the Foldiq version, Windows version, scan stages, timing, and error codes.</li>
                  <li>Does not include photos, filenames, or folder paths.</li>
                  <li>The same private diagnostic summary is copied to your clipboard as a backup.</li>
                  <li>Nothing is sent until you review the form and press Send.</li>
                </ul>
              </div>
              <div className={s.modalActions}>
                <button className={s.btnSecondary} onClick={copyDiagnostics}>{diagnosticsCopied ? 'Copied ✓' : 'Copy diagnostics'}</button>
                <button className={s.btnSecondary} onClick={() => setShowDiagnosticConsent(false)}>Cancel</button>
                <button className={s.btnPrimary} disabled={openingSupportForm} onClick={openSupportForm}>{openingSupportForm ? 'Opening form…' : 'Open support form'}</button>
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
  if (key === 'dupes') return files.filter(file => file.duplicateGroupID);
  if (key === 'probDupes') return files.filter(file => file.probableMatchKind === 'same');
  if (key === 'similar') return files.filter(file => file.probableDuplicateGroupID && file.probableMatchKind !== 'same');
  if (key === 'noDate') return files.filter(file => !file.date);
  if (key === 'zips') return files.filter(file => file.archiveSourcePath);
  return files;
}

function CategoryModal({ card, files, onClose, onKeepPhotos }) {
  const comparisonMode = card.key === 'dupes' || card.key === 'probDupes' || card.key === 'similar';
  const groups = useMemo(() => {
    if (!comparisonMode) return [];
    const grouped = new Map();
    for (const file of files) {
      const groupID = card.key === 'dupes' ? file.duplicateGroupID : file.probableDuplicateGroupID;
      if (!groupID) continue;
      if (!grouped.has(groupID)) grouped.set(groupID, []);
      grouped.get(groupID).push(file);
    }
    return Array.from(grouped, ([id, groupFiles]) => ({
      id,
      files: groupFiles.sort((left, right) => left.name.localeCompare(right.name)),
    })).filter(group => group.files.length > 1)
      .sort((left, right) => left.files[0].name.localeCompare(right.files[0].name));
  }, [card.key, comparisonMode, files]);
  const [selectedGroupID, setSelectedGroupID] = useState(null);
  const [selectedFilePath, setSelectedFilePath] = useState(null);
  const [zoom, setZoom] = useState(1);
  const selectedGroup = groups.find(group => group.id === selectedGroupID) || groups[0];
  const sortedReferenceFiles = selectedGroup ? [...selectedGroup.files].sort((left, right) => {
    const leftDate = new Date(left.date || left.fileModifiedDate || 8640000000000000).getTime();
    const rightDate = new Date(right.date || right.fileModifiedDate || 8640000000000000).getTime();
    return leftDate - rightDate || left.name.localeCompare(right.name);
  }) : [];
  const reference = card.key === 'dupes'
    ? selectedGroup?.files.find(file => !file.isDuplicate) || selectedGroup?.files[0]
    : card.key === 'probDupes'
      ? selectedGroup?.files.find(file => !file.isProbableDuplicate) || selectedGroup?.files[0]
      : selectedGroup?.files.some(file => file.userSetAside)
        ? selectedGroup.files.find(file => !file.userSetAside) || sortedReferenceFiles[0]
        : sortedReferenceFiles[0];
  const candidates = selectedGroup?.files.filter(file => file.path !== reference?.path) || [];
  const candidate = candidates.find(file => file.path === selectedFilePath) || candidates[0];

  useEffect(() => {
    if (!selectedGroupID && groups[0]) setSelectedGroupID(groups[0].id);
  }, [groups, selectedGroupID]);

  function chooseGroup(group) {
    setSelectedGroupID(group.id);
    setSelectedFilePath(null);
    setZoom(1);
  }

  function keepPhoto(file) {
    if (!selectedGroup) return;
    onKeepPhotos([{ mode: 'one', groupID: selectedGroup.id, keepPath: file.path, exact: card.key === 'dupes' }]);
  }

  function isKept(file) {
    if (!selectedGroup) return false;
    if (selectedGroup.files.every(item => item.userExcluded)) return false;
    if (selectedGroup.files.some(item => item.userSetAside)) return !file.userSetAside;
    if (card.key === 'dupes') return !file.isDuplicate;
    if (card.key === 'probDupes') return !file.isProbableDuplicate;
    return false;
  }

  function keepRecommendedInAllGroups() {
    const decisions = groups.map(group => {
      const recommended = card.key === 'dupes'
        ? group.files.find(file => !file.isDuplicate) || group.files[0]
        : card.key === 'probDupes'
          ? group.files.find(file => !file.isProbableDuplicate) || group.files[0]
          : [...group.files].sort((left, right) => (right.pixelWidth || 0) * (right.pixelHeight || 0) - (left.pixelWidth || 0) * (left.pixelHeight || 0) || (right.size || 0) - (left.size || 0))[0];
      return { mode: 'one', groupID: group.id, keepPath: recommended.path, exact: card.key === 'dupes' };
    });
    onKeepPhotos(decisions);
  }

  function keepAll() {
    if (!selectedGroup) return;
    onKeepPhotos([{ mode: 'all', groupID: selectedGroup.id, exact: card.key === 'dupes' }]);
  }

  function leaveGroupUntouched() {
    if (!selectedGroup) return;
    onKeepPhotos([{ mode: 'untouched', groupID: selectedGroup.id, exact: card.key === 'dupes' }]);
  }

  const groupUntouched = selectedGroup?.files.every(file => file.userExcluded) || false;
  const allKept = selectedGroup?.files.every(file => !file.userExcluded && !file.userSetAside && (
    card.key === 'dupes' ? !file.isDuplicate : !file.isProbableDuplicate
  )) || false;
  const decisionSummary = groupUntouched
    ? 'This group will stay exactly where it is.'
    : allKept
      ? 'All photos in this group will be organized.'
      : 'Unwanted copies go to Duplicates / To Review. Nothing is deleted.';

  return (
    <div className={s.modalBackdrop} onMouseDown={event => { if (event.target === event.currentTarget) onClose(); }}>
      <section className={`${s.modalCard} ${comparisonMode ? s.comparisonModalCard : ''}`} role="dialog" aria-modal="true" aria-label={card.label}>
        <div className={s.modalHeader}><h2>{card.label} — {comparisonMode ? `${groups.length.toLocaleString()} groups · ${files.length.toLocaleString()} photos` : files.length.toLocaleString()}</h2><button onClick={onClose}>×</button></div>
        <div className={s.modalBody}>
          {card.key === 'probDupes' && (
            <div className={s.diagnosticPrivacyNotice}>
              <p><strong>Same Image compares photo content locally.</strong></p>
              <p>Choose the photo to keep. The others go to Duplicates / To Review, where Undo can restore them.</p>
            </div>
          )}
          {card.key === 'dupes' && (
            <div className={s.diagnosticPrivacyNotice}>
              <p><strong>These copies are exactly identical.</strong></p>
              <p>Choose one to keep. The others go to a safe review folder; nothing is permanently deleted.</p>
            </div>
          )}
          {card.key === 'similar' && (
            <div className={s.diagnosticPrivacyNotice}>
              <p><strong>Bursts, edited versions, and visually similar photos.</strong></p>
              <p>Keep one, keep all, or leave this group completely untouched.</p>
            </div>
          )}
          {card.key === 'noDate' && (
            <div className={s.diagnosticPrivacyNotice}>
              <p><strong>Foldiq could not determine when these photos were taken.</strong></p>
              <p>They will stay in Unknown Date unless you assign the real date in Preview.</p>
            </div>
          )}
          {comparisonMode ? (
            <div className={s.comparisonWorkspace}>
              <aside className={s.comparisonGroups}>
                <button className={s.comparisonBulkButton} onClick={keepRecommendedInAllGroups}>Use all recommendations</button>
                {groups.map(group => (
                  <button key={group.id} className={selectedGroup?.id === group.id ? s.comparisonGroupSelected : ''} onClick={() => chooseGroup(group)}>
                    <strong>{group.files[0].name}</strong>
                    <span>{group.files.length} photos</span>
                  </button>
                ))}
              </aside>
              <div className={s.comparisonMain}>
                <div className={s.comparisonToolbar}>
                  <strong className={card.key === 'similar' ? s.reviewOnlyText : s.verifiedText}>
                    {card.key === 'dupes' ? '● Exact copies' : card.key === 'similar' ? '● You decide' : '● Same image'}
                  </strong>
                  <label>{zoom > 1 ? 'Drag photos to inspect' : 'Synchronized zoom'}</label>
                  <input type="range" min="1" max="3" step="0.25" value={zoom} onChange={event => setZoom(Number(event.target.value))} />
                  <span>{zoom.toFixed(2)}×</span>
                </div>
                {reference && candidate ? (
                  <>
                    <div className={s.comparisonStage}>
                      <ComparisonPhotoCard file={reference} title="Recommended" tone="green" zoom={zoom} kept={isKept(reference)} onKeep={() => keepPhoto(reference)} />
                      <ComparisonPhotoCard file={candidate} title={card.key === 'similar' ? matchKindLabel(candidate) : 'Other copy'} tone={card.key === 'similar' ? 'orange' : 'yellow'} zoom={zoom} kept={isKept(candidate)} onKeep={() => keepPhoto(candidate)} />
                    </div>
                    {candidates.length > 1 && (
                      <div className={s.comparisonFilmstrip}>
                        <small>Compare another photo in this group</small>
                        <div>{candidates.map(file => (
                          <ComparisonFilmstripButton key={file.path} file={file} selected={candidate.path === file.path} onClick={() => { setSelectedFilePath(file.path); setZoom(1); }} />
                        ))}</div>
                      </div>
                    )}
                    <div className={s.comparisonDecisionActions}>
                      <button className={allKept ? s.comparisonDecisionSelected : ''} onClick={keepAll}>
                        {selectedGroup.files.length === 2 ? 'Keep both' : 'Keep all'}
                      </button>
                      <button className={groupUntouched ? s.comparisonDecisionSelected : ''} onClick={leaveGroupUntouched}>Leave group untouched</button>
                    </div>
                    <p className={s.comparisonSafety}>{decisionSummary}</p>
                  </>
                ) : <p className={s.comparisonEmpty}>No comparison group is available.</p>}
              </div>
            </div>
          ) : (
            <div className={s.scanFileDrilldown}>
              {files.length === 0 && <p>No matching files.</p>}
              {files.slice(0, 500).map(file => (
                <button key={file.path} onClick={() => window.foldiq.revealFile(file.archiveSourcePath || file.path)}>
                  <strong>{file.name}</strong>
                  <span className={card.key === 'noDate' ? s.fileDateEstimate : ''}>
                    {card.key === 'noDate'
                      ? 'Date unknown'
                      : file.path}
                  </span>
                </button>
              ))}
              {files.length > 500 && <p>Showing the first 500 files.</p>}
            </div>
          )}
          <div className={s.modalActions}><button className={s.btnPrimary} onClick={onClose}>Done</button></div>
        </div>
      </section>
    </div>
  );
}

function ComparisonPhotoCard({ file, title, tone, zoom, kept, onKeep }) {
  const [thumbnail, setThumbnail] = useState(undefined);
  const [pan, setPan] = useState({ x: 0, y: 0 });
  const [dragging, setDragging] = useState(false);
  const frameRef = useRef(null);
  const imageRef = useRef(null);
  const dragRef = useRef(null);
  const suppressClickRef = useRef(false);

  function clampPan(next) {
    const frame = frameRef.current;
    const image = imageRef.current;
    if (!frame || !image || zoom <= 1) return { x: 0, y: 0 };
    const rect = frame.getBoundingClientRect();
    const imageRatio = image.naturalWidth / Math.max(image.naturalHeight, 1);
    const frameRatio = rect.width / Math.max(rect.height, 1);
    const renderedWidth = imageRatio > frameRatio ? rect.width : rect.height * imageRatio;
    const renderedHeight = imageRatio > frameRatio ? rect.width / imageRatio : rect.height;
    const maxX = Math.max(0, (renderedWidth * zoom - rect.width) / 2);
    const maxY = Math.max(0, (renderedHeight * zoom - rect.height) / 2);
    return {
      x: Math.min(Math.max(next.x, -maxX), maxX),
      y: Math.min(Math.max(next.y, -maxY), maxY),
    };
  }

  useEffect(() => {
    let active = true;
    setThumbnail(undefined);
    setPan({ x: 0, y: 0 });
    window.foldiq.getThumbnail(file.path).then(value => { if (active) setThumbnail(value); });
    return () => { active = false; };
  }, [file.path]);

  useEffect(() => {
    setPan(current => clampPan(current));
  }, [zoom]);

  function beginPan(event) {
    if (zoom <= 1 || !thumbnail) return;
    event.preventDefault();
    event.currentTarget.setPointerCapture(event.pointerId);
    dragRef.current = { startX: event.clientX, startY: event.clientY, origin: pan, moved: false };
    setDragging(true);
  }

  function movePan(event) {
    if (!dragRef.current) return;
    const dx = event.clientX - dragRef.current.startX;
    const dy = event.clientY - dragRef.current.startY;
    if (Math.abs(dx) + Math.abs(dy) > 3) dragRef.current.moved = true;
    setPan(clampPan({ x: dragRef.current.origin.x + dx, y: dragRef.current.origin.y + dy }));
  }

  function endPan() {
    if (dragRef.current?.moved) suppressClickRef.current = true;
    dragRef.current = null;
    setDragging(false);
  }

  function openOriginal() {
    if (suppressClickRef.current) {
      suppressClickRef.current = false;
      return;
    }
    window.foldiq.revealFile(file.path);
  }

  return (
    <section className={`${s.comparisonPhotoCard} ${s[`comparisonTone${tone}`] || ''}`}>
      <header><strong>{title}</strong>{file.probableMatchScore > 0 && <span>{file.probableMatchScore}%</span>}</header>
      <button
        ref={frameRef}
        className={`${s.comparisonImage} ${zoom > 1 ? s.comparisonImagePannable : ''} ${dragging ? s.comparisonImageDragging : ''}`}
        onClick={openOriginal}
        onPointerDown={beginPan}
        onPointerMove={movePan}
        onPointerUp={endPan}
        onPointerCancel={endPan}
        title={zoom > 1 ? 'Drag to move around the zoomed photo' : 'Show original file'}
      >
        {thumbnail === undefined && <i className={s.comparisonLoader} />}
        {thumbnail && <img ref={imageRef} src={thumbnail} alt={file.name} draggable="false" style={{ transform: `translate(${pan.x}px, ${pan.y}px) scale(${zoom})` }} />}
        {thumbnail === null && <span>Preview unavailable</span>}
      </button>
      <strong className={s.comparisonFilename}>{file.name}</strong>
      <small>{formatComparisonMetadata(file)}</small>
      <button className={`${s.comparisonKeepButton} ${kept ? s.comparisonKeepButtonSelected : ''}`} onClick={onKeep}>
        {kept ? '✓ Keeping this photo' : 'Keep this photo'}
      </button>
    </section>
  );
}

function ComparisonFilmstripButton({ file, selected, onClick }) {
  const [thumbnail, setThumbnail] = useState(undefined);
  useEffect(() => {
    let active = true;
    window.foldiq.getThumbnail(file.path).then(value => { if (active) setThumbnail(value); });
    return () => { active = false; };
  }, [file.path]);
  return <button className={selected ? s.comparisonFilmstripSelected : ''} onClick={onClick} title={file.name}>
    {thumbnail ? <img src={thumbnail} alt="" draggable="false" /> : <span>▧</span>}
    <small>{file.name}</small>
  </button>;
}

function formatComparisonMetadata(file) {
  const fields = [formatBytes(file.size)];
  if (file.pixelWidth && file.pixelHeight) fields.push(`${file.pixelWidth}×${file.pixelHeight}`);
  if (file.date) fields.push(new Date(file.date).toLocaleDateString());
  else fields.push('No embedded date');
  return fields.join(' · ');
}

function formatBytes(value) {
  const bytes = Number(value) || 0;
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(0)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
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
  if (file.probableMatchKind === 'burst') return 'Burst';
  if (file.probableMatchKind === 'edited') return 'Edited version';
  return 'Visually similar';
}
