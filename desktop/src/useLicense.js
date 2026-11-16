import { useEffect, useState } from 'react';

// Free-trial status for Microsoft Store copies. `license` is null until known;
// for the full version (and Stripe installs) `license.isTrial` is false.
// Re-checked when the window regains focus, so buying Foldiq in the Store app
// unlocks it without restarting.
export default function useLicense() {
  const [license, setLicense] = useState(null);

  useEffect(() => {
    let active = true;
    const load = refresh => window.foldiq.getLicense(refresh)
      .then(value => { if (active) setLicense(value); })
      .catch(() => {});
    const onFocus = () => load(true);
    load(false);
    window.addEventListener('focus', onFocus);
    return () => {
      active = false;
      window.removeEventListener('focus', onFocus);
    };
  }, []);

  return license;
}

export function buyFullVersion() {
  window.foldiq.buyFullVersion().catch(() => {});
}
