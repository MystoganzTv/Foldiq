import { useEffect, useState } from 'react';
import s from './Screen.module.css';

export default function ApplyScreen({ go, plan, config, setResult }) {
  const [progress, setProgress] = useState({ current: 0, total: 0, file: '' });
  const [done,     setDone]     = useState(false);

  useEffect(() => {
    window.foldiq.onApplyProgress(p => setProgress(p));
    window.foldiq.startApply(plan, config).then(res => {
      setResult(res);
      setDone(true);
    });
    return () => window.foldiq.removeAllListeners('apply:progress');
  }, []);

  const total = plan.filter(f => f.action !== 'skip').length;
  const pct   = total > 0 ? Math.round((progress.current / total) * 100) : 0;

  return (
    <div className={s.screen} style={{ justifyContent: 'center' }}>
      <div className={s.centerBlock}>
        {!done ? (
          <>
            <div className={s.bigIcon}>⚡️</div>
            <h1 className={s.title}>{config.copyMode ? 'Copying' : 'Moving'} files…</h1>
            <p className={s.sub}>{progress.file || 'Starting…'}</p>
            <div className={s.progressBar} style={{ marginTop: 24 }}>
              <div className={s.progressFill} style={{ width: `${pct}%` }} />
            </div>
            <p className={s.progressLabel}>{progress.current.toLocaleString()} / {total.toLocaleString()}</p>
          </>
        ) : (
          <>
            <div className={s.bigIcon}>✅</div>
            <h1 className={s.title}>Done!</h1>
            <p className={s.sub}>Your library has been organized.</p>
            <button className={s.btnPrimary} style={{ marginTop: 32 }} onClick={() => go('report')}>
              View Report →
            </button>
          </>
        )}
      </div>
    </div>
  );
}
