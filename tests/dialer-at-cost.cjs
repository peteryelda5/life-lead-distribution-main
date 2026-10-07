'use strict';
const assert=require('node:assert/strict'),vm=require('node:vm'),fs=require('node:fs');
function moduleFrom(path,modules,extra={}){const module={exports:{}};vm.runInNewContext(fs.readFileSync(path,'utf8'),{module,exports:module.exports,require:n=>{if(n in modules)return modules[n];if(n.startsWith('node:'))return require(n);throw Error('Unexpected import '+n)},Buffer,URLSearchParams,AbortSignal,Date,console,...extra},{filename:path});return module.exports;}
(async()=>{
 const ids=['6b2007a4-8bd8-4b4c-b65c-6d4a28dce4b3','7b5e5b17-766f-4e49-9cf5-2e57f33575eb','4733ed70-f774-4209-a8b5-fd233d0bb638','5893f335-aad3-4079-ad95-77eaf1347ac6','144fb019-c861-4ca5-87cb-0bd7d928b49e'];
 const fail=(s,m)=>Object.assign(Error(m),{status:s}),cfg={TWILIO_AUTH_TOKEN:'testonly',TWILIO_ACCOUNT_SID:'AC'+'a'.repeat(32)};
 const p=moduleFrom('lib/dialer-at-cost-provider.js',{'./dialer-full':{config:()=>cfg,failure:fail,database:async()=>[],rpc:async()=>true,ORIGIN:'https://www.lldportal.com'}});
 ids.forEach(id=>assert.equal(p.eligible({id,live:true}),true));
 assert.equal(p.eligible({id:'62036f10-8243-4f16-aa09-8785b07e405a',live:true}),false);
 assert.equal(p.eligible({id:ids[0],live:false}),false);
 const usageProvider=moduleFrom('lib/dialer-at-cost-provider.js',{'./dialer-full':{config:()=>cfg,failure:fail,database:async()=>[{required_role:'admin',provider_sid:'AC'+'b'.repeat(32)}]}},{fetch:async url=>{const q=new URL(url);assert.equal(q.searchParams.get('Category'),'totalprice');assert.equal(q.searchParams.get('IncludeSubaccounts'),'false');return {ok:true,status:200,json:async()=>({usage_records:[{category:'totalprice',price_unit:'usd',price:'1.235'}]})};},URL});
 assert.equal(await usageProvider.usage({id:ids[0],live:true},'2026-10-01','2026-10-07'),1.235);
 const lead=moduleFrom('lib/lead-calling.js',{'./dialer':{failure:fail}},{process:{env:{SUPABASE_SECRET_KEY:'sb_secret_unit'}},fetch:async()=>({status:204,ok:true,json:async()=>{throw Error('Empty success must not parse JSON');}})});
 assert.equal(await lead.rpc('dialer_select_number',{}),null);
 const sealed=p.seal('secretForTest',ids[0]);assert.equal(p.unseal(sealed,ids[0]),'secretForTest');assert.throws(()=>p.unseal(sealed,ids[1]));
 assert.equal(p.amountCents('1.235'),124);assert.throws(()=>p.amountCents(null));assert.throws(()=>p.amountCents('-1'));
 const customer='cus_unit',calls=[],a={customer_id:customer,subscription_id:null},user={id:ids[0],live:true};
 let records={user_id:user.id,billed_through:'2026-10-01',provider_sid:'AC'+'b'.repeat(32)},invoices=[],pm='pm_unit',provisioned=0,cost=1.235,saved;
 const full={ORIGIN:'https://www.lldportal.com',PURPOSE:'normal',failure:fail,
 rpc:async(n,args)=>{calls.push({n,args});if(n==='dialer_sync_at_cost')return {subscription_status:args.p_ready?'at_cost':'at_cost_pending'};if(n==='dialer_claim_checkout')return {checkout_request:'uuid',checkout_expires:'2026-10-07T16:00:00Z'};},
 database:async(path,body)=>{if(path.startsWith('dialer_at_cost_invoices')){if(body){saved={...saved,...body};return [saved];}return saved?[saved]:[];}if(body){records={...records,...body};return [records];}return [records];},
 stripe:async(path,body,key)=>{calls.push({path,body,key});if(path==='customers/'+customer)return {id:customer,livemode:true,invoice_settings:{default_payment_method:pm}};if(path==='payment_methods/'+pm)return {customer,type:'card'};if(path.startsWith('invoices?'))return {data:invoices,has_more:false};if(path==='checkout/sessions')return {id:'cs_unit',livemode:true,url:'https://checkout.stripe.com/test'};if(path==='invoices')return {id:'in_unit',status:'draft',customer,livemode:true,metadata:{purpose:'vivid_dialer_at_cost_v1'}};if(path==='invoiceitems')return {id:'ii_unit'};if(path.includes('/finalize'))return {id:'in_unit',status:'open'};throw Error('Unexpected Stripe '+path);}
 };
 const provider={row:async()=>records,provision:async()=>{provisioned++},amountCents:p.amountCents,usage:async()=>cost};
 const b=moduleFrom('lib/dialer-at-cost-billing.js',{'./dialer-full':full,'./dialer-at-cost-provider':provider});
 assert.equal((await b.sync(user,a)).subscription_status,'at_cost');assert.equal(provisioned,1);
 invoices=[{metadata:{purpose:b.purpose},status:'open',amount_remaining:50}];
 assert.equal((await b.sync(user,a)).subscription_status,'at_cost_pending');assert.equal(provisioned,1);
 invoices=[];pm=null;assert.equal((await b.sync(user,a)).subscription_status,'at_cost_pending');
 await b.checkout(user,a);const setup=calls.find(c=>c.path==='checkout/sessions');assert.equal(setup.body.mode,'setup');assert.equal(setup.body['line_items[0][price_data][unit_amount]'],undefined);assert.match(setup.body['custom_text[submit][message]'],/actual Twilio/);
 records.payment_session=null;cost=.49;await b.settle(user,a,new Date('2026-11-03T10:00:00Z'));assert.equal(saved,undefined);
 cost=1.235;await b.settle(user,a,new Date('2026-11-03T10:00:00Z'));assert.equal(saved.amount_cents,124);assert.equal(saved.state,'attached');assert.equal(records.billed_through,'2026-11-01');const invoiceCount=calls.filter(c=>c.path==='invoices').length;await b.settle(user,a,new Date('2026-11-03T10:00:00Z'));assert.equal(calls.filter(c=>c.path==='invoices').length,invoiceCount);
 assert.equal(calls.some(c=>c.path?.startsWith('subscriptions')),false);
 console.log('PASS: exact five live accounts; Nick agent excluded; encrypted provider credentials tied to user; no $250 charge; card setup mode; missing card/unpaid invoice denied; exact provider cents; small balances carried; no duplicate period invoice.');
})().catch(e=>{console.error(e);process.exitCode=1});

