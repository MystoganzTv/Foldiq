import { useEffect, useState } from 'react';
import s from '../screens/Screen.module.css';

function timeAgo(timestamp) {
  const seconds = Math.max(0, Math.round((Date.now() - timestamp) / 1000));
  if (seconds < 60) return 'just now';
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return `${minutes} min ago`;
  const hours = Math.round(minutes / 60);
  if (hours < 24) return `${hours} h ago`;
  return new Date(timestamp).toLocaleDateString();
}

export default function AutoOrganizeCard({ config, setConfig }) {
  const [state, setState] = useState(null);
  const [folder, setFolder] = useState('');
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState('');

  useEffect(() => {
    if (!window.foldiq?.getWatchState) return undefined;
    let active = true;
    window.foldiq.getWatchState().then(value => {
      if (!active) return;
      setState(value);
      setFolder(value.folder || '');
    }).catch(() => {});
    window.foldiq.onWatchEvent(event => {
      if (event.type === 'running') setMessage(`Organizing ${event.files.toLocaleString()} new file${event.files === 1 ? '' : 's'}…`);
      else if (event.type === 'error') setMessage(event.message);
      else setMessage('');
      window.foldiq.getWatchState().then(value => { if (active) setState(value); }).catch(() => {});
    });
    return () => {
      active = false;
      window.foldiq.removeAllListeners('watch:event');
    };
  }, []);

  if (!state) return null;

  async function chooseFolder() {
    const selected = await window.foldiq.chooseWatchFolder();
    if (selected) setFolder(selected);
  }

  async function chooseOutput() {
    const selected = await window.foldiq.selectOutput();
    if (selected) setConfig(current => ({ ...current, outputFolder: selected }));
  }

  async function setEnabled(enabled) {
    setBusy(true);
    setMessage('');
    try {
      // Settings are saved as they change; give that write a moment to land
      // before the main process reads the output folder.
      await window.foldiq.savePreferences(config);
      const next = await window.foldiq.configureWatch(enabled, folder);
      setState(next);
      if (next.error) setMessage(next.error);
    } catch (error) {
      setMessage(error?.message || 'Auto-organize could not be changed.');
    } finally {
      setBusy(false);
    }
  }

  async function undo(run) {
    setBusy(true);
    setMessage('');
    try {
      const result = await window.foldiq.undoWatchRun(run.manifestPath);
      setState(result.state);
      setMessage(result.errors.length > 0
        ? (result.errors[0]?.error || 'Some files could not be restored safely.')
        : `${result.restored.toLocaleString()} file${result.restored === 1 ? '' : 's'} put back where they arrived.`);
    } catch (error) {
      setMessage(error?.message || 'Undo could not be completed safely.');
    } finally {
      setBusy(false);
    }
  }

  const lastRun = state.history.find(run => run.organized > 0);
  const canEnable = Boolean(folder && config.outputFolder);

  return (
    <section className={s.autoOrganizeCard} aria-label="Auto-organize new files">
      <div className={s.autoOrganizeHeader}>
        <div>
          <strong>Auto-organize new files</strong>
          <p>
            {state.enabled
              ? 'Foldiq is watching this folder and organizes new photos and videos a few seconds after they arrive, using your organization settings.'
              : 'Pick a folder such as Downloads or your camera import folder. While Foldiq is open, new photos and videos that land there are organized automatically. Files already in the folder are left alone.'}
          </p>
        </div>
        <span className={`${s.autoOrganizeStatus} ${state.enabled && state.active ? s.autoOrganizeOn : ''}`}>
          {state.enabled && state.active ? 'On' : 'Off'}
        </span>
      </div>

      <div className={s.autoOrganizeRow}>
        <span>Watch</span>
        <code title={folder}>{folder || 'No folder chosen'}</code>
        {!state.enabled && <button className={s.btnOutline} onClick={chooseFolder} disabled={busy}>Choose…</button>}
      </div>
      <div className={s.autoOrganizeRow}>
        <span>Into</span>
        <code title={config.outputFolder}>{config.outputFolder || 'No output folder yet'}</code>
        {!state.enabled && <button className={s.btnOutline} onClick={chooseOutput} disabled={busy}>Choose…</button>}
      </div>

      {lastRun && (
        <div className={s.autoOrganizeRow}>
          <span>Last run</span>
          <em>
            {lastRun.undone
              ? `Undone · ${lastRun.organized.toLocaleString()} files put back`
              : `${lastRun.organized.toLocaleString()} file${lastRun.organized === 1 ? '' : 's'} organized ${timeAgo(lastRun.at)}`}
            {lastRun.errors > 0 ? ` · ${lastRun.errors} need attention` : ''}
          </em>
          {!lastRun.undone && lastRun.manifestPath && (
            <button className={s.btnOutline} onClick={() => undo(lastRun)} disabled={busy}>↩ Undo</button>
          )}
        </div>
      )}

      {message && <p className={s.autoOrganizeMessage}>{message}</p>}

      <div className={s.autoOrganizeActions}>
        {state.enabled
          ? <button className={s.btnSecondary} onClick={() => setEnabled(false)} disabled={busy}>Turn Off</button>
          : <button className={s.btnPrimary} onClick={() => setEnabled(true)} disabled={busy || !canEnable}>Turn On</button>}
      </div>
    </section>
  );
}
