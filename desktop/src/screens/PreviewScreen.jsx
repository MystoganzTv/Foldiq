import { useEffect, useMemo, useState } from 'react';
import s from './Screen.module.css';

const FILTERS = [
  ['all', 'All'],
  ['included', 'Ready'],
  ['excluded', 'Left alone'],
  ['skipped', 'Duplicates'],
  ['unknown', 'Missing date'],
];

function formatBytes(bytes = 0) {
  if (bytes >= 1e9) return `${(bytes / 1e9).toFixed(1)} GB`;
  if (bytes >= 1e6) return `${(bytes / 1e6).toFixed(1)} MB`;
  if (bytes >= 1e3) return `${(bytes / 1e3).toFixed(0)} KB`;
  return `${bytes} B`;
}

function formatDate(value) {
  if (!value) return 'Unknown';
  const date = new Date(value);
  return Number.isNaN(date.getTime())
    ? 'Unknown'
    : new Intl.DateTimeFormat(undefined, { year: 'numeric', month: 'short', day: 'numeric' }).format(date);
}

function dateInputValue(value) {
  if (!value) return '';
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return '';
  const pad = number => String(number).padStart(2, '0');
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
}

function dateSourceLabel(source) {
  const labels = {
    'camera metadata': 'Camera metadata',
    'video metadata': 'Video metadata',
    'embedded metadata': 'Embedded creation metadata',
    filename: 'Date encoded in filename',
    'Google Takeout': 'Google Photos export (Takeout .json)',
    manual: 'Corrected by you',
  };
  return labels[source] || 'No reliable capture date';
}

function pathParts(value = '') {
  return value.split(/[\\/]+/).filter(Boolean);
}

function fileKey(file) {
  return `${file.id ?? ''}:${file.path ?? ''}`;
}

function isUnknownDate(file) {
  return /(?:^|[\\/])Unknown Date(?:[\\/]|$)/i.test(file.destPath || '');
}

function friendlyDestination(file, outputFolder) {
  if (!file.destPath) return 'No destination — skipped automatically';

  const destination = pathParts(file.destPath);
  const root = pathParts(outputFolder);
  const rootMatches = root.length > 0 && root.every(
    (part, index) => destination[index]?.toLowerCase() === part.toLowerCase(),
  );
  const relative = rootMatches ? destination.slice(root.length, -1) : destination.slice(-4, -1);
  return relative.length > 0 ? relative.join('  ›  ') : 'Organized library';
}

function sourceFolder(file) {
  const parts = pathParts(file.archiveSourcePath || file.path);
  return parts.slice(0, -1).join('  ›  ');
}

function skipReason(file) {
  if (file.reason === 'user-choice') return 'Left alone by your choice';
  if (file.reason === 'duplicate') return 'Exact duplicate';
  return 'Skipped automatically';
}

function buildFolderTree(files, outputFolder) {
  const rootName = pathParts(outputFolder).at(-1) || 'Organized Library';
  const root = { name: rootName, count: 0, children: new Map() };

  for (const file of files) {
    if (!file.destPath) continue;
    const destination = pathParts(file.destPath);
    const output = pathParts(outputFolder);
    const rootMatches = output.length > 0 && output.every(
      (part, index) => destination[index]?.toLowerCase() === part.toLowerCase(),
    );
    const folders = (rootMatches ? destination.slice(output.length, -1) : destination.slice(-5, -1));
    root.count += 1;
    let cursor = root;
    for (const folder of folders) {
      if (!cursor.children.has(folder)) {
        cursor.children.set(folder, { name: folder, count: 0, children: new Map() });
      }
      cursor = cursor.children.get(folder);
      cursor.count += 1;
    }
  }
  return root;
}

