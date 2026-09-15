-- Resumable, atomic imports. Every RPC call validates the current admin and division.
create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated;
create table public.lead_import_jobs (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references public.profiles(id),
 division text not null check(division in ('owner','vivid_life','legacy_life')),
 fingerprint text not null check(length(fingerprint)=64),
 filename text not null, file_size bigint not null check(file_size>0),
 lead_type text not null check(length(btrim(lead_type))>0), default_source text not null default 'CSV import',
 headers jsonb, byte_offset bigint not null default 0, row_count bigint not null default 0,
 last_from bigint, last_digest text,
 status text not null default 'uploading' check(status in ('uploading','completed')),
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 check(byte_offset>=0 and byte_offset<=file_size),check(row_count>=0)
);
create index lead_import_jobs_owner_recent on public.lead_import_jobs(owner_id,created_at desc);
create unique index lead_import_jobs_resume_key on public.lead_import_jobs(owner_id,division,fingerprint,lead_type,default_source);
alter table public.lead_import_jobs enable row level security;
revoke all on public.lead_import_jobs from anon,authenticated;
grant select on public.lead_import_jobs to authenticated;
grant insert(id,owner_id,division,fingerprint,filename,file_size,lead_type,default_source) on public.lead_import_jobs to authenticated;
create policy "admins read own imports" on public.lead_import_jobs for select to authenticated
 using(owner_id=(select auth.uid()) and (select public.is_admin()) and public.admin_can_access_division(division));
create policy "admins start permitted imports" on public.lead_import_jobs for insert to authenticated
 with check(owner_id=(select auth.uid()) and (select public.is_admin()) and
 (case when (select public.is_super_admin()) then division in ('owner','vivid_life') else division=(select public.current_admin_division()) end));
create or replace function private.commit_lead_import_batch(p_job uuid,p_from bigint,p_to bigint,p_headers jsonb,p_rows jsonb,p_final boolean default false)
returns jsonb language plpgsql security definer set search_path='' as $$
declare job public.lead_import_jobs; uid uuid:=auth.uid(); n integer; signature text;
begin
 if uid is null or not public.is_admin() then raise exception 'Active admin required' using errcode='42501'; end if;
 select * into job from public.lead_import_jobs where id=p_job and owner_id=uid for update;
 if not found then raise exception 'Import not found' using errcode='42501'; end if;
 if (public.is_super_admin() and job.division not in ('owner','vivid_life')) or
    (not public.is_super_admin() and job.division is distinct from public.current_admin_division()) then
  raise exception 'You cannot import into this division' using errcode='42501';
 end if;
 if p_rows is null or jsonb_typeof(p_rows)<>'array' or jsonb_array_length(p_rows)>500 or octet_length(p_rows::text)>8388608 then raise exception 'Batch must contain at most 500 rows and 8 MB'; end if;
 if p_headers is null or jsonb_typeof(p_headers)<>'array' or jsonb_array_length(p_headers)>256 then raise exception 'Invalid CSV headers'; end if;
 if p_from is null or p_to is null or p_from<0 or p_to<p_from or p_to>job.file_size or p_final is null then raise exception 'Invalid byte checkpoint'; end if;
 if p_final and p_to<>job.file_size then raise exception 'Final checkpoint must match file size'; end if;
 n:=jsonb_array_length(p_rows);
 if not p_final and p_to=p_from then raise exception 'Batch must advance the checkpoint'; end if;
 signature:=encode(sha256(convert_to(jsonb_build_array(p_from,p_to,p_headers,p_rows,p_final)::text,'UTF8')),'hex');
 if job.last_from=p_from and job.last_digest=signature then
  return jsonb_build_object('byte_offset',job.byte_offset,'row_count',job.row_count,'status',job.status,'replayed',true);
 end if;
 if job.status='completed' or job.byte_offset<>p_from then raise exception 'Checkpoint changed. Resume the import from saved progress.' using errcode='40001'; end if;
 if exists(select 1 from jsonb_array_elements(p_rows) r where jsonb_typeof(r)<>'object' or jsonb_typeof(r->'csv_values') is distinct from 'array' or jsonb_array_length(r->'csv_values')>256) then raise exception 'Invalid CSV row'; end if;
 insert into public.leads(first_name,last_name,phone,email,state,source,notes,lead_type,division,owner_admin_id,csv_filename,csv_headers,csv_values)
 select coalesce(r.first_name,''),coalesce(r.last_name,''),r.phone,r.email,r.state,coalesce(nullif(r.source,''),job.default_source),r.notes,job.lead_type,job.division,uid,job.filename,p_headers,r.csv_values
 from jsonb_to_recordset(p_rows) as r(first_name text,last_name text,phone text,email text,state text,source text,notes text,csv_values jsonb);
 update public.lead_import_jobs set byte_offset=p_to,row_count=row_count+n,headers=p_headers,last_from=p_from,last_digest=signature,
 status=case when p_final then 'completed' else 'uploading' end,updated_at=now() where id=job.id returning * into job;
 return jsonb_build_object('byte_offset',job.byte_offset,'row_count',job.row_count,'status',job.status,'replayed',false);
