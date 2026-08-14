const $ = selector => document.querySelector(selector);
const money = cents => new Intl.NumberFormat('en-US',{style:'currency',currency:'USD'}).format((cents||0)/100);
const escape = value => String(value ?? '').replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;').replaceAll("'",'&#039;');
const row = (label,value) => `<div class="row"><span>${escape(label)}</span><strong>${escape(value)}</strong></div>`;

async function load() {
  const response = await fetch('/api/owner-metrics',{credentials:'same-origin'});
  if (response.status === 401) { $('#login').hidden=false; $('#dashboard').hidden=true; return; }
  if (!response.ok) throw new Error('Metrics could not be loaded.');
  const data = await response.json();
  $('#login').hidden=true; $('#dashboard').hidden=false;
  $('#updated').textContent=`Updated ${new Date(data.generatedAt).toLocaleString()}`;
  const win=data.windows||{}, apple=data.apple?.auditedSnapshot||{}, dl=data.downloads||{}, product=data.product||{};
  $('#win-customers').textContent=win.externalCustomers ?? 'Setup';
  $('#win-sales').textContent=win.configured ? `${money(win.externalGrossCents)} external gross` : 'Stripe setup required';
  $('#mac-downloads').textContent=apple.downloads ?? '—';
  $('#mac-sales').textContent=apple.salesUSD!=null ? `$${apple.salesUSD} sales · audited snapshot` : 'Apple setup required';
  $('#exe-downloads').textContent=dl.current?.downloads ?? 'Setup';
  $('#exe-version').textContent=dl.current ? `${dl.current.tag} · current asset` : 'GitHub setup required';
  $('#active-installs').textContent=product.configured ? product.activeInstalls : 'Off';
  $('#sales-detail').innerHTML=[row('Windows purchases',win.purchases ?? '—'),row('External buyers who downloaded',win.externalBuyerDownloads ?? 'Tracking now'),row('Tracked download requests',win.trackedDownloadRequests ?? '—'),row('External Windows gross',win.externalGrossCents!=null?money(win.externalGrossCents):'—'),row('Mac sales',apple.salesUSD!=null?`$${apple.salesUSD}`:'—'),row('Mac proceeds',apple.proceedsUSD!=null?`$${apple.proceedsUSD}`:'—')].join('');
  $('#download-detail').innerHTML=[row('Unique external purchases tracked',win.externalBuyerDownloads ?? '—'),row('Requests tied to purchases',win.trackedDownloadRequests ?? '—'),row('GitHub asset requests (not unique)',dl.current?.downloads ?? '—'),...(dl.releases?.length?dl.releases.slice(0,4).map(item=>row(item.tag,item.downloads.toLocaleString())):[])].join('');
  if(product.configured){$('#product-status').textContent='Live';$('#product-status').classList.add('live');$('#product-detail').innerHTML=[row('Opted-in active installs',product.activeInstalls),row('Operations measured',product.events),row('Successful operations',product.successRate==null?'—':`${product.successRate}%`),...Object.entries(product.byEvent||{}).map(([name,value])=>row(name.replaceAll('_',' '),value.total))].join('')}else{$('#product-detail').innerHTML='<p class="muted">Anonymous product metrics are ready in the apps but remain off until private storage is connected. Users must explicitly opt in.</p>'}
  const errors=[win.error,dl.error,product.error].filter(Boolean); $('#notice').hidden=!errors.length; $('#notice').textContent=errors.join(' · ');
}

$('#login-form').addEventListener('submit',async event=>{event.preventDefault();$('#login-error').textContent='';const response=await fetch('/api/owner-auth',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({token:$('#token').value})});if(!response.ok){$('#login-error').textContent='That access code is not correct.';return}$('#token').value='';await load()});
$('#refresh').addEventListener('click',()=>load().catch(error=>{$('#notice').hidden=false;$('#notice').textContent=error.message}));
$('#logout').addEventListener('click',async()=>{await fetch('/api/owner-logout',{method:'POST'});location.reload()});
load().catch(error=>{$('#login').hidden=false;$('#login-error').textContent=error.message});