export default function PreviewScreen({ go, files, config, plan, setPlan }) {
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [filter, setFilter] = useState('all');
  const [search, setSearch] = useState('');
  const [sort, setSort] = useState('source');
  const [selectedKey, setSelectedKey] = useState(null);
  const [showTree, setShowTree] = useState(false);
  const [showPreflight, setShowPreflight] = useState(false);
  const [dateUpdatingKey, setDateUpdatingKey] = useState(null);
  const [planProgress, setPlanProgress] = useState(null);
  const [locationWarning, setLocationWarning] = useState('');

  useEffect(() => {
    let active = true;
    window.foldiq.onPlanProgress(progress => {
      if (!active) return;
      if (progress.warning) setLocationWarning(progress.warning);
      setPlanProgress(progress);
    });
    window.foldiq.buildPlan(files, config)
      .then(nextPlan => {
        if (!active) return;
        setPlan(nextPlan);
        setSelectedKey(nextPlan.length > 0 ? fileKey(nextPlan[0]) : null);
        setLoading(false);
      })
      .catch(err => {
        if (!active) return;
        setError(err?.message || 'Foldiq could not build the preview.');
        setLoading(false);
      });
    return () => {
      active = false;
      window.foldiq.removeAllListeners('plan:progress');
    };
  }, [files, config, setPlan]);

  const candidates = useMemo(() => plan.filter(file => file.action !== 'skip'), [plan]);
  const included = useMemo(() => candidates.filter(file => file.included !== false), [candidates]);
  const excluded = useMemo(() => plan.filter(file => file.action === 'skip' || file.included === false), [plan]);
  const skipped = useMemo(() => plan.filter(file => file.action === 'skip'), [plan]);
  const duplicates = useMemo(() => plan.filter(file => (
    file.action === 'skip' && file.reason === 'duplicate'
  ) || /(?:^|[\\/])Duplicates(?:[\\/]|$)/i.test(file.destPath || '')), [plan]);
  const unknown = useMemo(() => plan.filter(isUnknownDate), [plan]);
  const moves = useMemo(() => included.filter(file => file.action === 'move'), [included]);
  const copies = useMemo(() => included.filter(file => file.action === 'copy'), [included]);
  const selected = useMemo(
    () => plan.find(file => fileKey(file) === selectedKey) || null,
    [plan, selectedKey],
  );

  const visible = useMemo(() => {
    let result = plan;
    if (filter === 'included') result = included;
    if (filter === 'excluded') result = excluded;
    if (filter === 'skipped') result = duplicates;
    if (filter === 'unknown') result = unknown;

    const query = search.trim().toLowerCase();
    if (query) {
      result = result.filter(file => (
        file.name?.toLowerCase().includes(query) ||
        file.path?.toLowerCase().includes(query) ||
        file.destPath?.toLowerCase().includes(query)
      ));
    }

    return [...result].sort((left, right) => {
      if (sort === 'destination') return (left.destPath || '').localeCompare(right.destPath || '');
      if (sort === 'status') {
        const status = file => file.action === 'skip' ? 2 : file.included === false ? 1 : 0;
        return status(left) - status(right) || left.name.localeCompare(right.name);
      }
      return (left.path || left.name).localeCompare(right.path || right.name);
    });
  }, [filter, included, excluded, skipped, unknown, plan, search, sort]);

  const filterCounts = {
    all: plan.length,
    included: included.length,
    excluded: excluded.length,
    skipped: duplicates.length,
    unknown: unknown.length,
  };
  const actionableVisible = visible.filter(file => file.action !== 'skip');
  const allVisibleIncluded = actionableVisible.length > 0 && actionableVisible.every(file => file.included !== false);
  const resultsLabel = filter === 'all' && !search.trim() ? 'files' : 'matching files';

  function setIncluded(file, value) {
    if (file.action === 'skip') return;
    const key = fileKey(file);
    setPlan(current => current.map(item => (
      fileKey(item) === key ? { ...item, included: value } : item
    )));
  }

  function setAllVisible(value) {
    const visibleKeys = new Set(visible.filter(file => file.action !== 'skip').map(fileKey));
    setPlan(current => current.map(item => (
      visibleKeys.has(fileKey(item)) ? { ...item, included: value } : item
    )));
  }

  async function correctDate(file, value) {
    const key = fileKey(file);
    const parts = value ? value.split('-').map(Number) : [];
    const corrected = value && parts.length === 3
      ? new Date(parts[0], parts[1] - 1, parts[2], 12, 0, 0)
      : null;
    const inclusion = new Map(plan.map(item => [fileKey(item), item.included]));
    const editedFiles = plan.map(item => (
      fileKey(item) === key
        ? { ...item, date: corrected?.toISOString() ?? null, dateSource: corrected ? 'manual' : null, dateTag: null, dateEstimated: false }
        : item
    ));

    setDateUpdatingKey(key);
    try {
      const rebuilt = await window.foldiq.buildPlan(editedFiles, config);
      setPlan(rebuilt.map(item => ({ ...item, included: inclusion.get(fileKey(item)) ?? item.included })));
    } catch (dateError) {
      setError(dateError?.message || 'Foldiq could not update that date.');
    } finally {
      setDateUpdatingKey(null);
    }
  }

  return (
    <div className={s.screen}>
      <div className={s.previewHeader}>
        <div>
          <h1 className={s.title}>Review your photos</h1>
          <p className={s.sub}>Uncheck anything you want to leave alone. Nothing has changed yet.</p>
        </div>
        {!loading && !error && (
          <div className={s.previewHeaderDestination} title={config.outputFolder}>
            <span>Organized library</span>
            <strong>{pathParts(config.outputFolder).at(-1) || config.outputFolder}</strong>
          </div>
        )}
      </div>

      {loading && (
        <div className={s.centerBlock}>
          <div className={s.planningOrb}><span /></div>
          <h2 className={s.loadingTitle}>Building a safe plan…</h2>
          <div className={`${s.progressBar} ${s.indeterminateBar}`} style={{ width: 380 }}><div /></div>
          <p className={s.sub}>
            {planProgress?.phase === 'locations' && planProgress.total > 0
              ? `Naming GPS locations ${Number(planProgress.current || 0).toLocaleString()} of ${Number(planProgress.total).toLocaleString()}…`
              : 'Comparing source paths, dates, duplicates, and destinations.'}
          </p>
        </div>
      )}

      {!loading && error && (
        <div className={s.centerBlock}>
          <div className={s.errorTitle}>Preview could not be created</div>
          <p className={s.sub}>{error}</p>
          <button className={s.btnSecondary} onClick={() => go('settings')}>Back to settings</button>
        </div>
      )}

      {!loading && !error && (
        <>
          {locationWarning && <div className={s.previewWarning}>{locationWarning}</div>}
          <div className={s.previewContent}>
            <div className={s.previewToolbarTop}>
              <div className={s.previewStatsInline}>
                <PlanStat icon="✓" value={included.length} label="ready" tone="green" />
                <PlanStat icon="−" value={excluded.length} label="left alone" tone="neutral" />
                {duplicates.length > 0 && <PlanStat icon="⊘" value={duplicates.length} label="set aside" tone="orange" />}
                {unknown.length > 0 && <PlanStat icon="?" value={unknown.length} label="need dates" tone="yellow" />}
              </div>
              <div className={s.previewTools}>
                <button className={s.iconToolBtn} onClick={() => setShowTree(true)} title="Preview folder structure" aria-label="Preview folder structure">▦</button>
                <input
                  className={s.previewSearch}
                  value={search}
                  onChange={event => setSearch(event.target.value)}
                  placeholder="Search photos…"
                  aria-label="Search photos"
                />
              </div>
            </div>

            <div className={s.previewToolbar}>
              <div className={s.filterRow}>
                {FILTERS.map(([id, label]) => (
                  <button
                    key={id}
                    className={`${s.filterBtn} ${filter === id ? s.active : ''}`}
                    onClick={() => setFilter(id)}
                  >
                    {label} <span>{filterCounts[id].toLocaleString()}</span>
                  </button>
                ))}
              </div>
              <div className={s.previewBulkActions}>
                <select value={sort} onChange={event => setSort(event.target.value)} aria-label="Sort preview">
                  <option value="source">Sort: Photo</option>
                  <option value="destination">Sort: Folder</option>
                  <option value="status">Sort: Status</option>
                </select>
                {actionableVisible.length > 0 && (
                  <button
                    onClick={() => setAllVisible(!allVisibleIncluded)}
                    title={allVisibleIncluded
                      ? 'These files will be left exactly where they are.'
                      : 'These files will be processed using the planned destinations.'}
                  >
                    {allVisibleIncluded ? 'Keep' : 'Organize'} {actionableVisible.length.toLocaleString()} {resultsLabel} {allVisibleIncluded ? 'untouched' : ''}
                  </button>
                )}
              </div>
            </div>

            <div className={s.previewWorkspace}>
              <div className={s.previewTablePane}>
                <div className={s.previewTableHeader}>
                  <span />
                  <span>Photo</span>
                  <span>Will go to</span>
                </div>
                <div className={s.fileList}>
                  {visible.length === 0 && <div className={s.previewEmpty}>No files match these filters.</div>}
                  {visible.slice(0, 500).map((file, index) => {
                    const automaticSkip = file.action === 'skip';
                    const fileIncluded = !automaticSkip && file.included !== false;
                    const active = fileKey(file) === selectedKey;
                    return (
                      <div
                        key={fileKey(file)}
                        className={`${s.fileRow} ${!fileIncluded ? s.fileRowExcluded : ''} ${active ? s.fileRowSelected : ''}`}
                        onClick={() => setSelectedKey(fileKey(file))}
                        style={{ animationDelay: `${Math.min(index * 12, 180)}ms` }}
                        role="button"
                        tabIndex={0}
                        onKeyDown={event => {
                          if (event.key === 'Enter' || event.key === ' ') setSelectedKey(fileKey(file));
                        }}
                      >
                        <label className={s.previewCheckbox} title={automaticSkip ? skipReason(file) : 'Organize this file'} onClick={event => event.stopPropagation()}>
                          <input
                            type="checkbox"
                            checked={fileIncluded}
                            disabled={automaticSkip}
                            onChange={event => setIncluded(file, event.target.checked)}
                            aria-label={`Organize ${file.name}`}
                          />
                          <span />
                        </label>
                        <div className={s.fileSourceCell}>
                          <span className={s.fileTypeIcon}>{(file.ext || '').replace('.', '').slice(0, 4).toUpperCase() || 'FILE'}</span>
                          <div>
                            <strong title={file.name}>{file.name}</strong>
                            <small>{formatBytes(file.size)}{file.date ? ` · ${formatDate(file.date)}` : ' · Date unknown'}</small>
                          </div>
                        </div>
                        <div className={s.fileDestinationCell}>
                          <strong title={file.destPath || ''}>{automaticSkip ? skipReason(file) : friendlyDestination(file, config.outputFolder)}</strong>
                        </div>
                      </div>
                    );
                  })}
                  {visible.length > 500 && <div className={s.moreRow}>…and {(visible.length - 500).toLocaleString()} more</div>}
                </div>
              </div>

              {selected && (
                <PreviewInspector
                  file={selected}
                  outputFolder={config.outputFolder}
                  onClose={() => setSelectedKey(null)}
                  onToggle={() => setIncluded(selected, selected.included === false)}
                  onCorrectDate={value => correctDate(selected, value)}
                  dateUpdating={dateUpdatingKey === fileKey(selected)}
                />
              )}
            </div>
          </div>

          <div className={s.bottomBar}>
            <button className={s.btnSecondary} onClick={() => go('settings')}>← Back</button>
            <div className={s.previewFooterSummary}>
              <strong>{included.length.toLocaleString()} photos ready</strong>
              <span>{excluded.length.toLocaleString()} left alone</span>
            </div>
            <button className={s.btnPrimary} disabled={included.length === 0} onClick={() => setShowPreflight(true)}>
              Organize {included.length.toLocaleString()} Files →
            </button>
          </div>

          {showTree && (
            <Modal title="Planned folder structure" onClose={() => setShowTree(false)}>
              <p className={s.modalIntro}>This is the structure Foldiq will create. The original files are still untouched.</p>
              <div className={s.folderTree}>
                <TreeNode node={buildFolderTree(included, config.outputFolder)} depth={0} />
              </div>
              <div className={s.modalActions}><button className={s.btnPrimary} onClick={() => setShowTree(false)}>Done</button></div>
            </Modal>
          )}

          {showPreflight && (
            <Modal title={config.copyMode ? 'Review before copying' : 'Review before moving'} onClose={() => setShowPreflight(false)}>
              <p className={s.modalPath}>{config.outputFolder}</p>
              <div className={s.preflightStats}>
                <PlanStat icon="✓" value={included.length} label="files" tone="green" />
                {copies.length > 0 && <PlanStat icon="⧉" value={copies.length} label="copied" tone="blue" />}
                {moves.length > 0 && <PlanStat icon="→" value={moves.length} label="moved" tone="blue" />}
                <PlanStat icon="−" value={excluded.length} label="untouched" tone="neutral" />
                {unknown.length > 0 && <PlanStat icon="?" value={unknown.length} label="no date" tone="yellow" />}
              </div>
              <p className={s.preflightText}>
                {moves.length === 0
                  ? 'Foldiq will create organized copies. Originals and compressed archives stay in their current locations.'
                  : copies.length === 0
                    ? 'Foldiq will move the selected originals and create an internal undo manifest so the operation can be reversed.'
                    : `Foldiq will move ${moves.length.toLocaleString()} originals and copy ${copies.length.toLocaleString()} files extracted from archives. The compressed archives stay untouched.`}
              </p>
              <div className={s.modalActions}>
                <button className={s.btnSecondary} onClick={() => setShowPreflight(false)}>Cancel</button>
                <button className={s.btnPrimary} onClick={() => go('apply')}>
                  {config.copyMode ? 'Copy Files Now' : 'Move Files Now'} →
                </button>
              </div>
            </Modal>
          )}
        </>
      )}
    </div>
  );
}

