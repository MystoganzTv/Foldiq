// Free trial for copies installed from the Microsoft Store.
//
// Partner Center offers the app as a free trial with no time limit. The Store
// tells the app whether the current licence is a trial; the app itself decides
// what a trial may do. Here that is: scan and preview everything, organize up to
// TRIAL_FILE_LIMIT files in total, undo always works.
//
// Copies bought through Stripe (the NSIS installer) are never limited: they are
// not running from a Store package, so there is no Store licence to ask about.
//
// If the licence cannot be read (PowerShell blocked by policy, Store service
// unavailable, anything unexpected), Foldiq fails open and behaves as the full
// version. Locking out a paying customer is far worse than letting a trial user
// through.
const fs = require('fs');
const path = require('path');
const { execFile } = require('child_process');

const TRIAL_FILE_LIMIT = 100;
const STORE_PRODUCT_ID = '9N7XKX8G0M2P';
const STORE_PRODUCT_URL = `ms-windows-store://pdp/?productid=${STORE_PRODUCT_ID}`;
const LICENSE_TIMEOUT_MS = 20000;

// Windows PowerShell 5.1 (not pwsh) can call WinRT directly. A child process of
// a packaged app runs with the package's identity, so StoreContext.GetDefault()
// returns this app's licence.
const LICENSE_SCRIPT = `
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null = [Windows.Services.Store.StoreContext, Windows.Services.Store, ContentType = WindowsRuntime]
$asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
  $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
  $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation\`1'
} | Select-Object -First 1
$context = [Windows.Services.Store.StoreContext]::GetDefault()
$task = $asTask.MakeGenericMethod([Windows.Services.Store.StoreAppLicense]).Invoke($null, @($context.GetAppLicenseAsync()))
if (-not $task.Wait(15000)) { throw 'Timed out reading the Store licence' }
$license = $task.Result
[pscustomobject]@{
  isActive = [bool]$license.IsActive
  isTrial = [bool]$license.IsTrial
  skuStoreId = [string]$license.SkuStoreId
} | ConvertTo-Json -Compress
`;

