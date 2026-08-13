import { useEffect, useRef, useState } from 'react';
import s from './Screen.module.css';

function formatElapsed(seconds) {
  const minutes = Math.floor(seconds / 60);
  return `${minutes}:${String(seconds % 60).padStart(2, '0')}`;
}

export default function ApplyScreen({ go, plan, config, setResult }) {
  const [progress, setProgress] = useState({ current: 0, total: 0, file: '' });
  const [result, setLocalResult] = useState(null);
  const [fatalError, setFatalError] = useState('');
  const [elapsed, setElapsed] = useState(0);
  const startedRef = useRef(false);

  const total = plan.filter(file => file.action !== 'skip' && file.included !== false).length;
  const done = Boolean(result) || Boolean(fatalError);
  const errors = result?.errors || [];
  const pct = total > 0 ? Math.min(100, Math.round((progress.current / total) * 100)) : 0;

  useEffect(() => {
    if (startedRef.current) return undefined;
    startedRef.current = true;

    window.foldiq.onApplyProgress(nextProgress => setProgress(nextProgress));
    window.foldiq.startApply(plan, config)
      .then(nextResult => {
        setLocalResult(nextResult);
        setResult(nextResult);
      })
      .catch(error => setFatalError(error?.message || 'Foldiq could not organize these files.'));

    return () => window.foldiq.removeAllListeners('apply:progress');
  }, [config, plan, setResult]);

  useEffect(() => {
    if (done) return undefined;
    const timer = window.setInterval(() => setElapsed(value => value + 1), 1000);
    return () => window.clearInterval(timer);
  }, [done]);

  const completedWithErrors = errors.length > 0;
  const title = fatalError
    ? 'Organization Was Interrupted'
    : completedWithErrors
      ? 'Finished with Errors'
      : result
        ? 'Done!'
        : `${config.copyMode ? 'Copying' : 'Moving'} Files…`;

  const subtitle = fatalError
    ? 'Foldiq preserved a recovery record. Reopen the app to restore any files that were already organized.'
    : completedWithErrors
      ? `${result.moved.toLocaleString()} files were organized, but ${errors.length.toLocaleString()} need attention.`
      : result
        ? `${result.moved.toLocaleString()} files were organized successfully.`
        : 'Keep Foldiq open while it creates your organized library.';

  return (
    <div className={s.screen}>
      <div className={s.applyStage}>
        <div className={`${s.applyStatusIcon} ${done ? s.applyStatusIconDone : ''}`}>
          {!done && (
            <svg className={s.applySpinner} width="62" height="62" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
              <polyline points="23 4 23 10 17 10"/><polyline points="1 20 1 14 7 14"/>
              <path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15"/>
            </svg>
          )}
          {done && !fatalError && !completedWithErrors && (
            <svg className={s.applySuccess} width="66" height="66" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round">
              <path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"/><polyline points="22 4 12 14.01 9 11.01"/>
            </svg>
          )}
          {done && (fatalError || completedWithErrors) && <span className={s.applyWarning}>!</span>}
        </div>

        <h1 className={s.applyTitle}>{title}</h1>
        <p className={s.applySub}>{subtitle}</p>

        {!done && (
          <div className={s.applyProgressCard}>
            <div className={s.applyProgressHeader}>
              <span title={progress.file}>{progress.file || 'Preparing your files…'}</span>
              <strong>{formatElapsed(elapsed)}</strong>
            </div>
            <div className={s.progressBar}>
              <div className={s.progressFill} style={{ width: `${pct}%` }} />
            </div>
            <div className={s.applyProgressFooter}>
              <span>{progress.current.toLocaleString()} of {total.toLocaleString()}</span>
              <strong>{pct}%</strong>
            </div>
          </div>
        )}

        {done && (fatalError || completedWithErrors) && (
          <div className={s.applyErrorSummary}>
            <strong>{fatalError || `${errors.length.toLocaleString()} file${errors.length === 1 ? '' : 's'} could not be organized`}</strong>
            {errors.slice(0, 4).map((item, index) => (
              <p key={`${item.file || 'error'}-${index}`}><span>{item.file || 'File'}</span>{item.error || item.message || 'Unknown error'}</p>
            ))}
            {errors.length > 4 && <small>And {(errors.length - 4).toLocaleString()} more — all are listed in the report.</small>}
          </div>
        )}

        {done && (
          <button className={s.btnPrimary} onClick={() => go(fatalError ? 'settings' : 'report')}>
            {fatalError ? 'Back to Settings' : 'View Report'} →
          </button>
        )}
      </div>
    </div>
  );
}