function PlanStat({ icon, value, label, tone }) {
  return (
    <div className={`${s.planStat} ${s[`planStat_${tone}`] || ''}`}>
      <span className={s.planStatIcon}>{icon}</span>
      <div><strong>{Number.isFinite(value) ? value.toLocaleString() : value}</strong><small>{label}</small></div>
    </div>
  );
}

function PreviewInspector({ file, outputFolder, onClose, onToggle, onCorrectDate, dateUpdating }) {
  const [thumbnail, setThumbnail] = useState(undefined);

  useEffect(() => {
    let active = true;
    setThumbnail(undefined);
    window.foldiq.getThumbnail(file.path)
      .then(value => { if (active) setThumbnail(value); })
      .catch(() => { if (active) setThumbnail(null); });
    return () => { active = false; };
  }, [file.path]);

  const automaticSkip = file.action === 'skip';
  return (
    <aside className={s.previewInspector}>
      <div className={s.inspectorHeader}><span>File Info</span><button onClick={onClose} aria-label="Close inspector">×</button></div>
      <div className={s.thumbnailFrame}>
        {thumbnail === undefined && <div className={s.thumbnailLoading}><span /></div>}
        {thumbnail && <img src={thumbnail} alt="" draggable="false" />}
        {thumbnail === null && <div className={s.thumbnailFallback}>▧<small>Preview unavailable</small></div>}
      </div>
      <div className={s.inspectorBody}>
        <h3 title={file.name}>{file.name}</h3>
        {!automaticSkip && (
          <button className={s.inspectorToggle} onClick={onToggle}>
            {file.included === false ? '✓ Organize this file' : '− Leave this file untouched'}
          </button>
        )}
        <div className={s.inspectorDivider} />
        <MetaRow label="Size" value={formatBytes(file.size)} />
        <MetaRow label="Type" value={(file.ext || '').replace('.', '').toUpperCase() || 'File'} />
        <MetaRow label="Date" value={formatDate(file.date)} warning={!file.date} />
        <MetaRow label="Date source" value={dateSourceLabel(file.dateSource)} warning={!file.dateSource} />
        {(file.cameraMake || file.cameraModel) && <MetaRow label="Camera" value={[file.cameraMake, file.cameraModel].filter(Boolean).join(' ')} />}
        {file.pixelWidth && file.pixelHeight && <MetaRow label="Dimensions" value={`${file.pixelWidth} × ${file.pixelHeight}`} />}
        {file.durationSeconds > 0 && <MetaRow label="Duration" value={`${Math.round(file.durationSeconds)} seconds`} />}
        {file.latitude != null && file.longitude != null && <MetaRow label="GPS" value={`${Number(file.latitude).toFixed(4)}, ${Number(file.longitude).toFixed(4)}`} />}
        {file.isDuplicate && <MetaRow label="Duplicate" value="Exact content match" warning />}
        {file.probableDuplicateGroupID && <MetaRow label={file.probableMatchKind === 'same' ? 'Same image' : 'Similar photo'} value={`${file.probableMatchKind === 'burst' ? 'Burst · ' : file.probableMatchKind === 'edited' ? 'Edited version · ' : file.probableMatchKind === 'same' ? '' : 'Visually similar · '}${file.probableMatchKind === 'same' ? (file.isProbableDuplicate ? 'other copy' : 'recommended') : 'you decide'} · ${file.probableMatchScore}%`} warning />}
        {file.probableDuplicateGroupID && file.probableMatchReasons && <p className={s.inspectorReason}>{file.probableMatchReasons.replace(/\s*·\s*review only/gi, '')}</p>}
        <MetaRow label="Source" value={file.archiveSourcePath ? 'Compressed archive' : 'Folder'} />
        <div className={s.dateCorrection}>
          <div className={s.dateCorrectionHeader}>
            <span>{file.date ? 'Correct capture date' : 'Assign capture date'}</span>
            {file.date && <button disabled={dateUpdating} onClick={() => onCorrectDate('')}>Clear date</button>}
          </div>
          <input
            type="date"
            max={dateInputValue(new Date())}
            value={dateInputValue(file.date)}
            disabled={dateUpdating}
            onChange={event => onCorrectDate(event.target.value)}
            aria-label={`Capture date for ${file.name}`}
          />
          <small>{dateUpdating ? 'Updating destinations…' : file.dateEstimated ? 'Estimated from the file timestamp. Review it if this file was copied or exported.' : 'Capture metadata and filename dates are preferred over file timestamps.'}</small>
        </div>
        <div className={s.inspectorDivider} />
        <div className={s.inspectorDestination}>
          <span>Planned destination</span>
          <strong className={isUnknownDate(file) ? s.warningText : ''}>{friendlyDestination(file, outputFolder)}</strong>
        </div>
        <div className={s.inspectorOriginal} title={file.archiveSourcePath || file.path}>
          <span>Original</span>
          <p>{file.archiveSourcePath || file.path}</p>
        </div>
        <button className={s.revealButton} onClick={() => window.foldiq.revealFile(file.archiveSourcePath || file.path)}>Show Original in Explorer ↗</button>
      </div>
    </aside>
  );
}

function MetaRow({ label, value, warning = false }) {
  return <div className={s.metaRow}><span>{label}</span><strong className={warning ? s.warningText : ''}>{value}</strong></div>;
}

function TreeNode({ node, depth }) {
  const children = [...node.children.values()].sort((a, b) => a.name.localeCompare(b.name));
  return (
    <div className={s.treeNode} style={{ '--tree-depth': depth }}>
      <div className={s.treeNodeRow}><span>▸</span><strong>{node.name}</strong><small>{node.count.toLocaleString()} files</small></div>
      {children.map(child => <TreeNode key={`${depth}-${child.name}`} node={child} depth={depth + 1} />)}
    </div>
  );
}

function Modal({ title, onClose, children }) {
  return (
    <div className={s.modalBackdrop} role="presentation" onMouseDown={event => { if (event.target === event.currentTarget) onClose(); }}>
      <section className={s.modalCard} role="dialog" aria-modal="true" aria-label={title}>
        <div className={s.modalHeader}><h2>{title}</h2><button onClick={onClose} aria-label="Close">×</button></div>
        <div className={s.modalBody}>{children}</div>
      </section>
    </div>
  );
}
