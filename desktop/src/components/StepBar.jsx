import s from './StepBar.module.css';

const STEPS = [
  { id: 'scan',     label: 'Scan Results',          icon: <ScanIcon /> },
  { id: 'settings', label: 'Organization Settings', icon: <SettingsIcon /> },
  { id: 'preview',  label: 'Preview Changes',       icon: <PreviewIcon /> },
  { id: 'apply',    label: 'Applying',               icon: <ApplyIcon /> },
  { id: 'report',   label: 'Report',                 icon: <ReportIcon /> },
];

export default function StepBar({ screen }) {
  const currentIdx = STEPS.findIndex(s => s.id === screen);

  return (
    <div className={s.bar}>
      {STEPS.map((step, idx) => {
        const done   = idx < currentIdx;
        const active = idx === currentIdx;
        return (
          <div key={step.id} className={s.stepWrap}>
            {/* Connector left */}
            {idx > 0 && (
              <div className={`${s.line} ${done || active ? s.lineActive : ''}`} />
            )}

            <div className={`${s.step}`}>
              <div className={`${s.circle} ${active ? s.circleActive : ''} ${done ? s.circleDone : ''}`}>
                {done
                  ? <CheckIcon />
                  : <span className={active ? s.iconActive : s.iconInactive}>{step.icon}</span>
                }
              </div>
              <span className={`${s.label} ${active ? s.labelActive : ''} ${done ? s.labelDone : ''}`}>
                {step.label}
              </span>
            </div>

            {/* Connector right */}
            {idx < STEPS.length - 1 && (
              <div className={`${s.line} ${done ? s.lineActive : ''}`} />
            )}
          </div>
        );
      })}
    </div>
  );
}

// ── SVG Icons (SF Symbol style) ───────────────────────────────────────────────
function ScanIcon() {
  return (
    <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <circle cx="11" cy="11" r="8"/><line x1="21" y1="21" x2="16.65" y2="16.65"/>
    </svg>
  );
}
function SettingsIcon() {
  return (
    <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <line x1="4" y1="6" x2="20" y2="6"/><line x1="8" y1="12" x2="20" y2="12"/><line x1="4" y1="18" x2="16" y2="18"/>
      <circle cx="4" cy="12" r="1.5" fill="currentColor" stroke="none"/>
      <circle cx="20" cy="18" r="1.5" fill="currentColor" stroke="none"/>
    </svg>
  );
}
function PreviewIcon() {
  return (
    <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"/><circle cx="12" cy="12" r="3"/>
    </svg>
  );
}
function ApplyIcon() {
  return (
    <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <polyline points="23 4 23 10 17 10"/><polyline points="1 20 1 14 7 14"/>
      <path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15"/>
    </svg>
  );
}
function ReportIcon() {
  return (
    <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"/><polyline points="22 4 12 14.01 9 11.01"/>
    </svg>
  );
}
function CheckIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="white" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
      <polyline points="20 6 9 17 4 12"/>
    </svg>
  );
}
