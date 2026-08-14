import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const migration = await readFile(new URL('../../database/migrations/202608140001_foldiq_metrics.sql', import.meta.url), 'utf8');

test('metrics storage contains only aggregate product and Apple reporting tables', () => {
  assert.match(migration, /create table if not exists product_events/i);
  assert.match(migration, /create table if not exists apple_analytics_rows/i);
  assert.match(migration, /create table if not exists apple_analytics_imports/i);
  assert.doesNotMatch(migration, /customer|email|filename|file_path|photo_metadata/i);
});

test('metrics schema avoids public security-definer functions', () => {
  assert.doesNotMatch(migration, /security\s+definer/i);
});
