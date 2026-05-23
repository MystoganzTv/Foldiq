import { useEffect, useState } from 'react';
import s from './Screen.module.css';

const STAT_CARDS = [
  { key: 'photos',    label: 'Photos',         color: '#EFF6FF', iconColor: '#3B82F6' },
  { key: 'videos',    label: 'Videos',          color: '#F5F3FF', iconColor: '#8B5CF6' },
  { key: 'zips',      label: 'ZIPs Extracted',  color: '#F0FDFA', iconColor: '#14B8A6' },
  { key: 'dupes',     label: 'Exact Dupes',     color: '#FFF7ED', iconColor: '#F97316' },
  { key: 'probDupes', label: 'Probable Dupes',  color: '#FEFCE8', iconColor: '#EAB308' },
  { key: 'noDate',    label: 'Missing Date',    color: '#FEF2F2', iconColor: '#EF4444' },
  { key: 'noMeta',    label: 'No Metadata',     color: '#F8FAFC', iconColor: '#94A3B8' },
  { key: 'total',     label: 'Total Files',     color: '#F0FDF4', iconColor: '#22C55E' },
];

export default function ScanScreen({ go, folders, setFiles }) {
  const [progress, setProgress] = useState({ current: 0, total: 0, file: '' });
  const [done,     setDone]     = useState(false);
  const [stats,    setStats]    = useState(null);

  useEffect(() => {
    window.foldiq.onScanProgress(p => setProgress(p));
    window.foldiq.startScan(folders).then(files => {
      setFiles(files);
      const photoExts = new Set(['.jpg','.jpeg','.png','.heic','.heif','.tiff','.tif','.webp','.cr2','.cr3','.nef','.arw','.dng','.raf','.orf','.rw2']);
      const videoExts = new Set(['.mov','.mp4','.m4v','.avi','.mkv']);
      setStats({
        photos:    files.filter(f => photoExts.has(f.ext)).length,
        videos:    files.filter(f => videoExts.has(f.ext)).length,
        zips:      0,
        dupes:     files.filter(f => f.isDuplicate).length,
        probDupes: 0,
        noDate:    0,
        noMeta:    0,
        total:     files.length,
      });
      setDone(true);
    });
    return () => window.foldiq.removeAllListeners('scan:progress');
  }, []);

  const pct = progress.total > 0 ? Math.round((progress.current / progress.total) * 100) : 0;

  return (
    <div className={s.screen}>
      <div className={s.scrollArea}>
        <div style={{ textAlign: 'center', padding: '16px 0 24px' }}>
          <h1 className={s.title}>{done ? 'Scan Complete' : 'Scanning…'}</h1>
          <p className={s.sub} style={{ margin: '0 auto' }}>
            {done ? folders.map(f => f.split(/[\\/]/).pop()).join(', ') : 'Reading metadata from every file…'}
          </p>
        </div>

        {!done && (
          <div className={s.progressBlock} style={{ maxWidth: 500, margin: '0 auto', width: '100%' }}>
            <div className={s.progressBar}>
              <div className={s.progressFill} style={{ width: `${pct}%` }} />
            </div>
            <p className={s.progressLabel} style={{ textAlign: 'center' }}>
              {progress.current.toLocaleString()} / {progress.total.toLocaleString()} — {progress.file}
            </p>
          </div>
        )}

        {done && stats && (
          <div className={s.statsGrid}>
            {STAT_CARDS.map(card => (
              <div key={card.key} className={s.statCard}>
                <div className={s.statIcon} style={{ background: card.color }}>
                  <StatIcon name={card.key} color={card.iconColor} />
                </div>
                <div>
                  <div className={s.statNum}>{stats[card.key].toLocaleString()}</div>
                  <div className={s.statLabel}>{card.label}</div>
                </div>
              </div>
            ))}
          </div>
        )}
      </div>

      {done && (
        <div className={s.bottomBar}>
          <button className={s.btnSecondary} onClick={() => go('welcome')}>Change Folders</button>
          <button className={s.btnPrimary} onClick={() => go('settings')}>Configure Organization →</button>
        </div>
      )}
    </div>
  );
}

function StatIcon({ name, color }) {
  const p = { width: 22, height: 22, fill: 'none', stroke: color, strokeWidth: 1.8, strokeLinecap: 'round', strokeLinejoin: 'round' };
  const icons = {
    photos:    <svg {...p}><rect x="3" y="3" width="18" height="18" rx="2"/><circle cx="8.5" cy="8.5" r="1.5"/><polyline points="21 15 16 10 5 21"/></svg>,
    videos:    <svg {...p}><polygon points="23 7 16 12 23 17 23 7"/><rect x="1" y="5" width="15" height="14" rx="2"/></svg>,
    zips:      <svg {...p}><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/><line x1="12" y1="12" x2="12" y2="18"/><line x1="9" y1="15" x2="15" y2="15"/></svg>,
    dupes:     <svg {...p}><rect x="8" y="8" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>,
    probDupes: <svg {...p}><circle cx="12" cy="12" r="10"/><line x1="8" y1="12" x2="16" y2="12"/></svg>,
    noDate:    <svg {...p}><circle cx="12" cy="12" r="10"/><line x1="12" y1="8" x2="12" y2="12"/><line x1="12" y1="16" x2="12.01" y2="16"/></svg>,
    noMeta:    <svg {...p}><circle cx="12" cy="12" r="10"/><line x1="12" y1="8" x2="12" y2="12"/><line x1="12" y1="16" x2="12.01" y2="16"/></svg>,
    total:     <svg {...p}><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/><line x1="16" y1="13" x2="8" y2="13"/><line x1="16" y1="17" x2="8" y2="17"/><polyline points="10 9 9 9 8 9"/></svg>,
  };
  return icons[name] || null;
}
