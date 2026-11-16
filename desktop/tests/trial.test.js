const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const trial = require('../electron/services/trial');

function tempStatePath() {
  return path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'foldiq-trial-')), 'trial.json');
}

function plan(count, extra = []) {
  return [
    ...Array.from({ length: count }, (_, index) => ({ name: `IMG_${index}.jpg`, action: 'move' })),
    ...extra,
  ];
}

const TRIAL_OUTPUT = '{"isActive":true,"isTrial":true,"skuStoreId":"9N7XKX8G0M2P/0010"}';
const FULL_OUTPUT = '{"isActive":true,"isTrial":false,"skuStoreId":"9N7XKX8G0M2P/0010"}';

test('the Store licence output is read as trial, full or unknown', () => {
  assert.equal(trial.parseLicenseOutput(TRIAL_OUTPUT), 'trial');
  assert.equal(trial.parseLicenseOutput(`WARNING: something\r\n${FULL_OUTPUT}\r\n`), 'full');
  assert.equal(trial.parseLicenseOutput('{"isActive":false,"isTrial":true}'), 'unknown');
  assert.equal(trial.parseLicenseOutput('not json'), 'unknown');
  assert.equal(trial.parseLicenseOutput(''), 'unknown');
});

test('limitPlan keeps the first files and leaves the rest untouched', () => {
  const skipped = { name: 'dup.jpg', action: 'skip' };
  const excluded = { name: 'left.jpg', action: 'move', included: false };
  const result = trial.limitPlan(plan(5, [skipped, excluded]), 3);
  assert.equal(result.held, 2);
  assert.equal(result.plan.length, 7);
  assert.deepEqual(result.plan.slice(0, 3).map(item => item.included), [undefined, undefined, undefined]);
  assert.deepEqual(result.plan.slice(3, 5).map(item => [item.included, item.trialHeld]), [[false, true], [false, true]]);
  assert.equal(result.plan[5], skipped);
  assert.equal(result.plan[6], excluded);
});

test('Stripe installs are never limited and never ask the Store', async () => {
  let asked = false;
  const license = new trial.TrialLicense({
    statePath: tempStatePath(),
    isWindowsStore: false,
    checkLicense: async () => { asked = true; return TRIAL_OUTPUT; },
  });
  const result = await license.limit(plan(500));
  assert.equal(result.held, 0);
  assert.equal(asked, false);
  assert.equal((await license.status()).isTrial, false);
});

test('a trial organizes 100 files in total across runs', async () => {
  const statePath = tempStatePath();
  const license = new trial.TrialLicense({ statePath, isWindowsStore: true, checkLicense: async () => TRIAL_OUTPUT });

  const first = await license.limit(plan(60));
  assert.equal(first.held, 0);
  await license.record(60);

  const second = await license.limit(plan(60));
  assert.equal(second.held, 20);
  await license.record(40);

  const status = await license.status();
  assert.deepEqual(status, { isTrial: true, limit: 100, used: 100, remaining: 0 });
  assert.equal((await license.limit(plan(10))).held, 10);
});

test('files that failed to organize do not use up the trial', async () => {
  const statePath = tempStatePath();
  const license = new trial.TrialLicense({ statePath, isWindowsStore: true, checkLicense: async () => TRIAL_OUTPUT });
  await license.record(0);
  await license.record(-5);
  assert.equal((await license.status()).remaining, 100);
});

test('if the licence cannot be read, Foldiq behaves as the full version', async () => {
  const messages = [];
  const license = new trial.TrialLicense({
    statePath: tempStatePath(),
    isWindowsStore: true,
    checkLicense: async () => { throw new Error('PowerShell blocked'); },
    log: message => messages.push(message),
  });
  assert.equal((await license.limit(plan(500))).held, 0);
  assert.match(messages[0], /PowerShell blocked/);
});

test('once bought, a later failed check cannot bring the limit back', async () => {
  const statePath = tempStatePath();
  let output = FULL_OUTPUT;
  const license = new trial.TrialLicense({ statePath, isWindowsStore: true, checkLicense: async () => output });
  assert.equal(await license.refresh(), 'full');
  assert.equal(trial.readState(statePath).purchased, true);

  output = TRIAL_OUTPUT;
  const later = new trial.TrialLicense({ statePath, isWindowsStore: true, checkLicense: async () => output });
  assert.equal(await later.isTrial(), false);
  assert.equal((await later.limit(plan(500))).held, 0);
});

test('buying during a session unlocks on the next refresh', async () => {
  let output = TRIAL_OUTPUT;
  const license = new trial.TrialLicense({ statePath: tempStatePath(), isWindowsStore: true, checkLicense: async () => output });
  assert.equal(await license.isTrial(), true);
  output = FULL_OUTPUT;
  await license.refresh({ minIntervalMs: 0 });
  assert.equal(await license.isTrial(), false);
});

test('repeated refreshes share one Store check', async () => {
  let calls = 0;
  const license = new trial.TrialLicense({
    statePath: tempStatePath(),
    isWindowsStore: true,
    checkLicense: async () => { calls++; return TRIAL_OUTPUT; },
  });
  await Promise.all([license.refresh(), license.refresh(), license.isTrial()]);
  await license.refresh({ minIntervalMs: 60000 });
  assert.equal(calls, 1);
});

test('a damaged state file starts the trial from zero instead of crashing', async () => {
  const statePath = tempStatePath();
  fs.writeFileSync(statePath, '{broken');
  assert.deepEqual(trial.readState(statePath), { organizedFiles: 0, purchased: false });
});

test('the licence script uses Windows PowerShell and the WinRT Store API', () => {
  assert.match(trial.powershellPath({ SystemRoot: 'C:\\Windows' }), /System32\\WindowsPowerShell\\v1\.0\\powershell\.exe$/);
  assert.match(trial.LICENSE_SCRIPT, /StoreContext\]::GetDefault\(\)/);
  assert.match(trial.LICENSE_SCRIPT, /'IAsyncOperation`1'/);
  assert.equal(trial.STORE_PRODUCT_URL, 'ms-windows-store://pdp/?productid=9N7XKX8G0M2P');
});
