'use strict';
// Offline PostgreSQL execution with PGlite 0.5.11. The new migrations and the
// existing repository deal writers/contact triggers run against synthetic data.
const {PGlite}=require('@electric-sql/pglite'),fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const root=path.join(__dirname,'..'),read=f=>fs.readFileSync(path.join(root,f),'utf8');
const migration='supabase/migrations/20261024195054_unified_deal_intake.sql';
const extract=(source,name)=>{
 const start=source.search(new RegExp('create (?:or replace )?function '+name.replaceAll('.','\\.')+'\\s*\\(','i'));assert(start>=0,name);
 const tail=source.slice(start),open=tail.match(/\bas\s+(\$[a-z_]*\$)/i);assert(open,'function body '+name);
 const end=tail.indexOf(open[1],open.index+open[0].length);assert(end>=0,'closing delimiter '+name);return tail.slice(0,end+open[1].length)+';';
};
(async()=>{
 const db=new PGlite();try{
  await db.exec(read('tests/fixtures/deal-intake-schema.sql'));
  const multi=read('supabase/migrations/20261022172331_crm_multiple_policies.sql');
  await db.exec(multi.slice(0,multi.indexOf('create or replace view')));
  const contacts=read('supabase/migrations/20261023180330_crm_client_contact_recovery.sql');
  for(const name of ['private.book_crm_missing_name','private.book_crm_csv_value','private.book_crm_lead_contact','private.book_crm_closed_insert'])await db.exec(extract(contacts,name));
  await db.exec('create trigger book_crm_closed_insert after insert on public.closed_business for each row execute function private.book_crm_closed_insert();');
  for(const [file,name] of [['database/admin-personal-leads.sql','public.close_lead'],['database/optional-chat-lead.sql','private.chat_standalone_deal'],['database/book-of-business.sql','private.book_capture_deal'],['database/live-chat.sql','private.chat_deal_announcement']])await db.exec(extract(read(file),name));
  await db.exec('create trigger book_capture_closed after insert or update of agent_id,carrier,policy_type,application_date on public.closed_business for each row execute function private.book_capture_deal();create trigger chat_deal_announcement after insert or update or delete on public.closed_business for each row execute function private.chat_deal_announcement();');
  await db.exec(read(migration));await db.exec(read('supabase/migrations/20261024195553_enforce_complete_deal_intake.sql'));
  const agent='00000000-0000-4000-8000-000000000001',other='00000000-0000-4000-8000-000000000002',admin='00000000-0000-4000-8000-000000000003';
  const who=async(id=agent,aal='aal2',onboard='true')=>{await db.query("select set_config('test.user',$1,false),set_config('test.aal',$2,false),set_config('test.onboard',$3,false)",[id,aal,onboard]);};
  await who();
  const day=new Date().toLocaleDateString('en-CA',{timeZone:'America/Detroit'}),fields={client_name:'Taylor Morgan',phone:'202-555-0123',email:'taylor@example.invalid',carrier:'Ethos',policy_type:'Term',monthly_payment:100,application_date:day,effective_date:day,pipeline_stage:'in_force',policy_number:'DEMO-001',address_line1:'100 Example Lane',city:'Detroit',state:'MI',zip:'48000',alternate_phone:'212-555-0100',date_of_birth:'1985-04-12',mortgage_balance:150000,notes:'Fictional local test'};
  const submit=async(f=fields,{id=crypto.randomUUID(),lead=null,owner=agent,division='vivid_life'}={})=>(await db.query('select public.submit_deal_with_client($1,$2,$3,$4,$5) result',[id,f,lead,owner,lead?null:division])).rows[0].result;
  const count=async table=>(await db.query('select count(*)::int n from '+table)).rows[0].n;
  const lead=crypto.randomUUID();await db.query("insert into public.leads(id,assigned_to,status,first_name,last_name,phone,division) values($1,$2,'assigned','Old','Name','2025550100','vivid_life')",[lead,agent]);
  const id=crypto.randomUUID(),first=await submit(fields,{id,lead});
  const row=(await db.query('select * from private.book_crm_clients where id=$1',[first.client_id])).rows[0];
  for(const k of ['client_name','phone','email','policy_number','pipeline_stage','city','state','notes'])assert.equal(row[k],fields[k]);
  assert.equal(row.production_recorded,true);assert.equal(row.deal_id,first.deal_id);assert.equal(row.status,'active');
  const comp=(await db.query('select * from private.book_deal_comp where deal_id=$1',[first.deal_id])).rows[0];assert.equal(Number(comp.comp_percent),100);assert.equal(Number(comp.advance_percent),75);
  const feed=(await db.query('select deal from public.chat_messages where source_deal_id=$1',[first.deal_id])).rows[0].deal;assert.equal(Number(feed.annual_premium),1200);assert.equal(feed.client_name,undefined);assert.equal(feed.phone,undefined);
  assert.equal((await db.query('select status from public.leads where id=$1',[lead])).rows[0].status,'closed');
  assert.equal((await db.query('select details from private.book_crm_profiles where id=$1',[row.profile_id])).rows[0].details.client_name,fields.client_name);
  assert.equal((await submit(fields,{id,lead})).replayed,true);assert.equal(await count('public.closed_business'),1);assert.equal(await count('private.book_crm_clients'),1);
  assert.equal(await count('public.chat_messages'),1,'retry posts no duplicate deal announcement');
  await assert.rejects(submit({...fields,monthly_payment:101},{id,lead}),/already handled/);
  await assert.rejects(submit(fields,{lead}),/already closed/);
  const manual=await submit({...fields,client_name:'Jordan Blake',pipeline_stage:'submitted',effective_date:''});assert(manual.client_id);assert.equal(await count('public.closed_business'),2);
  const pending=(await db.query('select effective_date,status from private.book_crm_clients where id=$1',[manual.client_id])).rows[0];assert.equal(pending.effective_date,null);assert.equal(pending.status,'submitted');
  // Validation/authorization failures must leave no partial CRM, deal or ledger.
  const before=[await count('public.closed_business'),await count('private.book_crm_clients'),await count('private.deal_intake_requests')];
  for(const bad of [{client_name:''},{client_name:'Client not linked'},{phone:''},{carrier:''},{policy_type:''},{monthly_payment:0},{monthly_payment:'NaN'},{application_date:''},{application_date:'2099-01-01'},{pipeline_stage:'in_force',effective_date:''},{pipeline_stage:'in_force',effective_date:'2099-01-01'},{email:'bad'},{date_of_birth:'2099-01-01'},{unexpected:'value'}])await assert.rejects(submit({...fields,...bad}));
  await assert.rejects(submit(fields,{owner:other}),/authorized/);await assert.rejects(submit(fields,{division:'other_agency'}),/authorized/);
  await who(other);await assert.rejects(submit(fields,{lead,owner:other}),/not assigned/);
  await who(agent,'aal1');await assert.rejects(submit());await who(agent,'aal2','false');await assert.rejects(submit());await who();
  assert.deepEqual([await count('public.closed_business'),await count('private.book_crm_clients'),await count('private.deal_intake_requests')],before);
  // Old shortcuts and direct inserts cannot create incomplete client records.
  await assert.rejects(db.query("select private.chat_standalone_deal('vivid_life',$1,$2,'Ethos','Term',100,$3::date)",[agent,crypto.randomUUID(),day]),/Complete the client/);
  await assert.rejects(db.query("insert into public.closed_business(agent_id,carrier,policy_type,monthly_premium,application_date) values($1,'Ethos','Term',100,current_date)",[agent]),/Complete the client/);
  // Force a failure after the client was created; transaction rolls everything back.
  await db.exec("create function private.fail_test() returns trigger language plpgsql as $$begin raise exception 'Synthetic downstream failure';end$$;create trigger zz_fail_test after insert on public.closed_business for each row execute function private.fail_test();");
  await assert.rejects(submit(),/Synthetic downstream failure/);assert.equal(await count('private.book_crm_clients'),before[1]);assert.equal(await count('public.closed_business'),before[0]);
  await db.exec('drop trigger zz_fail_test on public.closed_business;');
  await who(admin);assert((await submit(fields,{owner:other})).client_id,'admin can credit an eligible agent');
  // The public RPC works under the actual authenticated role; private tables stay private.
  await who();await db.exec('set role authenticated');assert((await submit()).client_id);await assert.rejects(db.query('select * from private.deal_intake_requests'),/permission denied/);await db.exec('reset role');
  const perms=(await db.query("select has_function_privilege('anon','public.submit_deal_with_client(uuid,jsonb,uuid,uuid,text)','execute') anon,has_function_privilege('authenticated','private.require_complete_deal_client()','execute') guard")).rows[0];assert.equal(perms.anon,false);assert.equal(perms.guard,false);
  console.log('PASS: offline PostgreSQL migration, lead/manual atomic CRM+deal creation, shared contact, submitted/in-force dates, required fields, replay/conflict, foreign-agent denial, MFA/onboarding, admin credit, legacy-route guard, rollback on downstream failure, authenticated RPC and private permissions.');
 }finally{await db.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
