import styles from './Sidebar.module.css';

const STEPS = [
  { id: 'welcome',  label: 'Select Folders', icon: '📁' },
  { id: 'scan',     label: 'Scan',           icon: '🔍' },
  { id: 'settings', label: 'Settings',       icon: '⚙️'  },
  { id: 'preview',  label: 'Preview',        icon: '👁'  },
  { id: 'apply',    label: 'Organizing',     icon: '⚡️'  },
  { id: 'report',   label: 'Report',         icon: '✅'  },
];

export default function Sidebar({ screen }) {
  const currentIdx = STEPS.findIndex(s => s.id === screen);

  return (
    <aside className={styles.sidebar}>
      <div className={styles.logo}>
        <span className={styles.logoIcon}>🗂</span>
        <span className={styles.logoText}>Foldiq</span>
      </div>

      <nav className={styles.steps}>
        {STEPS.map((step, idx) => {
          const done    = idx < currentIdx;
          const active  = idx === currentIdx;
          return (
            <div
              key={step.id}
              className={`${styles.step} ${active ? styles.active : ''} ${done ? styles.done : ''}`}
            >
              <div className={styles.stepDot}>
                {done ? '✓' : idx + 1}
              </div>
              <span className={styles.stepLabel}>{step.label}</span>
            </div>
          );
        })}
      </nav>

      <div className={styles.footer}>
        <span>Foldiq v1.0</span>
      </div>
    </aside>
  );
}
