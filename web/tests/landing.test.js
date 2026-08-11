import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const html = await readFile(new URL('../index.html', import.meta.url), 'utf8');

test('download navigation targets the purchase section with sticky-nav spacing', () => {
  assert.match(html, /<a class="btn-nav" href="#download">/);
  assert.match(html, /<section class="cta-section" id="download">/);
  assert.match(html, /\.cta-section\s*\{[^}]*scroll-margin-top:\s*64px;/s);
  assert.match(html, /target\.scrollIntoView\(\{ behavior: 'smooth', block: 'start' \}\)/);
  const sizedScreenshots = html.match(/<img src="screenshots\/[^"]+"[^>]+width="1440" height="900"/g) ?? [];
  assert.equal(sizedScreenshots.length, 5, 'lazy screenshots must reserve space before they load');
});

test('the Foldiq brand icon appears only once on the landing page', () => {
  const brandIcons = html.match(/<img src="icon\.png" alt="Foldiq"/g) ?? [];
  assert.equal(brandIcons.length, 1);
  assert.doesNotMatch(html, /class="footer-logo"/);
});
