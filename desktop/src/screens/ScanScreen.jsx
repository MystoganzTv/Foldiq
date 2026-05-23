import { useEffect, useState } from 'react';
import s from './Screen.module.css';

export default function ScanScreen({ go, folders, setFiles }) {
  const [progress, setProgress] = useState({ current: 0, total: 0, file: '' });
  const [done,     setDone]     = useState(false);
  const [results,  setResults]  = useState(null);

  useEffect(() => {
    window.foldiq.onScanProgress(p => setProgress(p));
    window.foldiq.startScan(folders).then(files => {
      setFiles(files);
      setResults({
        total:      files.length,
        duplicates: files.filter(f => f.isDuplicate).length,
        formats:    [...new Set(files.map(f => f.ext))].join(', '),
      });
      setDone(true);
    });
    return () => window.foldiq.removeAllListeners('scan:progress');
  }, []);

  const pct = progress.total > 0 ? Math.round((progress.current / progress.total) * 100) : 0;

  return (
    <div className={s.screen}>
      <div className={s.header}>
        <h1 className={s.title}>{done ? 'Scan Complete' : 'Scanning…'}</h1>
        <p className={s.sub}>{done ? `Found ${results.total.toLocaleString()} media files.` : 'Reading metadata from every file.'}</p>
      </div>

      {!done && (
        <div className={s.progressBlock}>
          <div className={s.progressBar}>
            <div className={s.progressFill} style={{ width: `${pct}%` }} />
          </div>
          <p className={s.progressLabel}>{progress.current.toLocaleString()} / {progress.total.toLocaleString()} — {progress.file}</p>
        </div>
      )}

      {done && results && (
        <div className={s.statsGrid}>
          <div className={s.statCard}>
            <div className={s.statNum}>{results.total.toLocaleString()}</div>
            <div className={s.statLabel}>Files found</div>
          </div>
          <div className={s.statCard}>
            <div className={s.statNum}>{results.duplicates.toLocaleString()}</div>
            <div className={s.statLabel}>Duplicates</div>
          </div>
          <div className={s.statCard}>
            <div className={s.statNum}>{[...new Set(results.formats.split(', '))].length}</div>
            <div className={s.statLabel}>Formats</div>
          </div>
        </div>
      )}

      {done && (
        <div className={s.actions}>
          <button className={s.btnSecondary} onClick={() => go('welcome')}>← Back</button>
          <button className={s.btnPrimary} onClick={() => go('settings')}>Configure →</button>
        </div>
      )}
    </div>
  );
}
