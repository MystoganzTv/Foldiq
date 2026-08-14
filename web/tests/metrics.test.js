import assert from 'node:assert/strict';
import test from 'node:test';

process.env.OWNER_DASHBOARD_TOKEN = 'correct-horse-battery-staple';
process.env.TELEMETRY_HASH_SALT = 'test-salt-never-production';
process.env.DATABASE_URL = 'postgresql://test.invalid/foldiq';

const { normalizeTelemetry } = await import('../lib/telemetry.js');
const { createTelemetryHandler } = await import('../api/telemetry.js');
const { createOwnerMetricsHandler } = await import('../api/owner-metrics.js');

function response(){return{statusCode:0,body:null,headers:{},status(code){this.statusCode=code;return this},json(body){this.body=body;return this},setHeader(name,value){this.headers[name.toLowerCase()]=value}}}
const validEvent={eventId:'11111111-1111-4111-8111-111111111111',installId:'22222222-2222-4222-8222-222222222222',eventName:'scan_completed',platform:'windows',appVersion:'1.0.18',success:true,durationBucket:'2m_5m',itemCountBucket:'50_199'};

test('anonymous event strips everything outside the fixed privacy schema',()=>{const normalized=normalizeTelemetry({...validEvent,filePath:'C:\\Private\\photo.jpg',filename:'photo.jpg',dateTaken:'2026-01-01'});assert.deepEqual(Object.keys(normalized).sort(),['app_version','duration_bucket','event_id','event_name','install_hash','item_count_bucket','platform','success']);assert.equal(JSON.stringify(normalized).includes('photo.jpg'),false)});
test('anonymous event rejects unknown event types and identifiers',()=>{assert.equal(normalizeTelemetry({...validEvent,eventName:'photo_opened'}),null);assert.equal(normalizeTelemetry({...validEvent,installId:'person@example.com'}),null)});
test('telemetry endpoint inserts only normalized data with a parameterized query',async()=>{let query;const handler=createTelemetryHandler({queryImpl:async(text,params)=>{query={text,params}}});const res=response();await handler({method:'POST',headers:{'content-length':'400'},body:validEvent},res);assert.equal(res.statusCode,202);assert.match(query.text,/insert into product_events/i);assert.equal(query.params[2],'scan_completed');assert.equal(query.params.includes('photo.jpg'),false)});
test('owner metrics require private authentication',async()=>{const handler=createOwnerMetricsHandler({stripeClient:{paymentIntents:{list:async()=>({data:[],has_more:false})}},fetchImpl:async()=>({ok:true,json:async()=>[]}),queryImpl:async()=>[]});const res=response();await handler({method:'GET',headers:{}},res);assert.equal(res.statusCode,401)});

test('owner metrics calculate detailed external sales without exposing buyer identities',async()=>{
  const created=Math.floor(Date.parse('2026-08-14T04:00:00Z')/1000);
  const stripeClient={paymentIntents:{list:async()=>({has_more:false,data:[
    {id:'pi_1',created,status:'succeeded',amount_received:499,currency:'usd',receipt_email:'buyer@example.com',metadata:{platform:'windows',foldiq_download_count:'2'},latest_charge:{billing_details:{email:'buyer@example.com',address:{country:'US'}},balance_transaction:{fee:44,net:455},amount_refunded:0}},
    {id:'pi_2',created,status:'succeeded',amount_received:499,currency:'usd',receipt_email:'enrique.padron853@gmail.com',metadata:{platform:'windows',foldiq_download_count:'1'},latest_charge:{billing_details:{email:'enrique.padron853@gmail.com',address:{country:'US'}},balance_transaction:{fee:44,net:455},amount_refunded:0}},
    {id:'pi_3',created,status:'requires_payment_method',amount:499,currency:'usd',metadata:{}},
    {id:'pi_4',created,status:'succeeded',amount_received:499,currency:'usd',receipt_email:'legacy-mac@example.com',metadata:{},latest_charge:{billing_details:{email:'legacy-mac@example.com',address:{country:'DE'}},balance_transaction:{fee:44,net:455},amount_refunded:0}},
  ]})}};
  const fetchImpl=async()=>({ok:true,json:async()=>[]});
  const handler=createOwnerMetricsHandler({stripeClient,fetchImpl,queryImpl:async()=>[]});
  const res=response();
  await handler({method:'GET',headers:{authorization:'Bearer correct-horse-battery-staple'}},res);
  assert.equal(res.statusCode,200);
  assert.equal(res.body.windows.purchases,3);
  assert.equal(res.body.windows.externalCustomers,2);
  assert.equal(res.body.windows.externalPurchases,2);
  assert.equal(res.body.windows.verifiedWindowsPurchases,1);
  assert.equal(res.body.windows.legacyDirectMacPurchases,1);
  assert.equal(res.body.windows.externalGrossCents,998);
  assert.equal(res.body.windows.externalFeesCents,88);
  assert.equal(res.body.windows.externalNetCents,910);
  assert.equal(res.body.windows.externalBuyerDownloads,1);
  assert.equal(res.body.windows.trackedDownloadRequests,3);
  assert.deepEqual(res.body.windows.countries,[{country:'US',customers:1},{country:'DE',customers:1}]);
  assert.equal(res.body.windows.daily[0].purchases,2);
  assert.equal(res.body.windows.recentPurchases[0].country,'US');
  assert.equal(JSON.stringify(res.body).includes('buyer@example.com'),false);
});
