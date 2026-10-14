-- Master-only, previewed recall from every agency, including archived agencies.
-- Apply together with agency-lead-recall-trigger.sql in one migration.
create table if not exists private.agency_lead_recalls (
 request_id uuid primary key,
 actor_id uuid not null,
 source text not null,
 fingerprint text not null,
 lead_count integer not null check (lead_count between 1 and 1000),
 created_at timestamptz not null default now()
);
alter table private.agency_lead_recalls enable row level security;
revoke all on private.agency_lead_recalls from public, anon, authenticated;

create or replace function private.can_recall_agency_pool(p_source text,p_destination text)
returns boolean language sql stable security definer set search_path='' as $$
 select private.verified_portal_session() and p_destination='owner' and p_source<>'owner'
 and exists(select 1 from public.divisions where id=p_source)
 and exists(select 1 from public.profiles where id=auth.uid() and role='admin' and is_super_admin
 and active and not coalesce(archived,false))
$$;
revoke all on function private.can_recall_agency_pool(text,text) from public,anon,authenticated;

create or replace function private.assert_agency_recall_access(p_source text)
returns void language plpgsql stable security definer set search_path='' as $$
begin
 if not private.verified_portal_session() or not exists (
  select 1 from public.profiles where id=auth.uid() and role='admin' and is_super_admin
  and active and not coalesce(archived,false)
 ) then raise exception 'Only a verified Master Admin can take back agency leads.' using errcode='42501'; end if;
 if p_source is null or p_source='owner' or not exists (
  select 1 from public.divisions where id=p_source
 ) then raise exception 'Choose an agency to take leads back from.'; end if;
end $$;
revoke all on function private.assert_agency_recall_access(text) from public, anon, authenticated;

create or replace function private.agency_recall_agencies()
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not private.verified_portal_session() or not exists(select 1 from public.profiles
  where id=auth.uid() and role='admin' and is_super_admin and active and not coalesce(archived,false))
 then raise exception 'Only a verified Master Admin can take back agency leads.' using errcode='42501';end if;
 return (select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name,'archived',archived) order by archived,name),'[]'::jsonb)
 from public.divisions where id<>'owner');
end $$;

create or replace function private.agency_recall_options(p_source text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 perform private.assert_agency_recall_access(p_source);
 return (select coalesce(jsonb_agg(jsonb_build_object('type',t.lead_type,'count',t.n) order by t.lead_type),'[]'::jsonb)
 from (select coalesce(l.lead_type,'') lead_type,count(*) n from public.leads l
 where l.division=p_source and l.status in ('assigned','unassigned')
 and not exists(select 1 from public.closed_business b where b.lead_id=l.id)
 group by coalesce(l.lead_type,'')) t);
end $$;

create or replace function private.agency_recall_preview(p_source text,p_type text,p_scope text,p_count integer)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare available bigint; rows jsonb;
begin
 perform private.assert_agency_recall_access(p_source);
 if p_scope is null or p_scope not in ('all','pool','assigned') then raise exception 'Choose which leads to include.'; end if;
 if p_count is null or p_count<1 or p_count>1000 then raise exception 'Choose 1–1,000 leads per recall.'; end if;
 select count(*) into available from public.leads l
 where l.division=p_source and l.status in ('assigned','unassigned')
 and (p_type is null or coalesce(l.lead_type,'')=p_type)
 and (p_scope='all' or (p_scope='pool' and l.assigned_to is null) or (p_scope='assigned' and l.assigned_to is not null))
 and not exists(select 1 from public.closed_business b where b.lead_id=l.id);
 select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at,t.id),'[]'::jsonb) into rows from (
  select l.id,l.updated_at,l.created_at,l.first_name,l.last_name,l.phone,l.lead_type,l.assigned_to,
   case when l.assigned_to is null then 'Agency lead pool' else coalesce(nullif(p.full_name,''),'Assigned user') end as assignee
  from public.leads l left join public.profiles p on p.id=l.assigned_to
  where l.division=p_source and l.status in ('assigned','unassigned')
  and (p_type is null or coalesce(l.lead_type,'')=p_type)
  and (p_scope='all' or (p_scope='pool' and l.assigned_to is null) or (p_scope='assigned' and l.assigned_to is not null))
  and not exists(select 1 from public.closed_business b where b.lead_id=l.id)
  order by l.created_at,l.id limit p_count
 ) t;
 return jsonb_build_object('available',available,'leads',rows);
end $$;

create or replace function private.agency_recall_commit(p_source text,p_leads jsonb,p_request_id uuid)
returns integer language plpgsql security definer set search_path='' as $$
declare expected integer; ids uuid[]; signature text; previous private.agency_lead_recalls%rowtype;
 n integer; assignments jsonb;
