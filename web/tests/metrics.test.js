import assert from 'node:assert/strict';
import test from 'node:test';

process.env.OWNER_DASHBOARD_TOKEN = 'correct-horse-battery-staple';
process.env.TELEMETRY_HASH_SALT = 'test-salt-never-production';
process.env.SUPABASE_URL = 'https://example.supabase.co';
process.env.SUPABASE_SECRET_KEY = 'sb_secret_test';

const { normalizeTelemetry } = await import('../lib/telemetry.js');
const { createTelemetryHandler } = await import('../api/telemetry.js');
const { createOwnerMetricsHandler } = await import('../api/owner-metrics.js');

function response(){return{statusCode:0,body:null,headers:{},status(code){this.statusCode=code;return this},json(body){this.body=body;return this},setHeader(name,value){this.headers[name.toLowerCase()]=value}}}
const validEvent={eventId:'11111111-1111-4111-8111-111111111111',installId:'22222222-2222-4222-8222-222222222222',eventName:'scan_completed',platform:'windows',appVersion:'1.0.18',success:true,durationBucket:'2m_5m',itemCountBucket:'50_199'};

test('anonymous event strips everything outside the fixed privacy schema',()=>{const normalized=normalizeTelemetry({...validEvent,filePath:'C:\\Private\\photo.jpg',filename:'photo.jpg',dateTaken:'2026-01-01'});assert.deepEqual(Object.keys(normalized).sort(),['app_version','duration_bucket','event_id','event_name','install_hash','item_count_bucket','platform','success']);assert.equal(JSON.stringify(normalized).includes('photo.jpg'),false)});
test('anonymous event rejects unknown event types and identifiers',()=>{assert.equal(normalizeTelemetry({...validEvent,eventName:'photo_opened'}),null);assert.equal(normalizeTelemetry({...validEvent,installId:'person@example.com'}),null)});
test('telemetry endpoint forwards only normalized data with the server secret',async()=>{let request;const handler=createTelemetryHandler({fetchImpl:async(url,options)=>{request={url,options};return{ok:true,status:201}}});const res=response();await handler({method:'POST',headers:{'content-length':'400'},body:validEvent},res);assert.equal(res.statusCode,202);assert.equal(request.options.headers.apikey,'sb_secret_test');assert.equal(request.options.headers.Authorization,undefined);assert.equal(JSON.parse(request.options.body).event_name,'scan_completed')});
test('owner metrics require private authentication',async()=>{const handler=createOwnerMetricsHandler({stripeClient:{paymentIntents:{list:async()=>({data:[],has_more:false})}},fetchImpl:async()=>({ok:true,json:async()=>[]})});const res=response();await handler({method:'GET',headers:{}},res);assert.equal(res.statusCode,401)});

test('owner metrics count all succeeded Stripe payments and exclude owner tests',async()=>{const stripeClient={paymentIntents:{list:async()=>({has_more:false,data:[{id:'pi_1',status:'succeeded',amount_received:499,currency:'usd',receipt_email:'buyer@example.com',metadata:{}},{id:'pi_2',status:'succeeded',amount_received:499,currency:'usd',receipt_email:'enrique.padron853@gmail.com',metadata:{}},{id:'pi_3',status:'requires_payment_method',amount:499,currency:'usd',metadata:{}}]})}};const fetchImpl=async url=>url.includes('github')?{ok:true,json:async()=>[]}:{ok:true,json:async()=>[]};const handler=createOwnerMetricsHandler({stripeClient,fetchImpl});const res=response();await handler({method:'GET',headers:{authorization:'Bearer correct-horse-battery-staple'}},res);assert.equal(res.statusCode,200);assert.equal(res.body.windows.purchases,2);assert.equal(res.body.windows.externalCustomers,1);assert.equal(res.body.windows.externalGrossCents,499)});