end $$;
revoke all on function private.commit_lead_import_batch(uuid,bigint,bigint,jsonb,jsonb,boolean) from public,anon;
grant execute on function private.commit_lead_import_batch(uuid,bigint,bigint,jsonb,jsonb,boolean) to authenticated;
create or replace function public.commit_lead_import_batch(p_job uuid,p_from bigint,p_to bigint,p_headers jsonb,p_rows jsonb,p_final boolean default false)
returns jsonb language sql security invoker set search_path='' as $$
 select private.commit_lead_import_batch(p_job,p_from,p_to,p_headers,p_rows,p_final);
$$;
revoke all on function public.commit_lead_import_batch(uuid,bigint,bigint,jsonb,jsonb,boolean) from public,anon;
grant execute on function public.commit_lead_import_batch(uuid,bigint,bigint,jsonb,jsonb,boolean) to authenticated;

-- Cursor pagination avoids increasingly expensive deep OFFSET scans.
create index leads_division_status_cursor on public.leads(division,status,created_at desc,id desc);
create index leads_agent_status_cursor on public.leads(assigned_to,status,created_at desc,id desc);
create index leads_division_type_cursor on public.leads(division,status,lead_type,created_at desc,id desc);
create index leads_division_state_cursor on public.leads(division,status,upper(btrim(coalesce(state,''))),created_at desc,id desc);

-- Maintain small grouped totals once per statement, rather than recounting leads on every page.
create table private.lead_totals (
 division text not null,status public.lead_status not null,lead_type text not null,state text not null,agent_key text not null,
 lead_count bigint not null,primary key(division,status,lead_type,state,agent_key)
);
alter table private.lead_totals enable row level security;
revoke all on private.lead_totals from public,anon,authenticated;
lock table public.leads in share row exclusive mode;
insert into private.lead_totals
 select division,status,coalesce(nullif(btrim(lead_type),''),''),upper(btrim(coalesce(state,''))),coalesce(assigned_to::text,''),count(*)
 from public.leads group by 1,2,3,4,5;
create function private.maintain_lead_totals() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if tg_op='INSERT' then
  insert into private.lead_totals as t
  select division,status,coalesce(nullif(btrim(lead_type),''),''),upper(btrim(coalesce(state,''))),coalesce(assigned_to::text,''),count(*)
  from new_leads group by 1,2,3,4,5 order by 1,2,3,4,5
  on conflict(division,status,lead_type,state,agent_key) do update set lead_count=t.lead_count+excluded.lead_count;
 elsif tg_op='DELETE' then
  insert into private.lead_totals as t
  select division,status,coalesce(nullif(btrim(lead_type),''),''),upper(btrim(coalesce(state,''))),coalesce(assigned_to::text,''),-count(*)
  from old_leads group by 1,2,3,4,5 order by 1,2,3,4,5
  on conflict(division,status,lead_type,state,agent_key) do update set lead_count=t.lead_count+excluded.lead_count;
 else
  insert into private.lead_totals as t
  select division,status,coalesce(nullif(btrim(lead_type),''),''),upper(btrim(coalesce(state,''))),coalesce(assigned_to::text,''),sum(delta)
  from (select division,status,lead_type,state,assigned_to,1 delta from new_leads
        union all select division,status,lead_type,state,assigned_to,-1 delta from old_leads) changes
  group by 1,2,3,4,5 having sum(delta)<>0 order by 1,2,3,4,5
  on conflict(division,status,lead_type,state,agent_key) do update set lead_count=t.lead_count+excluded.lead_count;
 end if;
 return null;
