// Windows has no StoreKit dialog, so Foldiq never asked for anything here at
// all. This is the equivalent ask: a plain, dismissible invitation shown on the
// final report once the app has actually done real work for the person.
const fs = require('fs');
const path = require('path');

const DEFAULTS = Object.freeze({
  successfulOrganizations: 0,
  organizedItems: 0,
  dismissedAt: 0,
  reviewOpened: false,
});

/// One clean run is enough on Windows — unlike the Mac there is no system
/// dialog competing for the same moment.
const MINIMUM_SUCCESSFUL_ORGANIZATIONS = 1;
/// A handful of test files is a trial run, not a win worth celebrating.
const MINIMUM_ORGANIZED_ITEMS = 25;
/// "Not now" means not now, not never.
const DAYS_HIDDEN_AFTER_DISMISSAL = 60;
const ONE_DAY = 24 * 60 * 60 * 1000;

const REVIEW_URL = 'https://foldiq.app/contact?source=foldiq-windows-review&kind=review';

function positiveInteger(value) {
  return Number.isFinite(value) && value > 0 ? Math.floor(value) : 0;
}

function normalizeRatingState(value = {}) {
  return {
    successfulOrganizations: positiveInteger(value.successfulOrganizations),
    organizedItems: positiveInteger(value.organizedItems),
    dismissedAt: positiveInteger(value.dismissedAt),
    reviewOpened: value.reviewOpened === true,
  };
}

function recordSuccessfulOrganization(state, itemCount) {
  const current = normalizeRatingState(state);
  const items = positiveInteger(itemCount);
  if (items === 0) return current;
  return {
    ...current,
    successfulOrganizations: current.successfulOrganizations + 1,
    organizedItems: current.organizedItems + items,
  };
}

function shouldShowInvite(state, now = Date.now()) {
  const current = normalizeRatingState(state);
  if (current.reviewOpened) return false;
  if (current.successfulOrganizations < MINIMUM_SUCCESSFUL_ORGANIZATIONS) return false;
  if (current.organizedItems < MINIMUM_ORGANIZED_ITEMS) return false;
  if (current.dismissedAt === 0) return true;
  return now - current.dismissedAt >= DAYS_HIDDEN_AFTER_DISMISSAL * ONE_DAY;
}

function readRatingState(filePath) {
  try {
    return normalizeRatingState(JSON.parse(fs.readFileSync(filePath, 'utf8')));
  } catch {
    return { ...DEFAULTS };
  }
}

function writeRatingState(filePath, value) {
  const normalized = normalizeRatingState(value);
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  const tempPath = `${filePath}.${process.pid}.tmp`;
  fs.writeFileSync(tempPath, JSON.stringify(normalized, null, 2), { encoding: 'utf8', flag: 'w' });
  fs.renameSync(tempPath, filePath);
  return normalized;
}

module.exports = {
  DEFAULTS,
  MINIMUM_ORGANIZED_ITEMS,
  MINIMUM_SUCCESSFUL_ORGANIZATIONS,
  DAYS_HIDDEN_AFTER_DISMISSAL,
  REVIEW_URL,
  normalizeRatingState,
  recordSuccessfulOrganization,
  shouldShowInvite,
  readRatingState,
  writeRatingState,
};
