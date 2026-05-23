import { useState } from 'react';
import s from './Screen.module.css';

export default function WelcomeScreen({ go, folders, setFolders }) {
  const [dragging, setDragging] = useState(false);

  async function pickFolders() {
    const selected = await window.foldiq.selectFolders();
    if (selected.length) setFolders(selected);
  }

  function onDrop(e) {
    e.preventDefault();
    setDragging(false);
    const paths = Array.from(e.dataTransfer.files)
      .filter(f => f.type === '' || f.path)
      .map(f => f.path);
    if (paths.length) setFolders(paths);
  }

  return (
    <div className={s.screen}>
      <div className={s.header}>
        <h1 className={s.title}>Select Folders</h1>
        <p className={s.sub}>Choose the folders you want Foldiq to organize.</p>
      </div>

      <div
        className={`${s.dropzone} ${dragging ? s.dragging : ''}`}
        onClick={pickFolders}
        onDragOver={e => { e.preventDefault(); setDragging(true); }}
        onDragLeave={() => setDragging(false)}
        onDrop={onDrop}
      >
        <div className={s.dropIcon}>📁</div>
        <p className={s.dropTitle}>Drop folders here or click to browse</p>
        <p className={s.dropSub}>Supports JPG, HEIC, RAW, MOV, MP4 and more</p>
      </div>

      {folders.length > 0 && (
        <div className={s.folderList}>
          {folders.map((f, i) => (
            <div key={i} className={s.folderItem}>
              <span className={s.folderIcon}>📂</span>
              <span className={s.folderPath}>{f}</span>
              <button
                className={s.folderRemove}
                onClick={() => setFolders(folders.filter((_, j) => j !== i))}
              >✕</button>
            </div>
          ))}
        </div>
      )}

      <div className={s.actions}>
        <button
          className={s.btnPrimary}
          disabled={folders.length === 0}
          onClick={() => go('scan')}
        >
          Scan Folders →
        </button>
      </div>
    </div>
  );
}
