import s from '../screens/Screen.module.css';
import { buyFullVersion } from '../useLicense';

// Shown only to Microsoft Store copies running on a free-trial licence.
export default function TrialCard({ title, children }) {
  return (
    <div className={s.trialCard}>
      <div>
        <strong>{title}</strong>
        <p>{children}</p>
      </div>
      <button className={s.btnPrimary} onClick={buyFullVersion}>Buy Foldiq</button>
    </div>
  );
}

export function trialSummary(license) {
  if (!license?.isTrial) return '';
  const remaining = license.remaining ?? 0;
  return `${remaining.toLocaleString()} of ${license.limit.toLocaleString()} free files left`;
}
