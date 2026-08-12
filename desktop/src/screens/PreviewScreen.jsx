import { useEffect, useMemo, useState } from 'react';
import s from './Screen.module.css';

const FILTERS = [
  ['all', 'All'],
  ['included', 'Included'],
  ['excluded', 'Excluded'],
  ['skipped', 'Skipped by Foldiq'],
];

function formatBytes(bytes = 0) {
  if (bytes >= 1e9) return `${(bytes / 1e9).toFixed(1)} GB`;
  if (bytes >= 1e6) return `${(bytes / 1e6).toFixed(1)} MB`;
  if (bytes >= 1e3) return `${(bytes / 1e3).toFixed(0)} KB`;
  return `${bytes} B`;
}

function pathParts(value = '') {
  return value.split(/[\\/]+/).filter(Boolean);
}

function friendlyDestination(file, outputFolder) {
  if (!file.destPath) return 'No destination — skipped automatically';

  const destination = pathParts(file.destPath);
  const root = pathParts(outputFolder);
  const rootMatches = root.length > 0 && root.every(
    (part, index) => destination[index]?.toLowerCase() === part.toLowerCase(),
  );
  const relative = rootMatches ? destination.slice(root.length) : destination.slice(-4);
  return relative.join('  ›  ');
}

function skipReason(file) {
  if (file.reason === 'duplicate') return 'Exact duplicate';
  return 'Skipped automatically';
}

export default function PreviewScreen({ go, files, config, plan, setPlan }) {
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [filter, setFilter] = useState('all');

  useEffect(() => {
    let active = true;
    window.foldiq.buildPlan(files, config)
      .then(nextPlan => {
        if (!active) return;
        setPlan(nextPlan);
        setLoading(false);
      })
      .catch(err => {
        if (!active) return;
        setError(err?.message || 'Foldiq could not build the preview.');
        setLoading(false);
      });
    return () => { active = false; };
  }, [files, config, setPlan]);

  const candidates = useMemo(() => plan.filter(file => file.action !== 'skip'), [plan]);
  const included = useMemo(
    () => candidates.filter(file => file.included !== false),
    [candidates],
  );
  const excluded = useMemo(
    () => candidates.filter(file => file.included === false),
    [candidates],
  );
  const skipped = useMemo(() => plan.filter(file => file.action === 'skip'), [plan]);

  const visible = useMemo(() => {
    if (filter === 'included') return included;
    if (filter === 'excluded') return excluded;
    if (filter === 'skipped') return skipped;
    return plan;
  }, [filter, included, excluded, skipped, plan]);

  const filterCounts = {
    all: plan.length,
    included: included.length,
    excluded: excluded.length,
    skipped: skipped.length,
  };

  function setIncluded(file, value) {
    if (file.action === 'skip') return;
    setPlan(current => current.map(item => (
      item === file ? { ...item, included: value } : item
    )));
  }

  function setAllVisible(value) {
    const visibleItems = new Set(visible.filter(file => file.action !== 'skip'));
    setPlan(current => current.map(item => (
      visibleItems.has(item) ? { ...item, included: value } : item
    )));
  }

  return (
    <div className={s.screen}>
      <div className={s.previewHeader}>
        <div>
          <h1 className={s.title}>Review before organizing</h1>
          <p className={s.sub}>
            Choose what Foldiq should process. Nothing has been moved or copied yet.
          </p>
        </div>
      </div>

      {loading && (
        <div className={s.centerBlock}>
          <div className={s.progressBar} style={{ width: 360 }}>
            <div className={s.progressFill} style={{ width: '65%' }} />
          </div>
          <p className={s.sub}>Building a safe organization plan…</p>
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
          <div className={s.previewContent}>
            <div className={s.previewStats}>
              <div className={`${s.previewStat} ${s.previewStatPrimary}`}>
                <span className={s.previewStatIcon}>✓</span>
                <div><strong>{included.length.toLocaleString()}</strong><span>Included</span></div>
              </div>
              <div className={s.previewStat}>
                <span className={s.previewStatIcon}>−</span>
                <div><strong>{excluded.length.toLocaleString()}</strong><span>Excluded by you</span></div>
              </div>
              <div className={s.previewStat}>
                <span className={s.previewStatIcon}>⊘</span>
                <div><strong>{skipped.length.toLocaleString()}</strong><span>Skipped by Foldiq</span></div>
              </div>
              <div className={s.previewStat}>
                <span className={s.previewStatIcon}>⇢</span>
                <div>
                  <strong>{config.copyMode ? 'Copy' : 'Move'}</strong>
                  <span>{config.copyMode ? 'Originals stay put' : 'Undo will be available'}</span>
                </div>
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
                    {label} ({filterCounts[id].toLocaleString()})
                  </button>
                ))}
              </div>
              <div className={s.previewBulkActions}>
                <button onClick={() => setAllVisible(true)}>Include shown</button>
                <button onClick={() => setAllVisible(false)}>Exclude shown</button>
              </div>
            </div>

            <div className={s.fileList}>
              {visible.length === 0 && (
                <div className={s.previewEmpty}>No files in this group.</div>
              )}
              {visible.slice(0, 500).map((file, index) => {
                const isAutomaticSkip = file.action === 'skip';
                const isIncluded = !isAutomaticSkip && file.included !== false;
                return (
                  <div
                    key={file.id || file.path || index}
                    className={`${s.fileRow} ${!isIncluded ? s.fileRowExcluded : ''}`}
                  >
                    <label className={s.previewCheckbox} title={isAutomaticSkip ? skipReason(file) : 'Include this file'}>
                      <input
                        type="checkbox"
                        checked={isIncluded}
                        disabled={isAutomaticSkip}
                        onChange={event => setIncluded(file, event.target.checked)}
                        aria-label={`Include ${file.name}`}
                      />
                      <span />
                    </label>
                    <span className={s.fileExt}>{(file.ext || '').replace('.', '').toUpperCase() || 'FILE'}</span>
                    <div className={s.fileInfo}>
                      <span className={s.fileName} title={file.name}>{file.name}</span>
                      <span className={s.fileDestinationLabel}>
                        {isAutomaticSkip ? skipReason(file) : 'Will go to'}
                      </span>
                      <span className={s.fileDest} title={file.destPath || ''}>
                        {friendlyDestination(file, config.outputFolder)}
                      </span>
                    </div>
                    <div className={s.fileMeta}>
                      <span>{formatBytes(file.size)}</span>
                      <span className={isIncluded ? s.includedLabel : s.excludedLabel}>
                        {isAutomaticSkip ? 'Automatic' : isIncluded ? 'Included' : 'Excluded'}
                      </span>
                    </div>
                  </div>
                );
              })}
              {visible.length > 500 && (
                <div className={s.moreRow}>…and {(visible.length - 500).toLocaleString()} more in this group</div>
              )}
            </div>
          </div>

          <div className={s.bottomBar}>
            <button className={s.btnSecondary} onClick={() => go('settings')}>← Back</button>
            <div className={s.previewFooterSummary}>
              <strong>{included.length.toLocaleString()} files will be {config.copyMode ? 'copied' : 'moved'}</strong>
              <span>{(excluded.length + skipped.length).toLocaleString()} will not be processed</span>
            </div>
            <button
              className={s.btnPrimary}
              disabled={included.length === 0}
              onClick={() => go('apply')}
            >
              Confirm {included.length.toLocaleString()} Files →
            </button>
          </div>
        </>
      )}
    </div>
  );
}
