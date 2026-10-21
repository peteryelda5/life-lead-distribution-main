'use strict';
// Isolated PostgreSQL engine, no connection to a Supabase project. Minimal
// prior-schema fixtures exercise the actual migration and adversarial SQL.
const {PGlite}=require('@electric-sql/pglite');const fs=require('fs'),path=require('path');
const root=path.join(__dirname,'..');
(async()=>{
 const db=new PGlite();
 await db.exec(`
 create role anon;create role authenticated;create role service_role;
 create schema auth;create schema private;
 grant usage on schema auth,private,public to authenticated,service_role;
 create table auth.users(id uuid primary key,email text);
 create table auth.sessions(id uuid primary key,user_id uuid references auth.users(id),aal text,created_at timestamptz,not_after timestamptz);
 create function auth.jwt() returns jsonb language sql stable as $$select coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb$$;
 create function auth.uid() returns uuid language sql stable as $$select nullif(auth.jwt()->>'sub','')::uuid$$;
 create table public.profiles(id uuid primary key references auth.users(id),email text,full_name text,role text,active boolean,archived boolean default false,division text,is_super_admin boolean default false);
 create table public.divisions(id text primary key,created_at timestamptz default now());insert into public.divisions(id) values('vivid_life'),('legacy_life');
 create table public.leads(id uuid primary key default gen_random_uuid(),assigned_to uuid,status text,lead_type text);
 create table public.closed_business(id uuid primary key default gen_random_uuid());
 create table public.portal_onboarding_receipts(user_id uuid,completion_kind text);
 create table public.audit_logs(actor_id uuid,action text,entity_type text,entity_id text,details jsonb);
 create function private.verified_portal_session() returns boolean language sql stable security definer as $$select auth.jwt()->>'aal'='aal2'$$;
 grant execute on function private.verified_portal_session() to authenticated;
 create function public.require_portal_mfa() returns boolean language plpgsql as $$begin if not private.verified_portal_session() then raise insufficient_privilege;end if;return true;end$$;
 create function public.is_admin() returns boolean language sql stable security definer as $$select exists(select 1 from public.profiles where id=auth.uid() and role='admin' and active)$$;
 create function private.my_admin_divisions() returns text[] language sql stable security definer as $$select array(select division from public.profiles where id=auth.uid() and role='admin' and active)$$;
 create function private.can_work_assigned_leads() returns boolean language sql stable security definer as $$select private.verified_portal_session()$$;
 alter table public.leads enable row level security;
 create policy owner_leads on public.leads for select to authenticated using(assigned_to=auth.uid());
 create policy "agent mfa required leads" on public.leads as restrictive for all to authenticated using(auth.jwt()->>'aal'='aal2') with check(auth.jwt()->>'aal'='aal2');
 alter table public.closed_business enable row level security;
 create policy "agent mfa required closed business" on public.closed_business as restrictive for all to authenticated using(auth.jwt()->>'aal'='aal2') with check(auth.jwt()->>'aal'='aal2');
 alter table public.portal_onboarding_receipts enable row level security;
 create policy onboarding_read_own on public.portal_onboarding_receipts for select to authenticated using(user_id=auth.uid() and auth.jwt()->>'aal'='aal2');
 create policy onboarding_acknowledge_own on public.portal_onboarding_receipts for insert to authenticated with check(user_id=auth.uid() and auth.jwt()->>'aal'='aal2');
 grant select on public.leads to authenticated;
 `);
 await db.exec(fs.readFileSync(path.join(root,'supabase/migrations/20261021165857_portal_face_id_verification.sql'),'utf8'));
 await db.exec(fs.readFileSync(path.join(__dirname,'portal-passkeys.sql'),'utf8'));
 const rows=await db.query('select count(*)::int n from auth.users');if(rows.rows[0].n!==0)throw Error('Fixture rollback failed');
 await db.close();console.log('PASS: isolated PostgreSQL migration, grants, enrollment gates, one-time challenges, owner/session binding, agency scope, proof expiry, account disable, session expiry, credential revocation, session cascade, TOTP compatibility and complete fixture rollback.');
})().catch(e=>{console.error(e.message);process.exitCode=1;});
