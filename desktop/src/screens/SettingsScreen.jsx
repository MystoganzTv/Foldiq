import s from './Screen.module.css';

export default function SettingsScreen({ go, config, setConfig }) {
  async function pickOutput() {
    const folder = await window.foldiq.selectOutput();
    if (folder) setConfig(c => ({ ...c, outputFolder: folder }));
  }

  function toggle(key) {
    setConfig(c => ({ ...c, [key]: !c[key] }));
  }

  return (
    <div className={s.screen}>
      <div className={s.header}>
        <h1 className={s.title}>Organization Settings</h1>
        <p className={s.sub}>Choose how Foldiq structures your files.</p>
      </div>

      <div className={s.form}>
        {/* Output folder */}
        <div className={s.formGroup}>
          <label className={s.label}>Output Folder</label>
          <div className={s.folderPicker}>
            <span className={s.folderPickerPath}>{config.outputFolder || 'Not selected'}</span>
            <button className={s.btnOutline} onClick={pickOutput}>Browse…</button>
          </div>
        </div>

        {/* Folder structure */}
        <div className={s.formGroup}>
          <label className={s.label}>Folder Structure</label>
          <div className={s.preview}>
            <code>
              {[
                '2024/',
                config.groupByMonth ? '  2024-08 August/' : null,
                config.groupByDay   ? '    2024-08-14/' : null,
                '      photo.jpg',
              ].filter(Boolean).join('\n')}
            </code>
          </div>
        </div>

        {/* Toggles */}
        <div className={s.formGroup}>
          <div className={s.toggle} onClick={() => toggle('groupByMonth')}>
            <div className={`${s.toggleSwitch} ${config.groupByMonth ? s.on : ''}`} />
            <div>
              <div className={s.toggleLabel}>Group by Month</div>
              <div className={s.toggleSub}>Add a month subfolder (e.g. 2024-08 August)</div>
            </div>
          </div>
          <div className={s.toggle} onClick={() => toggle('groupByDay')}>
            <div className={`${s.toggleSwitch} ${config.groupByDay ? s.on : ''}`} />
            <div>
              <div className={s.toggleLabel}>Group by Day</div>
              <div className={s.toggleSub}>Add a date subfolder (e.g. 2024-08-14)</div>
            </div>
          </div>
          <div className={s.toggle} onClick={() => toggle('copyMode')}>
            <div className={`${s.toggleSwitch} ${config.copyMode ? s.on : ''}`} />
            <div>
              <div className={s.toggleLabel}>Copy instead of Move</div>
              <div className={s.toggleSub}>Keep originals in place (uses more disk space)</div>
            </div>
          </div>
          <div className={s.toggle} onClick={() => toggle('skipDuplicates')}>
            <div className={`${s.toggleSwitch} ${config.skipDuplicates ? s.on : ''}`} />
            <div>
              <div className={s.toggleLabel}>Skip Duplicates</div>
              <div className={s.toggleSub}>Don't move files with identical content</div>
            </div>
          </div>
        </div>
      </div>

      <div className={s.actions}>
        <button className={s.btnSecondary} onClick={() => go('scan')}>← Back</button>
        <button
          className={s.btnPrimary}
          disabled={!config.outputFolder}
          onClick={() => go('preview')}
        >
          Preview Changes →
        </button>
      </div>
    </div>
  );
}
