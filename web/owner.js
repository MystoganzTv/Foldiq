const $ = selector => document.querySelector(selector);
const money = cents => cents == null ? 'Unavailable' : new Intl.NumberFormat('en-US', {
  style: 'currency', currency: 'USD', minimumFractionDigits: 2,
}).format(cents / 100);
const number = value => new Intl.NumberFormat('en-US').format(value ?? 0);
const escape = value => String(value ?? '')
  .replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;')
  .replaceAll('"', '&quot;').replaceAll("'", '&#039;');
const row = (label, value, note = '') => `<div class="row"><span>${escape(label)}${note ? `<small>${escape(note)}</small>` : ''}</span><strong>${escape(value)}</strong></div>`;

function dateLabel(value, options = { month: 'short', day: 'numeric', year: 'numeric' }) {
  if (!value) return '—';
  const normalized = /^\d{4}-\d{2}-\d{2}$/.test(value) ? `${value}T12:00:00Z` : value;
  return new Date(normalized).toLocaleDateString('en-US', options);
}

function renderBars(target, items, labelKey, valueKey, format = value => value) {
  if (!items?.length) {
    target.innerHTML = '<p class="empty">No data yet.</p>';
    return;
  }
  const max = Math.max(...items.map(item => Number(item[valueKey]) || 0), 1);
  target.innerHTML = items.map(item => {
    const value = Number(item[valueKey]) || 0;
    return `<div class="rank-item"><div><span>${escape(item[labelKey])}</span><strong>${escape(format(value, item))}</strong></div><i><b style="width:${Math.max(4, value / max * 100)}%"></b></i></div>`;
  }).join('');
}

function countryName(code) {
  if (!code || code === 'Unknown') return 'Unknown';
  try { return new Intl.DisplayNames(['en'], { type: 'region' }).of(code) || code; }
  catch { return code; }
}

function renderSalesChart(items = []) {
  const target = $('#sales-chart');
  if (!items.length) {
    target.innerHTML = '<p class="empty">No external purchase history available.</p>';
    return;
  }
  const max = Math.max(...items.map(item => item.grossCents), 1);
  target.innerHTML = items.map(item => `<div class="bar-column" title="${escape(`${dateLabel(item.date)} · ${item.purchases} purchase(s) · ${money(item.grossCents)}`)}"><div class="bar-value">${escape(money(item.grossCents))}</div><i style="height:${Math.max(8, item.grossCents / max * 100)}%"></i><span>${escape(dateLabel(item.date, { month: 'short', day: 'numeric' }))}</span></div>`).join('');
}

function funnelStep(label, value, note, state = '') {
  return `<div class="funnel-step ${state}"><span>${escape(label)}</span><strong>${escape(value)}</strong><small>${escape(note)}</small></div>`;
}

