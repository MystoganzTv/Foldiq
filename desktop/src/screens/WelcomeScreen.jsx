import { useRef, useState } from 'react';
import s from './Screen.module.css';

export default function WelcomeScreen({ go, folders, setFolders }) {
  const [dragging, setDragging] = useState(false);
  const listRef = useRef(null);

  function addSources(selected) {
    if (selected.length) {
      setFolders(prev => [...new Set([...prev, ...selected])]);
      setTimeout(() => listRef.current?.scrollIntoView({ behavior: 'smooth', block: 'nearest' }), 50);
    }
  }

  async function pickFolders() {
    addSources(await window.foldiq.selectFolders());
  }

  async function pickArchives() {
    addSources(await window.foldiq.selectArchives());
  }

  async function onDrop(e) {
    e.preventDefault();
    setDragging(false);
    const candidates = Array.from(e.dataTransfer.files)
      .map(file => window.foldiq.getPathForFile(file))
      .filter(Boolean);
    addSources(await window.foldiq.filterSources(candidates));
  }

  const hasFolders = folders.length > 0;

  return (
    <div className={s.screen}>
      <div className={s.scrollArea}>
        {/* Hero — compact when folders selected */}
        <div style={{ textAlign: 'center', padding: hasFolders ? '16px 0 8px' : '32px 0 16px', transition: 'padding .2s' }}>
          <svg width={hasFolders ? 52 : 80} height={hasFolders ? 52 : 80} viewBox="0 0 80 80" fill="none" style={{ marginBottom: hasFolders ? 12 : 24, transition: 'all .2s' }}>
            <rect width="80" height="80" rx="20" fill="url(#grad)"/>
            <defs>
              <linearGradient id="grad" x1="0" y1="0" x2="80" y2="80" gradientUnits="userSpaceOnUse">
                <stop stopColor="#6366F1"/>
                <stop offset="1" stopColor="#8B5CF6"/>
              </linearGradient>
            </defs>
            <path d="M18 28C18 25.8 19.8 24 22 24H36L42 30H58C60.2 30 62 31.8 62 34V52C62 54.2 60.2 56 58 56H22C19.8 56 18 54.2 18 52V28Z" fill="white" fillOpacity="0.2"/>
            <path d="M20 32C20 29.8 21.8 28 24 28H38L44 34H60C62.2 34 64 35.8 64 38V54C64 56.2 62.2 58 60 58H24C21.8 58 20 56.2 20 54V32Z" fill="white" fillOpacity="0.9"/>
            <circle cx="58" cy="26" r="10" fill="#F59E0B"/>
            <path d="M54 26H62M58 22V30" stroke="white" strokeWidth="2.5" strokeLinecap="round"/>
          </svg>
          {!hasFolders && (
            <>
              <h1 style={{ fontSize: 34, fontWeight: 800, color: '#0F172A', marginBottom: 10 }}>
                Organize Your Library
              </h1>
              <p style={{ fontSize: 16, color: '#475569', lineHeight: 1.6 }}>
                Clean up and organize thousands of messy<br />photos and videos safely, right on your PC.
              </p>
            </>
          )}
          {hasFolders && (
            <h1 style={{ fontSize: 20, fontWeight: 700, color: '#0F172A' }}>
              {folders.length} item{folders.length > 1 ? 's' : ''} selected
            </h1>
          )}
        </div>

        {/* Drop zone — compact when folders already added */}
        <div
          className={`${s.dropzone} ${dragging ? s.dragging : ''}`}
          style={hasFolders ? { padding: '20px 32px' } : {}}
          role="button"
          tabIndex={0}
          onClick={pickFolders}
          onKeyDown={event => {
            if (event.key === 'Enter' || event.key === ' ') {
              event.preventDefault();
              pickFolders();
            }
          }}
          onDragOver={e => { e.preventDefault(); setDragging(true); }}
          onDragLeave={() => setDragging(false)}
          onDrop={onDrop}
        >
          {!hasFolders && (
            <div style={{ marginBottom: 12 }}>
              <svg width="48" height="48" viewBox="0 0 24 24" fill="none" stroke="#3B82F6" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
                <path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/>
              </svg>
            </div>
          )}
          <p className={s.dropTitle} style={hasFolders ? { fontSize: 14 } : {}}>
            {hasFolders ? '+ Drop more folders or archives, or click to add a folder' : 'Drop folders or ZIP, RAR, or 7z archives here'}
          </p>
          {!hasFolders && <p className={s.dropSub}>Supports ZIP, RAR, 7z, JPG, HEIC, RAW, MOV, MP4 and more</p>}
        </div>

        {/* Selected folders */}
        {hasFolders && (
          <div ref={listRef} className={s.folderList}>
            {folders.map((f, i) => (
              <div key={f} className={s.folderItem}>
                <span className={s.folderIcon}>
                  {['.zip', '.rar', '.7z'].some(ext => f.toLowerCase().endsWith(ext)) ? (
                    <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="#3B82F6" strokeWidth="2">
                      <path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><path d="M14 2v6h6"/><path d="M12 11v7M9.5 14.5h5"/>
                    </svg>
                  ) : (
                    <svg width="18" height="18" viewBox="0 0 24 24" fill="#3B82F6">
                      <path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/>
                    </svg>
                  )}
                </span>
                <span className={s.folderPath}>{f}</span>
                <button
                  className={s.folderRemove}
                  aria-label={`Remove ${f}`}
                  onClick={e => { e.stopPropagation(); setFolders(folders.filter((_, j) => j !== i)); }}
                >✕</button>
              </div>
            ))}
          </div>
        )}

        <p style={{ textAlign: 'center', fontSize: 13, color: '#94A3B8' }}>
          Nothing is deleted without your permission.
        </p>
      </div>

      <div className={s.bottomBar}>
        <div />
        <div className={s.bottomBarRight}>
          <button className={s.btnSecondary} onClick={pickFolders}>+ Add Folders</button>
          <button className={s.btnSecondary} onClick={pickArchives}>+ Add Archives</button>
          <button
            className={s.btnPrimary}
            disabled={folders.length === 0}
            onClick={() => go('scan')}
          >
            Scan Items →
          </button>
        </div>
      </div>
    </div>
  );
}
