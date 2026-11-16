import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const html = await readFile(new URL('../index.html', import.meta.url), 'utf8');
const privacy = await readFile(new URL('../privacy-policy.html', import.meta.url), 'utf8');
const analytics = await readFile(new URL('../analytics.js', import.meta.url), 'utf8');
const contact = await readFile(new URL('../contact.html', import.meta.url), 'utf8');
const success = await readFile(new URL('../success.html', import.meta.url), 'utf8');
const owner = await readFile(new URL('../owner.html', import.meta.url), 'utf8');
const trackedPages = await Promise.all([
  'index.html',
  'contact.html',
  'privacy-policy.html',
  'terms.html',
  'success.html',
].map(name => readFile(new URL(`../${name}`, import.meta.url), 'utf8')));

test('download navigation targets the purchase section with sticky-nav spacing', () => {
  assert.match(html, /<a class="btn-nav" href="#download">/);
  assert.match(html, /<section class="cta-section" id="download">/);
  assert.match(html, /\.cta-section\s*\{[^}]*scroll-margin-top:\s*64px;/s);
  assert.match(html, /target\.scrollIntoView\(\{ behavior: 'smooth', block: 'start' \}\)/);
});

test('the Foldiq brand icon appears only once on the landing page', () => {
  const brandIcons = html.match(/<img src="icon\.png" alt="Foldiq"/g) ?? [];
  assert.equal(brandIcons.length, 1);
  assert.doesNotMatch(html, /class="footer-logo"/);
});

test('footer exposes only the private Extranet entry point', () => {
  assert.match(html, /<a href="\/owner" rel="nofollow" aria-label="Private owner extranet">Extranet<\/a>/);
  assert.match(owner, /<meta name="robots" content="noindex,nofollow,noarchive">/);
  assert.match(owner, /PRIVATE EXTRANET/);
  assert.doesNotMatch(html, /Owner Metrics|Owner Dashboard/);
});

test('privacy copy covers optional GPS lookup on both platforms', () => {
  assert.match(html, /Windows rounds it to about 1 km before using OpenStreetMap/);
  assert.match(html, /Apple platforms use Apple's system service/);
  assert.doesNotMatch(html, /Mac &amp; Windows · Local-only/);
  assert.match(privacy, /two decimal places \(roughly 1 km precision\)/);
  assert.match(privacy, /OpenStreetMap Nominatim/);
  assert.match(privacy, /Photos, videos, filenames, folder paths, and other media metadata are not included/);
});

test('cookie-free analytics is disclosed and strips purchase tokens', () => {
  for (const page of trackedPages) {
    assert.match(page, /<script defer src="\/analytics\.js"><\/script>/);
  }
  assert.match(analytics, /script\.src = '\/_vercel\/insights\/script\.js'/);
  assert.match(analytics, /url\.search = ''/);
  assert.match(analytics, /url\.hash = ''/);
  assert.match(privacy, /Vercel Web Analytics/);
  assert.match(privacy, /does not use cookies/);
  assert.match(privacy, /Stripe checkout session identifiers are not included/);
  assert.match(html, /anonymous, cookie-free traffic/);
});

test('landing screenshots preserve their native aspect ratio', () => {
  assert.match(html, /\.screenshot-frame img\s*\{[^}]*height:\s*auto;/s);
  const slides = [...html.matchAll(/<img src="\/screenshots\/product\/([^"/]+)\.webp"[^>]+width="1728" height="936" loading="lazy"/g)];
  assert.deepEqual(slides.map(([, name]) => name), ['scan', 'rules', 'preview', 'duplicates', 'report'],
    'all five slides must reserve space before they load');
});

test('social metadata points to the production domain', () => {
  assert.match(html, /<meta property="og:url" content="https:\/\/foldiq\.app\/"/);
  assert.match(html, /<link rel="canonical" href="https:\/\/foldiq\.app\/"/);
  assert.doesNotMatch(html, /mystoganztv\.github\.io/);
});

test('support form works without a local email client and strips diagnostic fragments', () => {
  assert.doesNotMatch(contact, /action="mailto:/);
  assert.match(contact, /fetch\('\/api\/support'/);
  assert.match(contact, /#diagnostic=/);
  assert.match(contact, /history\.replaceState/);
  assert.match(contact, /You do not need Outlook/);
});

test('purchase success support link does not require a local email app', () => {
  assert.match(success, /href="\/contact\.html"/);
  assert.doesNotMatch(success, /mailto:support@foldiq\.app/);
});

test('owner dashboard distinguishes business KPIs from diagnostics and snapshots', () => {
  assert.match(owner, /Stripe · live/);
  assert.match(owner, /Apple · snapshot/);
  assert.match(owner, /Vercel · snapshot/);
  assert.match(owner, /GitHub installer requests/);
  assert.match(owner, /Live · not unique/);
  assert.match(owner, /Purchases and downloads, kept separate/);
  assert.match(owner, /Where the money is now/);
  assert.match(owner, /Confirmed external bank deposits/);
  assert.match(owner, /intentionally not added together/);
  assert.doesNotMatch(owner, /combined-payout|Estimated platform payout|Apple estimate \+ Stripe net/);
  assert.match(owner, /discovery categories, not affiliate payments/);
  assert.doesNotMatch(owner, /Paid platform acquisitions/);
  assert.doesNotMatch(owner, /Combined gross sales/);
  assert.doesNotMatch(owner, /Active opted-in installs[\s\S]*>Off</);
  assert.match(owner, /No customer identities, filenames, paths, photo metadata, or media content/);
});