function powershellPath(env = process.env) {
  const systemRoot = env.SystemRoot || env.SYSTEMROOT || 'C:\\Windows';
  return path.win32.join(systemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
}

function runLicenseScript() {
  const encoded = Buffer.from(LICENSE_SCRIPT, 'utf16le').toString('base64');
  return new Promise((resolve, reject) => {
    execFile(
      powershellPath(),
      ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', encoded],
      { windowsHide: true, timeout: LICENSE_TIMEOUT_MS, maxBuffer: 64 * 1024 },
      (error, stdout) => (error ? reject(error) : resolve(String(stdout))),
    );
  });
}

/// Reads the last JSON line PowerShell printed and turns it into a licence kind.
/// 'trial' only when the Store says so explicitly; everything else is 'full' or
/// 'unknown', and 'unknown' is treated as full.
function parseLicenseOutput(output) {
  const line = String(output || '').trim().split(/\r?\n/).filter(Boolean).at(-1);
  if (!line) return 'unknown';
  let value;
  try { value = JSON.parse(line); } catch { return 'unknown'; }
  if (!value || typeof value !== 'object') return 'unknown';
  if (value.isActive === true && value.isTrial === true) return 'trial';
  if (value.isActive === true && value.isTrial === false) return 'full';
  // An inactive licence (e.g. a refunded purchase) is the Store's problem to
  // enforce; Foldiq doesn't second-guess it.
  return 'unknown';
}

function normalizeState(value = {}) {
  const organized = Number.isFinite(value.organizedFiles) && value.organizedFiles > 0
    ? Math.floor(value.organizedFiles)
    : 0;
  return { organizedFiles: organized, purchased: value.purchased === true };
}

function readState(statePath) {
  try { return normalizeState(JSON.parse(fs.readFileSync(statePath, 'utf8'))); } catch { return normalizeState(); }
}

function writeState(statePath, state) {
  const normalized = normalizeState(state);
  fs.mkdirSync(path.dirname(statePath), { recursive: true });
  const temporary = `${statePath}.tmp`;
  fs.writeFileSync(temporary, JSON.stringify(normalized), 'utf8');
  fs.renameSync(temporary, statePath);
  return normalized;
}

function remainingFiles(state) {
  return Math.max(0, TRIAL_FILE_LIMIT - normalizeState(state).organizedFiles);
}

function isActionable(item) {
  return item && item.action !== 'skip' && item.included !== false;
}

/// Keeps the first `remaining` files that would be organized and leaves the rest
/// untouched (included: false, trialHeld: true). Files that stay put are always
/// safe; nothing is dropped from the plan, so the report still lists them.
function limitPlan(plan, remaining) {
  let allowance = Math.max(0, Math.floor(remaining));
  let held = 0;
  const limited = plan.map(item => {
    if (!isActionable(item)) return item;
    if (allowance > 0) {
      allowance--;
      return item;
    }
    held++;
    return { ...item, included: false, trialHeld: true };
  });
  return { plan: limited, held };
}

class TrialLicense {
  constructor({ statePath, isWindowsStore = process.windowsStore === true, checkLicense = runLicenseScript, log = () => {} }) {
    this.statePath = statePath;
    this.isWindowsStore = isWindowsStore;
    this.checkLicense = checkLicense;
    this.log = log;
    this.kind = isWindowsStore ? 'pending' : 'full';
    this.inFlight = null;
    this.lastCheckedAt = 0;
  }

  /// Asks the Store again. Cheap to call: concurrent calls share one check and
  /// repeated calls within `minIntervalMs` reuse the last answer.
  async refresh({ minIntervalMs = 0 } = {}) {
    if (!this.isWindowsStore) return this.kind;
    if (readState(this.statePath).purchased) {
      this.kind = 'full';
      return this.kind;
    }
    if (this.inFlight) return this.inFlight;
    if (this.kind !== 'pending' && Date.now() - this.lastCheckedAt < minIntervalMs) return this.kind;
    this.inFlight = (async () => {
      let kind = 'unknown';
      try {
        kind = parseLicenseOutput(await this.checkLicense());
      } catch (error) {
        this.log(`Store licence check failed: ${error?.message || error}`);
      }
      if (kind === 'full') {
        // Once bought, always bought: later check failures can't bring the limit back.
        writeState(this.statePath, { ...readState(this.statePath), purchased: true });
      }
      this.kind = kind;
      this.lastCheckedAt = Date.now();
      return kind;
    })().finally(() => { this.inFlight = null; });
    return this.inFlight;
  }

  async isTrial() {
    if (this.kind === 'pending') await this.refresh();
    return this.kind === 'trial';
  }

  async status() {
    const trial = await this.isTrial();
    const state = readState(this.statePath);
    return {
      isTrial: trial,
      limit: TRIAL_FILE_LIMIT,
      used: Math.min(state.organizedFiles, TRIAL_FILE_LIMIT),
      remaining: trial ? remainingFiles(state) : null,
    };
  }

  /// Returns the plan the trial is allowed to run. Unchanged for the full version.
  async limit(plan) {
    if (!(await this.isTrial())) return { plan, held: 0 };
    return limitPlan(plan, remainingFiles(readState(this.statePath)));
  }

  /// Counts files actually organized, so failed or held-back files never use up the trial.
  async record(organizedCount) {
    if (!(await this.isTrial())) return;
    const count = Number.isFinite(organizedCount) && organizedCount > 0 ? Math.floor(organizedCount) : 0;
    if (count === 0) return;
    const state = readState(this.statePath);
    writeState(this.statePath, { ...state, organizedFiles: state.organizedFiles + count });
  }
}

module.exports = {
  TRIAL_FILE_LIMIT,
  STORE_PRODUCT_URL,
  LICENSE_SCRIPT,
  TrialLicense,
  limitPlan,
  parseLicenseOutput,
  powershellPath,
  readState,
  remainingFiles,
  runLicenseScript,
  writeState,
};