begin
 perform private.assert_agency_recall_access(p_source);
 if p_request_id is null or p_leads is null or jsonb_typeof(p_leads)<>'array' then raise exception 'Preview the leads before taking them back.'; end if;
 expected:=jsonb_array_length(p_leads);
 if expected<1 or expected>1000 then raise exception 'Choose 1–1,000 leads per recall.'; end if;
 if (select count(*) from jsonb_to_recordset(p_leads) as x(id uuid,updated_at timestamptz) where id is not null and updated_at is not null)<>expected
 or (select count(distinct id) from jsonb_to_recordset(p_leads) as x(id uuid,updated_at timestamptz))<>expected then raise exception 'Invalid lead preview.'; end if;
 select array_agg(id order by id),md5(jsonb_agg(jsonb_build_object('id',id,'updated_at',updated_at) order by id)::text)
 into ids,signature from jsonb_to_recordset(p_leads) as x(id uuid,updated_at timestamptz);
 perform set_config('lock_timeout','3s',true);
 perform pg_advisory_xact_lock(hashtextextended(p_request_id::text,0));
 select * into previous from private.agency_lead_recalls where request_id=p_request_id;
 if found then
  if previous.actor_id<>auth.uid() or previous.source<>p_source or previous.fingerprint<>signature then raise exception 'This recall request has already been used. Preview again.'; end if;
  return previous.lead_count;
 end if;
 -- Lock in a consistent order; any changed or closed lead aborts the entire recall.
 perform id from public.leads where id=any(ids) order by id for update;
 if (select count(*) from public.leads l join jsonb_to_recordset(p_leads) as x(id uuid,updated_at timestamptz) on x.id=l.id
  where l.division=p_source and l.status in ('assigned','unassigned') and l.updated_at=x.updated_at
  and not exists(select 1 from public.closed_business b where b.lead_id=l.id))<>expected
 then raise exception 'Some leads changed since your preview. No leads were taken back. Preview again.' using errcode='40001'; end if;
 select jsonb_agg(jsonb_build_object('id',id,'assigned_to',assigned_to)) into assignments from public.leads where id=any(ids);
 update public.leads set assigned_to=null,assigned_at=null,status='unassigned'
 where id=any(ids) and (assigned_to is not null or status<>'unassigned' or assigned_at is not null);
 -- Both steps commit together. The trigger permits only a verified Master recall
 -- to Owner, while existing history and delivery receipts capture the move.
 update public.leads set division='owner',assigned_at=null where id=any(ids) and division=p_source and status='unassigned' and assigned_to is null;
 get diagnostics n=row_count;
 if n<>expected then raise exception 'Recall changed. No leads were taken back.'; end if;
 insert into private.agency_lead_recalls(request_id,actor_id,source,fingerprint,lead_count)
 values(p_request_id,auth.uid(),p_source,signature,n);
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
 values(auth.uid(),'agency_leads_reclaimed','lead',p_request_id::text,
 jsonb_build_object('source',p_source,'destination','owner','count',n,'lead_ids',ids,'previous_assignments',assignments));
 return n;
end $$;

create or replace function public.agency_recall_agencies()
returns jsonb language sql security invoker set search_path='' as $$select private.agency_recall_agencies()$$;
create or replace function public.agency_recall_options(p_source text)
returns jsonb language sql security invoker set search_path='' as $$select private.agency_recall_options(p_source)$$;
create or replace function public.agency_recall_preview(p_source text,p_type text,p_scope text,p_count integer)
returns jsonb language sql security invoker set search_path='' as $$select private.agency_recall_preview(p_source,p_type,p_scope,p_count)$$;
create or replace function public.agency_recall_commit(p_source text,p_leads jsonb,p_request_id uuid)
returns integer language sql security invoker set search_path='' as $$select private.agency_recall_commit(p_source,p_leads,p_request_id)$$;
revoke all on function private.agency_recall_agencies(),public.agency_recall_agencies(),private.agency_recall_options(text),public.agency_recall_options(text),
 private.agency_recall_preview(text,text,text,integer),public.agency_recall_preview(text,text,text,integer),
 private.agency_recall_commit(text,jsonb,uuid),public.agency_recall_commit(text,jsonb,uuid) from public,anon;
grant execute on function private.agency_recall_agencies(),public.agency_recall_agencies(),private.agency_recall_options(text),public.agency_recall_options(text),
 private.agency_recall_preview(text,text,text,integer),public.agency_recall_preview(text,text,text,integer),
 private.agency_recall_commit(text,jsonb,uuid),public.agency_recall_commit(text,jsonb,uuid) to authenticated;
