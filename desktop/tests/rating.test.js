const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const rating = require('../electron/services/rating');

const ONE_DAY = 24 * 60 * 60 * 1000;

test('a trial run of a few files does not earn an ask', () => {
  const state = rating.recordSuccessfulOrganization(undefined, 3);
  assert.equal(state.successfulOrganizations, 1);
  assert.equal(rating.shouldShowInvite(state), false);
});

test('a real run does earn an ask', () => {
  const state = rating.recordSuccessfulOrganization(undefined, 400);
  assert.equal(rating.shouldShowInvite(state), true);
});

test('runs accumulate, so several small runs eventually qualify', () => {
  let state;
  for (let i = 0; i < 10; i += 1) state = rating.recordSuccessfulOrganization(state, 5);
  assert.equal(state.organizedItems, 50);
  assert.equal(rating.shouldShowInvite(state), true);
});

test('a run that organized nothing is not counted', () => {
  const state = rating.recordSuccessfulOrganization(undefined, 0);
  assert.equal(state.successfulOrganizations, 0);
});

test('"not now" hides the invite for sixty days, not forever', () => {
  const now = Date.UTC(2026, 0, 1);
  const state = { ...rating.recordSuccessfulOrganization(undefined, 400), dismissedAt: now };

  assert.equal(rating.shouldShowInvite(state, now + 10 * ONE_DAY), false);
  assert.equal(rating.shouldShowInvite(state, now + 61 * ONE_DAY), true);
});

test('opening the review form stops the invite for good', () => {
  const state = { ...rating.recordSuccessfulOrganization(undefined, 400), reviewOpened: true };
  assert.equal(rating.shouldShowInvite(state, Date.now() + 5000 * ONE_DAY), false);
});

test('a corrupt or missing state file falls back to the defaults', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'foldiq-rating-'));
  const file = path.join(dir, 'nested', 'rating.json');

  assert.deepEqual(rating.readRatingState(file), rating.DEFAULTS);

  rating.writeRatingState(file, { successfulOrganizations: 2, organizedItems: 90, reviewOpened: false });
  assert.equal(rating.readRatingState(file).organizedItems, 90);

  fs.writeFileSync(file, 'not json');
  assert.deepEqual(rating.readRatingState(file), rating.DEFAULTS);

  fs.rmSync(dir, { recursive: true, force: true });
});

test('hostile values in the state file cannot switch the invite on', () => {
  const state = rating.normalizeRatingState({
    successfulOrganizations: Number.POSITIVE_INFINITY,
    organizedItems: '9999',
    dismissedAt: -5,
    reviewOpened: 'yes',
  });

  assert.deepEqual(state, rating.DEFAULTS);
  assert.equal(rating.shouldShowInvite(state), false);
});

test('the review form URL carries the source and review mode', () => {
  const url = new URL(rating.REVIEW_URL);
  assert.equal(url.origin + url.pathname, 'https://foldiq.app/contact');
  assert.equal(url.searchParams.get('source'), 'foldiq-windows-review');
  assert.equal(url.searchParams.get('kind'), 'review');
});
