-- Minimal isolated Postgres fixture. No production users, requests or events.
create role anon;create role authenticated;
create schema auth;create schema private;
create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('test.user',true),'')::uuid$$;
create table public.profiles(id uuid primary key,full_name text,division text,role text,active boolean default true,archived boolean default false);
create table public.leads(id uuid primary key,assigned_to uuid,status text,first_name text,last_name text,phone text,email text,state text,division text,csv_headers jsonb default '[]',csv_values jsonb default '[]');
create table public.closed_business(id uuid primary key default gen_random_uuid(),lead_id uuid references public.leads(id),agent_id uuid references public.profiles(id),chat_request_id uuid unique,carrier text,policy_type text,monthly_premium numeric,application_date date,policy_number text,notes text);
alter table public.closed_business add column created_at timestamptz default now(),add column annual_premium numeric generated always as (monthly_premium*12) stored;
create table private.book_comp_grid(id uuid primary key default gen_random_uuid(),agent_id uuid,carrier text,policy_type text,effective_date date,comp_percent numeric,advance_percent numeric);
create table private.book_deal_comp(deal_id uuid primary key references public.closed_business(id),grid_id uuid,comp_percent numeric,advance_percent numeric);
create table public.chat_messages(division text,channel text,author_id uuid,author_name text,kind text,source_deal_id uuid unique,deal jsonb,body text);
create table public.audit_logs(actor_id uuid,action text,entity_type text,entity_id text,details jsonb);
create table private.book_clients(deal_id uuid primary key references public.closed_business(id),client_name text,phone text,email text,updated_by uuid);
create table private.book_crm_clients(id uuid primary key default gen_random_uuid(),agent_id uuid not null references public.profiles(id),client_name text not null,phone text default '',alternate_phone text default '',email text default '',address_line1 text default '',address_line2 text default '',city text default '',state text default '',zip text default '',date_of_birth date,mortgage_balance numeric,carrier text,policy_type text,monthly_payment numeric,policy_number text,application_date date,effective_date date,pipeline_stage text,status text,notes text,deal_id uuid unique references public.closed_business(id),production_recorded boolean not null default false,created_at timestamptz default now(),updated_at timestamptz default now());
create table private.book_crm_activity(client_id uuid references private.book_crm_clients(id),actor_id uuid,kind text,body text,metadata jsonb);
create function private.verified_portal_session() returns boolean language sql stable as $$select auth.uid() is not null and current_setting('test.aal',true)='aal2' and exists(select 1 from public.profiles where id=auth.uid() and active and not archived)$$;
create function public.require_portal_onboarding() returns boolean language plpgsql as $$begin if not private.verified_portal_session() or current_setting('test.onboard',true)<>'true' then raise insufficient_privilege;end if;return true;end$$;
create function private.can_work_assigned_leads() returns boolean language sql as $$select private.verified_portal_session()$$;
create function public.is_admin() returns boolean language sql as $$select exists(select 1 from public.profiles where id=auth.uid() and role='admin')$$;
create function private.leaderboard_divisions() returns text[] language sql as $$select array[division] from public.profiles where id=auth.uid()$$;
create function private.book_crm_can_access(p_agent uuid,p_deal uuid default null) returns boolean language sql as $$select private.verified_portal_session() and (p_agent=auth.uid() or public.is_admin())$$;
create function private.chat_deal_agents(p_division text) returns jsonb language sql as $$select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',full_name)),'[]') from public.profiles where division=p_division and active and not archived and (role='agent' or id=auth.uid()) and (public.is_admin() or id=auth.uid())$$;
insert into public.profiles(id,full_name,division,role) values
 ('00000000-0000-4000-8000-000000000001','Sample Agent','vivid_life','agent'),
 ('00000000-0000-4000-8000-000000000002','Other Agent','vivid_life','agent'),
 ('00000000-0000-4000-8000-000000000003','Sample Admin','vivid_life','admin');
insert into private.book_comp_grid(agent_id,carrier,policy_type,effective_date,comp_percent,advance_percent) values('00000000-0000-4000-8000-000000000001','ethos','term','2026-01-01',100,75);
grant usage on schema public,private,auth to authenticated;
grant execute on all functions in schema public,private,auth to authenticated;