function renderDashboard(data) {
  const win = data.windows || {};
  const appleState = data.apple || {};
  const apple = data.apple?.auditedSnapshot || {};
  const downloads = data.downloads || {};
  const product = data.product || {};
  const website = data.website?.snapshot || {};
  const windowsPurchases = win.externalPurchases ?? win.externalCustomers ?? 0;
  const verifiedWindowsPurchases = win.verifiedWindowsPurchases ?? 0;
  const legacyDirectMacPurchases = win.legacyDirectMacPurchases ?? 0;
  const stripePayoutCents = win.externalNetCents;
  const applePayoutCents = apple.proceedsUSD == null ? null : Math.round(apple.proceedsUSD * 100);
  const combinedPayoutCents = stripePayoutCents == null || applePayoutCents == null
    ? null
    : stripePayoutCents + applePayoutCents;

  $('#updated').textContent = `Refreshed ${new Date(data.generatedAt).toLocaleString()} · Stripe and GitHub are live${appleState.live ? ' · Apple is live' : ''}`;

  $('#direct-purchases').textContent = number(windowsPurchases);
  $('#direct-purchases-note').textContent = `${number(legacyDirectMacPurchases)} legacy Mac + ${number(verifiedWindowsPurchases)} Windows`;
  $('#windows-purchases').textContent = number(verifiedWindowsPurchases);
  $('#mac-downloads').textContent = number(apple.downloads);
  $('#apple-conversion').textContent = apple.conversionRate == null ? '—' : `${apple.conversionRate}%`;
  $('#apple-period').textContent = `${number(apple.pageViews)} page views · ${apple.period || 'snapshot'}`;
  $('#combined-payout').textContent = money(combinedPayoutCents);
  $('#apple-payout').textContent = money(applePayoutCents);
  $('#stripe-payout').textContent = money(stripePayoutCents);
  $('#windows-tax').textContent = money(win.customerTaxCollectedCents ?? 0);
  $('#windows-tax-note').textContent = win.automaticTaxEnabled
    ? 'Automatic tax is enabled in Checkout'
    : 'Not currently collected by Checkout';
  if (appleState.live) {
    $('#apple-source').innerHTML = '<i class="dot live-dot"></i>Apple · live';
    $('#apple-status').textContent = apple.capturedAt ? `Live · processed ${dateLabel(apple.capturedAt)}` : 'Live';
    $('#apple-status').classList.remove('snapshot');
    $('#apple-status').classList.add('live');
  } else if (appleState.awaitingData) {
    $('#apple-source').innerHTML = '<i class="dot setup-dot"></i>Apple · awaiting first report';
    $('#apple-status').textContent = 'Connected · awaiting Apple data';
  } else {
    $('#apple-status').textContent = apple.capturedAt ? `Captured ${dateLabel(apple.capturedAt)}` : 'Audited snapshot';
  }

  $('#windows-finance').innerHTML = [
    row('Direct gross sales', money(win.externalGrossCents)),
    row('Stripe fees', money(win.externalFeesCents)),
    row('Net after Stripe processing fees', money(win.externalNetCents), 'Before your income or business taxes'),
    row('Customer sales tax collected', money(win.customerTaxCollectedCents ?? 0), win.automaticTaxEnabled ? 'Automatic tax enabled' : 'Automatic tax is not enabled'),
    row('Refunded purchases', number(win.refundedPurchases), money(win.refundedCents)),
    row('Average order value', win.externalCustomers ? money(Math.round(win.externalGrossCents / win.externalCustomers)) : '—'),
  ].join('');

  $('#windows-movement').innerHTML = [
    row('Direct purchases · all time', number(windowsPurchases)),
    row('Legacy direct Mac purchases', number(legacyDirectMacPurchases), 'Later fulfilled with App Store promo codes'),
    row('Verified Windows purchases', number(verifiedWindowsPurchases)),
    row('New purchases · last 30 days', number(win.externalCustomers30d)),
    row('New purchases · last 7 days', number(win.externalCustomers7d)),
    row('Verified buyer downloads', number(win.externalBuyerDownloads), 'tracked from Aug 14'),
    row('Purchase → download', win.downloadConversionRate == null ? 'Not enough data' : `${win.downloadConversionRate}%`, `${number(win.trackingEligibleCustomers)} eligible purchases`),
  ].join('');

  renderSalesChart(win.daily);
  renderBars($('#windows-countries'), (win.countries || []).map(item => ({ ...item, country: countryName(item.country) })), 'country', 'customers', value => `${number(value)} purchase${value === 1 ? '' : 's'}`);
  $('#recent-purchases').innerHTML = win.recentPurchases?.length
    ? win.recentPurchases.map(item => `<tr><td>${escape(dateLabel(item.date))}</td><td>${escape(countryName(item.country))}</td><td>${escape(money(item.grossCents))}</td><td>${escape(money(item.netCents))}</td><td>${number(item.downloadCount)}</td></tr>`).join('')
    : '<tr><td colspan="5" class="empty">No purchase data.</td></tr>';

  const eligible = win.trackingEligibleCustomers || 0;
  const buyerDownloads = win.externalBuyerDownloads || 0;
  $('#windows-funnel').innerHTML = [
    funnelStep('Eligible purchases', number(eligible), 'Purchased after tracking began'),
    funnelStep('Verified downloads', number(buyerDownloads), win.downloadConversionRate == null ? 'Waiting for a new purchase' : `${win.downloadConversionRate}% of eligible purchases`),
    funnelStep('Opted-in active installs', product.configured ? number(product.activeInstalls) : 'Not connected', 'Anonymous and optional', product.configured ? '' : 'disabled'),
    funnelStep('Successful organizations', product.configured ? number(product.byEvent?.apply_completed?.successful || 0) : 'Not connected', 'The strongest product-value signal', product.configured ? '' : 'disabled'),
  ].join('<div class="funnel-arrow">→</div>');
  $('#tracking-note').textContent = `Reliable buyer-download tracking began ${dateLabel(win.downloadTrackingSince?.slice(0, 10))}. GitHub's earlier requests cannot be assigned to unique customers.`;

  $('#apple-funnel').innerHTML = [
    row('Impressions', number(apple.impressions)),
    row('Product page views', number(apple.pageViews)),
    row('Store conversion rate', apple.conversionRate == null ? '—' : `${apple.conversionRate}%`),
    row('First-time downloads', number(apple.downloads)),
    row('Redownloads', number(apple.redownloads)),
  ].join('');
  $('#apple-commerce').innerHTML = [
    ...(apple.purchases == null ? [] : [row('App purchases reported', number(apple.purchases), 'Refunds may appear as negative values')]),
    row('Customer spending reported by Apple', money((apple.salesUSD || 0) * 100), 'What customers were billed; not a buyer count'),
    row('Estimated amount Apple owes you', money((apple.proceedsUSD || 0) * 100), 'After Apple commission and applicable transaction taxes'),
    row('Apple commission, transaction taxes & adjustments', money(((apple.salesUSD || 0) - (apple.proceedsUSD || 0)) * 100), 'Difference between customer spending and your estimated payout'),
    row('Final bank payout', 'Available after Apple closes the fiscal month', 'May differ because of exchange rates, withholding or bank fees'),
    row('Updates', number(apple.updates)),
    row('Snapshot period', apple.period || '—'),
  ].join('');
  $('#apple-usage').innerHTML = [
    row('Sessions', apple.sessions == null ? 'Awaiting live reports' : number(apple.sessions), 'Apple opt-in and privacy thresholds apply'),
    row('Average session duration', apple.averageSessionSeconds == null ? '—' : `${number(apple.averageSessionSeconds)} sec`),
    row('Crashes', apple.crashes == null ? '—' : number(apple.crashes)),
    row('Installations', apple.installs == null ? '—' : number(apple.installs)),
    row('Deletions', apple.deletions == null ? '—' : number(apple.deletions)),
  ].join('');
  renderBars($('#apple-sources'), apple.proceedsBySource, 'source', 'usd', value => money(value * 100));
  renderBars($('#apple-referrers'), apple.proceedsByReferrer, 'referrer', 'usd', value => money(value * 100));
  renderBars($('#apple-territories'), apple.proceedsByTerritory, 'territory', 'usd', value => money(value * 100));

  $('#website-summary').innerHTML = [
    `<div><strong>${number(website.visitors)}</strong><span>Visitors</span></div>`,
    `<div><strong>${number(website.pageViews)}</strong><span>Page views</span></div>`,
    `<div><strong>${website.bounceRate == null ? '—' : `${website.bounceRate}%`}</strong><span>Bounce rate</span></div>`,
  ].join('');
  $('#website-period').textContent = website.period || 'Last captured period';
  renderBars($('#website-referrers'), website.referrers, 'label', 'visitors', value => `${number(value)} visitor${value === 1 ? '' : 's'}`);
  renderBars($('#website-countries'), website.countries, 'label', 'visitors', value => `${number(value)} visitor${value === 1 ? '' : 's'}`);
  renderBars($('#website-devices'), website.devices, 'label', 'share', value => `${number(value)}%`);

  $('#release-downloads').innerHTML = downloads.releases?.length
    ? downloads.releases.map(item => `<div><span>${escape(item.tag)}</span><strong>${number(item.downloads)}</strong><small>${escape(dateLabel(item.publishedAt))}</small></div>`).join('')
    : '<p class="empty">GitHub data unavailable.</p>';

  if (product.configured) {
    $('#product-source').innerHTML = '<i class="dot live-dot"></i>Product usage · live';
    $('#product-status').textContent = 'Live · opted-in only';
    $('#product-status').classList.add('live');
    $('#product-detail').innerHTML = `<div class="mini-metrics"><div><strong>${number(product.activeInstalls)}</strong><span>Active installs · 30 days</span></div><div><strong>${number(product.events)}</strong><span>Measured operations</span></div><div><strong>${product.successRate == null ? '—' : `${product.successRate}%`}</strong><span>Operation success</span></div></div><div class="rows">${Object.entries(product.byEvent || {}).map(([name, value]) => row(name.replaceAll('_', ' '), `${number(value.successful)} / ${number(value.total)} successful`)).join('')}</div>`;
  } else {
    $('#product-status').textContent = 'Not connected';
    $('#product-detail').innerHTML = '<div><h3>Worth enabling when we ship the next builds</h3><p class="muted">This would show whether scanning, organization, and Undo succeed; broad duration and item-count ranges; app version; platform; and active opted-in installs. It never includes photos, filenames, paths, dates, locations, or media metadata. To activate it, we connect the private Foldiq metrics database, verify retention and security, then release Mac and Windows builds. Data appears only for users who explicitly opt in.</p></div><span class="status">No data collected</span>';
  }

  const errors = [win.error, downloads.error, product.error, appleState.error].filter(Boolean);
  $('#notice').hidden = !errors.length;
  $('#notice').textContent = errors.join(' · ');
}

async function load() {
  const response = await fetch('/api/owner-metrics', { credentials: 'same-origin' });
  if (response.status === 401) {
    $('#login').hidden = false;
    $('#dashboard').hidden = true;
    return;
  }
  if (!response.ok) throw new Error('Metrics could not be loaded.');
  const data = await response.json();
  $('#login').hidden = true;
  $('#dashboard').hidden = false;
  renderDashboard(data);
}

$('#login-form').addEventListener('submit', async event => {
  event.preventDefault();
  $('#login-error').textContent = '';
  const response = await fetch('/api/owner-auth', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ token: $('#token').value }),
  });
  if (!response.ok) {
    $('#login-error').textContent = 'That access code is not correct.';
    return;
  }
  $('#token').value = '';
  await load();
});

$('#refresh').addEventListener('click', () => load().catch(error => {
  $('#notice').hidden = false;
  $('#notice').textContent = error.message;
}));
$('#logout').addEventListener('click', async () => {
  await fetch('/api/owner-logout', { method: 'POST' });
  location.reload();
});
load().catch(error => {
  $('#login').hidden = false;
  $('#login-error').textContent = error.message;
});
