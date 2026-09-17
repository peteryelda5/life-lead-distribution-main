const {PGlite}=require('@electric-sql/pglite');const fs=require('fs'),assert=require('assert/strict');
(async()=>{const db=new PGlite();await db.exec(`create role anon;create role authenticated;create schema auth;create schema private;
create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
create table public.profiles(id uuid primary key,role text,active boolean default true,archived boolean default false,is_super_admin boolean default false,division text,full_name text);
create table public.leads(id uuid primary key default gen_random_uuid(),division text,status text default 'unassigned',assigned_to uuid references profiles(id),assigned_at timestamptz,created_at timestamptz default now(),updated_at timestamptz,lead_type text,owner_admin_id uuid);
create table public.audit_logs(actor_id uuid,action text,entity_type text,entity_id text,details jsonb);
create function public.is_super_admin() returns boolean language sql stable security definer as $$select coalesce((select active and is_super_admin from public.profiles where id=auth.uid()),false)$$;
create function public.is_active_agent() returns boolean language sql stable security definer as $$select coalesce((select role='agent' and active and not archived from public.profiles where id=auth.uid()),false) and current_setting('test.aal',true)='aal2'$$;
create function public.admin_can_manage_agent(a uuid) returns boolean language sql stable security definer as $$select exists(select 1 from public.profiles c,public.profiles t where c.id=auth.uid() and c.role='admin' and c.active and t.id=a and t.role='agent' and (c.is_super_admin or c.division=t.division))$$;
grant usage on schema public,private,auth to authenticated;grant all on public.leads to authenticated;grant select on public.profiles to authenticated;
alter table public.leads enable row level security;
insert into profiles(id,role,division,is_super_admin,full_name) values
('00000000-0000-0000-0000-000000000001','admin','vivid_life',true,'Master'),
('00000000-0000-0000-0000-000000000002','agent','vivid_life',false,'Leader'),
('00000000-0000-0000-0000-000000000003','agent','vivid_life',false,'Member'),
('00000000-0000-0000-0000-000000000004','agent','legacy_life',false,'Other leader'),
('00000000-0000-0000-0000-000000000005','admin','legacy_life',false,'Legacy admin');`);
await db.exec(fs.readFileSync('db/team-leaders.sql','utf8'));
const id=n=>'00000000-0000-0000-0000-'+String(n).padStart(12,'0');
async function as(n,aal='aal2'){await db.exec(`reset role;select set_config('request.jwt.claim.sub','${id(n)}',false);select set_config('test.aal','${aal}',false);set role authenticated;`)}
async function reject(sql,match){await assert.rejects(db.exec(sql),match)}
await as(1);await db.exec(`select public.set_agent_team('${id(2)}',true,null);select public.set_agent_team('${id(4)}',true,null);select public.set_agent_team('${id(3)}',false,'${id(2)}');`);
await reject(`select public.set_agent_team('${id(3)}',false,'${id(4)}')`,/same division/);
await reject(`select public.set_agent_team('${id(2)}',false,null)`,/Reassign/);
await as(2);await reject(`select public.set_agent_team('${id(3)}',true,null)`,/Master Admin/);
await db.exec(`insert into leads(id,division,lead_type,uploaded_by) values('${id(10)}','vivid_life','A','${id(4)}');`);
let row=(await db.query(`select * from leads where id='${id(10)}'`)).rows[0];assert.equal(row.uploaded_by,id(2));assert.equal(row.status,'unassigned');
await reject(`insert into leads(division) values('legacy_life')`,/only to your division|row-level/);
await as(4);await db.exec(`insert into leads(id,division,lead_type) values('${id(11)}','legacy_life','A')`);
await as(2);await reject(`select public.delete_team_uploads(array['${id(11)}'::uuid])`,/only your own/);
await db.exec(`delete from leads where id='${id(11)}'`);
await db.exec('reset role');assert.equal((await db.query(`select count(*)::int n from leads where id='${id(11)}'`)).rows[0].n,1);
await as(2,'aal1');await reject(`insert into leads(division) values('vivid_life')`,/row-level/);await reject(`select public.delete_team_uploads(array['${id(10)}'::uuid])`,/access required/);
await as(3);await reject(`insert into leads(division) values('vivid_life')`,/row-level/);
await as(2);await db.exec(`select public.delete_team_uploads(array['${id(10)}'::uuid])`);
await db.exec(`reset role;select set_config('request.jwt.claim.sub','${id(1)}',false);insert into leads(id,division,status,assigned_to,lead_type) values('${id(20)}','vivid_life','assigned','${id(3)}','A'),('${id(21)}','vivid_life','assigned','${id(3)}','A'),('${id(22)}','vivid_life','assigned','${id(3)}','B'),('${id(23)}','vivid_life','closed','${id(3)}','A');`);
await as(5);await reject(`select public.reclaim_agent_leads_filtered('${id(3)}','A',1)`,/Cannot manage/);
await as(1);await db.exec(`select public.reclaim_agent_leads_filtered('${id(3)}','A',1)`);
await reject(`select public.reclaim_agent_leads_filtered('${id(3)}','A',5)`,/Only 1/);
await db.exec('reset role');const rows=(await db.query(`select * from leads where id in ('${id(20)}','${id(21)}','${id(22)}','${id(23)}')`)).rows;assert.equal(rows.filter(x=>x.status==='unassigned').length,1);assert.equal(rows.find(x=>x.id===id(22)).status,'assigned');assert.equal(rows.find(x=>x.id===id(23)).status,'closed');
console.log('PASS: team setup, cross-division/self-promotion denial, uploader stamp, own-only deletion, MFA, ordinary-agent denial, exact type/quantity reclaim, shortfall rollback, closed leads preserved');await db.close();})().catch(e=>{console.error(e);process.exit(1)});
