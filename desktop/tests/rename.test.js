const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('path');

const planner = require('../electron/services/planner');
const preferences = require('../electron/services/preferences');

const output = path.join(path.sep, 'library', 'Organized');
const source = path.join(path.sep, 'photos', 'Phone');

function file(name, date, extra = {}) {
  return {
    name,
    ext: path.extname(name).toLowerCase(),
    path: path.join(source, name),
    date: date ? new Date(date).toISOString() : null,
    size: 100,
    ...extra,
  };
}

function config(overrides = {}) {
  return {
    outputFolder: output,
    organizationMode: 'smart',
    groupByMonth: true,
    groupByDay: true,
    duplicateHandling: 'separate',
    renameByDate: true,
    ...overrides,
  };
}

test('dateFileStem uses local time and characters every file system accepts', () => {
  assert.equal(planner.dateFileStem(new Date(2024, 7, 14, 15, 32, 10)), '2024-08-14 15.32.10');
});

test('renaming is off by default and when the preference is missing', () => {
  assert.equal(preferences.normalizePreferences({}).renameByDate, false);
  assert.equal(preferences.normalizePreferences({ renameByDate: true }).renameByDate, true);
  const [move] = planner.buildPlan([file('IMG_4821.jpg', new Date(2024, 7, 14, 15, 32, 10))], config({ renameByDate: false }));
  assert.equal(path.basename(move.destPath), 'IMG_4821.jpg');
});

test('dated files are renamed and keep their extension', () => {
  const [move] = planner.buildPlan([file('IMG_4821.JPG', new Date(2024, 7, 14, 15, 32, 10))], config());
  assert.equal(path.basename(move.destPath), '2024-08-14 15.32.10.JPG');
  assert.equal(path.basename(path.dirname(move.destPath)), '2024-08-14');
});

test('Live Photo and RAW+JPEG pairs keep matching names', () => {
  const plan = planner.buildPlan([
    file('IMG_0001.MOV', new Date(2024, 7, 14, 15, 32, 11)),
    file('IMG_0001.HEIC', new Date(2024, 7, 14, 15, 32, 10)),
    file('DSC_0002.NEF', new Date(2024, 7, 15, 9, 0, 0)),
    file('DSC_0002.JPG', new Date(2024, 7, 15, 9, 0, 1)),
  ], config());
  const names = plan.map(move => path.basename(move.destPath));
  assert.deepEqual(names.slice(0, 2), ['2024-08-14 15.32.10.MOV', '2024-08-14 15.32.10.HEIC']);
  assert.equal(path.parse(names[2]).name, path.parse(names[3]).name);
});

test('photos taken in the same second get a numbered suffix instead of overwriting', () => {
  const second = new Date(2024, 7, 14, 15, 32, 10);
  const plan = planner.buildPlan([file('IMG_1.jpg', second), file('IMG_2.jpg', second)], config());
  assert.deepEqual(plan.map(move => path.basename(move.destPath)), ['2024-08-14 15.32.10.jpg', '2024-08-14 15.32.10_1.jpg']);
});

test('duplicates, set-aside files and undated files keep their original names', () => {
  const when = new Date(2024, 7, 14, 15, 32, 10);
  const plan = planner.buildPlan([
    file('copy.jpg', when, { isDuplicate: true }),
    file('review.jpg', when, { userSetAside: true }),
    file('nodate.jpg', null),
  ], config());
  assert.deepEqual(plan.map(move => path.basename(move.destPath)), ['copy.jpg', 'review.jpg', 'nodate.jpg']);

  const organizedTogether = planner.buildPlan([file('copy.jpg', when, { isDuplicate: true })], config({ duplicateHandling: 'organize' }));
  assert.equal(path.basename(organizedTogether[0].destPath), '2024-08-14 15.32.10.jpg');
});