end $$;
revoke all on function private.maintain_lead_totals() from public,anon,authenticated;
create trigger lead_totals_insert after insert on public.leads referencing new table as new_leads for each statement execute function private.maintain_lead_totals();
create trigger lead_totals_delete after delete on public.leads referencing old table as old_leads for each statement execute function private.maintain_lead_totals();
create trigger lead_totals_update after update on public.leads referencing new table as new_leads old table as old_leads for each statement execute function private.maintain_lead_totals();

create or replace function public.admin_dashboard_stats() returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb; master boolean; div text;
begin
 if auth.uid() is null or not public.is_admin() then raise exception 'Admin only' using errcode='42501';end if;
 master:=public.is_super_admin();div:=public.current_admin_division();
 select jsonb_build_object('total_leads',coalesce(sum(lead_count),0),
  'unassigned',coalesce(sum(lead_count) filter(where status='unassigned'),0),
  'assigned',coalesce(sum(lead_count) filter(where status='assigned'),0),
  'closed',coalesce(sum(lead_count) filter(where status='closed'),0)) into result
 from private.lead_totals where master or division=div;
 return result||(select jsonb_build_object('monthly_premium',coalesce(sum(c.monthly_premium),0),'annual_premium',coalesce(sum(c.annual_premium),0))
 from public.closed_business c join public.profiles p on p.id=c.agent_id where master or p.division=div);
end $$;
create or replace function public.admin_agent_stats() returns table(agent_id uuid,open_leads bigint,annual_premium numeric)
language plpgsql security definer set search_path='' as $$
declare master boolean; div text;
begin
 if auth.uid() is null or not public.is_admin() then raise exception 'Admin only' using errcode='42501';end if;
 master:=public.is_super_admin();div:=public.current_admin_division();
 return query select p.id,coalesce(l.n,0)::bigint,coalesce(c.ap,0)::numeric from public.profiles p
 left join(select agent_key,sum(lead_count) n from private.lead_totals where status='assigned' and (master or division=div) group by agent_key)l on l.agent_key=p.id::text
 left join(select cb.agent_id,sum(cb.annual_premium) ap from public.closed_business cb group by cb.agent_id)c on c.agent_id=p.id
 where p.role='agent' and not coalesce(p.archived,false) and (master or p.division=div);
end $$;
create or replace function public.admin_lead_filter_counts_scoped(p_division text default null)
returns table(lead_type text,state text,lead_count bigint) language plpgsql security definer set search_path='' as $$
declare div text;
begin
 if auth.uid() is null or not public.is_admin() then raise exception 'Admin only' using errcode='42501';end if;
 div:=case when public.is_super_admin() then coalesce(nullif(p_division,''),public.current_admin_division()) else public.current_admin_division() end;
 if div is null or div not in ('owner','vivid_life','legacy_life') then raise exception 'Invalid division';end if;
 return query select nullif(t.lead_type,''),nullif(t.state,''),sum(t.lead_count)::bigint from private.lead_totals t
 where t.division=div and t.status='unassigned' group by t.lead_type,t.state having sum(t.lead_count)>0;
end $$;
revoke execute on function public.admin_dashboard_stats(),public.admin_agent_stats(),public.admin_lead_filter_counts_scoped(text) from public,anon;
grant execute on function public.admin_dashboard_stats(),public.admin_agent_stats(),public.admin_lead_filter_counts_scoped(text) to authenticated;

-- One trigram index for the common free-text search, instead of scanning nine columns.
create extension if not exists pg_trgm with schema extensions;
alter table public.leads add column search_text text generated always as (
 coalesce(first_name,'')||' '||coalesce(last_name,'')||' '||coalesce(phone,'')||' '||coalesce(email,'')||' '||
 coalesce(state,'')||' '||coalesce(source,'')||' '||coalesce(lead_type,'')||' '||coalesce(agent_status,'')||' '||coalesce(call_notes,'')
) stored;
create index leads_search_text_trgm on public.leads using gin(search_text extensions.gin_trgm_ops);
