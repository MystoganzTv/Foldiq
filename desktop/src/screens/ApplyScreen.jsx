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
    <div className={s.screen}>
      <div className={s.centerBlock}>
        {!done ? (
          <>
            <div style={{ marginBottom: 8 }}>
              <svg width="56" height="56" viewBox="0 0 24 24" fill="none" stroke="#3B82F6" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
                <polyline points="23 4 23 10 17 10"/><polyline points="1 20 1 14 7 14"/>
                <path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15"/>
              </svg>
            </div>
            <h1 className={s.title}>{config.copyMode ? 'Copying' : 'Moving'} files…</h1>
            <p className={s.sub}>{progress.file || 'Starting…'}</p>
            <div className={s.progressBar} style={{ width: 400, marginTop: 24 }}>
              <div className={s.progressFill} style={{ width: `${pct}%` }} />
            </div>
            <p className={s.progressLabel}>{progress.current.toLocaleString()} / {total.toLocaleString()}</p>
          </>
        ) : (
          <>
            <div style={{ marginBottom: 8 }}>
              <svg width="64" height="64" viewBox="0 0 24 24" fill="none" stroke="#10B981" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
                <path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"/><polyline points="22 4 12 14.01 9 11.01"/>
              </svg>
            </div>
            <h1 className={s.title}>Done!</h1>
            <p className={s.sub}>Your library has been organized.</p>
            <button className={s.btnPrimary} style={{ marginTop: 28 }} onClick={() => go('report')}>
              View Report →
            </button>
          </>
        )}
      </div>
    </div>
  );
}
