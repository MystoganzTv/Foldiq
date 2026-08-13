import s from './Screen.module.css';

const MODES = [
  {
    id: 'smart',
    label: 'Smart Hybrid',
    badge: 'Recommended',
    sub: 'Year → Month → Date, with location when available. Best for most libraries.',
    preview: '2026/\n  2026-05 May/\n    2026-05-18 Herndon VA/',
    groupByMonth: true, groupByDay: true,
  },
  {
    id: 'year',
    label: 'By Year',
    sub: 'One folder per year. Simple and fast.',
    preview: '2026/\n2025/\n2024/',
    groupByMonth: false, groupByDay: false,
  },
  {
    id: 'yearmonth',
    label: 'By Year & Month',
    sub: 'One folder per month, grouped by year.',
    preview: '2026/\n  2026-05 May/\n  2026-04 April/',
    groupByMonth: true, groupByDay: false,
  },
  {
    id: 'full',
    label: 'By Year, Month & Day',
    sub: 'Maximum granularity — one folder per shooting day.',
    preview: '2026/\n  2026-05 May/\n    2026-05-18/',
    groupByMonth: true, groupByDay: true,
  },
  {
    id: 'location',
    label: 'By Location',
    sub: 'Country → State → City when GPS is available. Files without GPS stay together under Unknown Location.',
    preview: 'United States/\n  Virginia/\n    Herndon/\nUnknown Location/\n  2026/',
    groupByMonth: false, groupByDay: false,
  },
];

export default function SettingsScreen({ go, files, config, setConfig }) {
  const mode = config.organizationMode || 'smart';
  const missingDates = files.filter(file => !file.date).length;
  const fileDatesAvailable = files.filter(file => !file.date && file.fileModifiedDate).length;

  function selectMode(m) {
    setConfig(c => ({
      ...c,
      organizationMode: m.id,
      groupByMonth: m.groupByMonth,
      groupByDay: m.groupByDay,
      useGPSLocation: m.id === 'location' ? true : c.useGPSLocation,
    }));
  }

  async function pickOutput() {
    const folder = await window.foldiq.selectOutput();
    if (folder) setConfig(c => ({ ...c, outputFolder: folder }));
  }

  function toggle(key) { setConfig(c => ({ ...c, [key]: !c[key] })); }

  return (
    <div className={s.screen}>
      <div className={s.scrollArea}>
        <div>
          <h1 className={s.title}>Organization Settings</h1>
          <p className={s.sub}>Pick a rule, where to save the result, and how originals should be handled. You'll preview every change before anything moves.</p>
        </div>

        {/* Output folder */}
        <div className={s.formGroup}>
          <label className={s.label}>
            <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" style={{display:'inline',marginRight:6,verticalAlign:'middle'}}>
              <path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/>
            </svg>
            Output Folder
          </label>
          <div className={s.folderPicker}>
            <span className={s.folderPickerPath}>{config.outputFolder || 'Not selected — choose where organized files go'}</span>
            <button className={s.btnOutline} style={{ padding: '6px 14px', fontSize: 13 }} onClick={pickOutput}>Browse…</button>
          </div>
        </div>

        {/* Organization rule */}
        <div>
          <div className={s.sectionTitle}>
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="#475569" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
              <path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/>
              <circle cx="18" cy="8" r="4" fill="#3B82F6" stroke="none"/>
              <line x1="18" y1="6" x2="18" y2="10" stroke="white" strokeWidth="1.5"/>
              <line x1="16" y1="8" x2="20" y2="8" stroke="white" strokeWidth="1.5"/>
            </svg>
            Organization Rule
          </div>

          {MODES.map(m => {
            const sel = mode === m.id;
            return (
              <div key={m.id} className={`${s.radioCard} ${sel ? s.selected : ''}`} onClick={() => selectMode(m)}>
                <div className={s.radioHeader}>
                  <div className={`${s.radioCircle} ${sel ? s.checked : ''}`}>
                    {sel && <div className={s.radioDot} />}
                  </div>
                  <span className={s.radioLabel}>{m.label}</span>
                  {m.badge && <span className={s.badge}>{m.badge}</span>}
                </div>
                <p className={s.radioSub}>{m.sub}</p>
                <div className={s.radioPreview}>
                  <code>{m.preview}</code>
                </div>
              </div>
            );
          })}
        </div>

        {/* Toggles */}
        <div>
          <div className={s.sectionTitle}>Options</div>
          {[
            { key: 'copyMode', label: 'Copy instead of Move', sub: 'Keep originals in place (uses more disk space)' },
            {
              key: 'useFileDateFallback',
              label: 'Estimate missing capture dates from file dates',
              sub: `${fileDatesAvailable.toLocaleString()} of ${missingDates.toLocaleString()} missing dates have a file timestamp. Optional: copied or exported files may have a newer date than the photo.`,
            },
            ...(['smart', 'location'].includes(mode) ? [{
              key: 'useGPSLocation',
              label: 'Use GPS location in folder names',
              sub: 'Requires internet. Approximate GPS coordinates are sent to OpenStreetMap only to obtain country, state, and city names; results are cached on this PC.',
            }] : []),
          ].map(t => (
            <div key={t.key} className={s.toggleRow} onClick={() => toggle(t.key)}>
              <div className={`${s.toggleSwitch} ${config[t.key] ? s.on : ''}`} />
              <div>
                <div className={s.toggleLabel}>{t.label}</div>
                <div className={s.toggleSub}>{t.sub}</div>
              </div>
            </div>
          ))}
          {['smart', 'location'].includes(mode) && config.useGPSLocation && (
            <button className={s.attributionLink} onClick={() => window.foldiq.openAttribution()}>
              Location names © OpenStreetMap contributors · ODbL
            </button>
          )}
          <div className={s.settingSelectRow}>
            <div><div className={s.toggleLabel}>Duplicate handling</div><div className={s.toggleSub}>Applies to exact copies and strong visual matches. Review-only similar photos are never separated automatically.</div></div>
            <select value={config.duplicateHandling} onChange={event => setConfig(c => ({ ...c, duplicateHandling: event.target.value }))}>
              <option value="separate">Separate into Duplicates folders</option>
              <option value="skip">Leave duplicates untouched</option>
              <option value="organize">Organize with everything else</option>
            </select>
          </div>
          <div className={s.settingsNote}>Scan included {config.includeVideos ? 'videos' : 'photos only'} and {config.includeArchives ? 'compressed archives' : 'no compressed archives'}. Change these scan options from the first screen.</div>
        </div>
      </div>

      <div className={s.bottomBar}>
        <button className={s.btnSecondary} onClick={() => go('scan')}>Back</button>
        <button className={s.btnPrimary} disabled={!config.outputFolder} onClick={() => go('preview')}>
          Preview Organization →
        </button>
      </div>
    </div>
  );
}
