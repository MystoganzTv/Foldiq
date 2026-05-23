import { useEffect, useState } from 'react';
import s from './Screen.module.css';

export default function PreviewScreen({ go, files, config, plan, setPlan }) {
  const [loading, setLoading] = useState(true);
  const [filter,  setFilter]  = useState('all');

  useEffect(() => {
    window.foldiq.buildPlan(files, config).then(p => {
      setPlan(p);
      setLoading(false);
    });
  }, []);

  const moves    = plan.filter(f => f.action !== 'skip');
  const skipped  = plan.filter(f => f.action === 'skip');
  const visible  = filter === 'all'     ? moves
                 : filter === 'skipped' ? skipped
                 : moves.filter(f => f.action === filter);

  function fmt(bytes) {
    if (bytes > 1e9) return (bytes / 1e9).toFixed(1) + ' GB';
    if (bytes > 1e6) return (bytes / 1e6).toFixed(1) + ' MB';
    return (bytes / 1e3).toFixed(0) + ' KB';
  }

  return (
    <div className={s.screen}>
      <div className={s.header}>
        <h1 className={s.title}>Preview Changes</h1>
        <p className={s.sub}>
          {loading ? 'Building plan…' : `${moves.length.toLocaleString()} files to ${config.copyMode ? 'copy' : 'move'} · ${skipped.length} skipped`}
        </p>
      </div>

      {!loading && (
        <>
          <div className={s.filterRow}>
            {['all', 'move', 'copy', 'skipped'].map(f => (
              <button
                key={f}
                className={`${s.filterBtn} ${filter === f ? s.active : ''}`}
                onClick={() => setFilter(f)}
              >
                {f.charAt(0).toUpperCase() + f.slice(1)}
                {f === 'all'     && ` (${moves.length})`}
                {f === 'skipped' && ` (${skipped.length})`}
              </button>
            ))}
          </div>

          <div className={s.fileList}>
            {visible.slice(0, 200).map((file, i) => (
              <div key={i} className={s.fileRow}>
                <span className={s.fileExt}>{file.ext.slice(1).toUpperCase()}</span>
                <div className={s.fileInfo}>
                  <span className={s.fileName}>{file.name}</span>
                  <span className={s.fileDest}>{file.destPath || '— skipped'}</span>
                </div>
                <span className={s.fileSize}>{fmt(file.size)}</span>
              </div>
            ))}
            {visible.length > 200 && (
              <div className={s.moreRow}>…and {(visible.length - 200).toLocaleString()} more</div>
            )}
          </div>

          <div className={s.actions}>
            <button className={s.btnSecondary} onClick={() => go('settings')}>← Back</button>
            <button className={s.btnPrimary} onClick={() => go('apply')}>
              {config.copyMode ? 'Copy' : 'Move'} {moves.length.toLocaleString()} Files →
            </button>
          </div>
        </>
      )}
    </div>
  );
}
