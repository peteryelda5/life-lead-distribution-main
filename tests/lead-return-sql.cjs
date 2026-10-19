'use strict';
// Local PostgreSQL execution of the migration and rollback-only integration fixture.
// This minimal schema is not a replacement for testing the deployed RLS/schema.
const fs=require('node:fs'),assert=require('node:assert/strict'),{PGlite}=require('@electric-sql/pglite');
const read=p=>fs.readFileSync(__dirname+'/../'+p,'utf8');
(async()=>{
 const db=new PGlite();
 try{
  await db.exec(`
   create role anon; create role authenticated;
   create schema auth; create schema private;
   grant usage on schema auth,private to authenticated;
   create function auth.jwt() returns jsonb language sql stable as $$select coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb$$;
   create function auth.uid() returns uuid language sql stable as $$select (auth.jwt()->>'sub')::uuid$$;
   create type public.user_role as enum('admin','agent');
   create table auth.users(id uuid primary key,email text);
   create table public.divisions(id text primary key,name text not null,archived boolean default false);
   insert into public.divisions values('vivid_life','Vivid Life',false),('owner','Master',false);
   create table public.profiles(id uuid primary key references auth.users(id),email text,full_name text,role public.user_role,active boolean default true,archived boolean default false,is_super_admin boolean default false,is_team_leader boolean default false,division text references public.divisions(id));
   create table public.leads(id uuid primary key default gen_random_uuid(),first_name text,last_name text,phone text,state text,lead_type text,division text not null default 'owner' references public.divisions(id),assigned_to uuid references public.profiles(id),status text not null default 'unassigned',assigned_at timestamptz,created_at timestamptz default now(),updated_at timestamptz not null default now(),notes text,call_notes text,agent_status text,csv_headers jsonb,csv_values jsonb,uploaded_by uuid,owner_admin_id uuid,is_dead_number boolean default false);
   create table public.closed_business(id uuid primary key default gen_random_uuid(),lead_id uuid references public.leads(id),agent_id uuid references public.profiles(id),carrier text,policy_type text,monthly_premium numeric,application_date date);
   create table public.audit_logs(id bigint generated always as identity primary key,actor_id uuid,action text,entity_type text,entity_id text,details jsonb,created_at timestamptz default now());
   create function private.my_admin_divisions() returns text[] language sql stable security definer as $$select coalesce(array_agg(d.id),'{}') from public.divisions d,public.profiles p where p.id=auth.uid() and p.role='admin' and p.active and not p.archived and (p.is_super_admin or p.division=d.id)$$;
   create function public.admin_can_access_division(d text) returns boolean language sql stable as $$select d=any(private.my_admin_divisions())$$;
   create function private.admin_can_receive_lead(who uuid,d text) returns boolean language sql stable as $$select exists(select 1 from public.profiles p where p.id=who and p.role='admin' and p.active and not p.archived and (p.is_super_admin or p.division=d))$$;
   -- Pool transfers are outside this feature; deny any accidental division change.
   create function private.can_transfer_lead_pool(a text,b text) returns boolean language sql as $$select false$$;
   create function private.can_recall_agency_pool(a text,b text) returns boolean language sql as $$select false$$;
   alter table public.leads enable row level security;
   grant select on public.leads to authenticated;
   create policy local_own_leads on public.leads for select to authenticated using(assigned_to=auth.uid() or division=any(private.my_admin_divisions()));
  `);
  const mfa=read('database/mfa-bootstrap.sql');
  await db.exec(mfa.slice(mfa.indexOf('create or replace function private.verified_portal_session'),mfa.indexOf('-- Edge functions')));
  const portable=read('database/portable-agent-leads.sql');
  await db.exec(portable.slice(0,portable.indexOf('create or replace function public.enforce_lead_division')));
  await db.exec(read('database/agency-lead-recall-trigger.sql'));
  await db.exec('create trigger enforce_lead_division before insert or update on public.leads for each row execute function public.enforce_lead_division();');
  await db.exec(portable.slice(portable.indexOf('create or replace function private.clear_portable_lead'),portable.indexOf('create or replace function private.transfer_agent_division')));
  await db.exec(read('database/lead-history.sql').split('-- Snapshot is explicitly')[0]);
  await db.exec(read('database/lead-delivery-receipts.sql').split('-- Reconstruct only')[0]);
  await db.exec(read('database/return-my-leads-to-pool.sql'));
  await db.exec(read('database/verify-return-my-leads-to-pool.sql'));
  const result=await db.query('select (select count(*) from public.leads) leads,(select count(*) from auth.users) users,(select count(*) from public.lead_delivery_receipts) receipts,(select count(*) from private.my_lead_pool_returns) returns');
  assert.deepEqual(result.rows[0],{leads:0,users:0,receipts:0,returns:0});
  console.log('PASS: own admin/team-leader returns; role/MFA/ownership/revision/closed-business restrictions; atomic rejection; portable cleanup; preserved lead data; history/receipts; idempotent retries; private ledger; fixture rollback.');
 }finally{await db.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
