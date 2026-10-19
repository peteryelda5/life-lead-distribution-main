-- Admins and team leaders may release only their own open assignments.
-- No agency transfer occurs: each lead stays in its existing agency pool.
create table if not exists private.my_lead_pool_returns (
 request_id uuid primary key,
 actor_id uuid not null,
 fingerprint text not null,
 lead_count integer not null check(lead_count between 1 and 1000),
 created_at timestamptz not null default now()
);
alter table private.my_lead_pool_returns enable row level security;
revoke all on private.my_lead_pool_returns from public,anon,authenticated;

create or replace function private.return_my_leads_to_pool(p_leads jsonb,p_request_id uuid)
returns integer language plpgsql security definer set search_path='' as $$
declare who uuid:=auth.uid(); expected integer; ids uuid[]; signature text; n integer;
 previous private.my_lead_pool_returns%rowtype; destinations jsonb; sender text;
begin
 if who is null or not private.verified_portal_session() then
  raise exception 'Sign in and complete two-step verification.' using errcode='42501';
 end if;
 perform set_config('lock_timeout','3s',true);
 -- Read the current profile, never user-editable JWT metadata. Hold the role
 -- stable until the return completes so a demotion cannot race the mutation.
 select p.full_name into sender from public.profiles p where p.id=who and p.active
 and not coalesce(p.archived,false) and (p.role='admin' or (p.role='agent' and p.is_team_leader)) for share;
 if not found then raise exception 'Only admins and team leaders can return their own leads.' using errcode='42501';end if;
 if p_request_id is null or p_leads is null or jsonb_typeof(p_leads)<>'array' then raise exception 'Select the leads you want to return.';end if;
 expected:=jsonb_array_length(p_leads);
 if expected<1 or expected>1000 then raise exception 'Select 1–1,000 leads.';end if;
 if (select count(*) from jsonb_to_recordset(p_leads) x(id uuid,updated_at timestamptz) where id is not null and updated_at is not null)<>expected
 or (select count(distinct id) from jsonb_to_recordset(p_leads) x(id uuid,updated_at timestamptz))<>expected
 then raise exception 'Invalid preview. Close this window and try again.';end if;
 select array_agg(id order by id),md5(jsonb_agg(jsonb_build_object('id',id,'updated_at',updated_at) order by id)::text)
 into ids,signature from jsonb_to_recordset(p_leads) x(id uuid,updated_at timestamptz);
 perform pg_advisory_xact_lock(hashtextextended('my-lead-return:'||p_request_id::text,0));
 select * into previous from private.my_lead_pool_returns where request_id=p_request_id;
 if found then
  if previous.actor_id<>who or previous.fingerprint<>signature then raise exception 'This return request has already been used. Open a new preview.';end if;
  return previous.lead_count;
 end if;
 perform id from public.leads where id=any(ids) order by id for update;
 if (select count(*) from public.leads l join jsonb_to_recordset(p_leads) x(id uuid,updated_at timestamptz) on x.id=l.id
  where l.assigned_to=who and l.status='assigned' and l.updated_at=x.updated_at
  and not exists(select 1 from public.closed_business b where b.lead_id=l.id))<>expected
 then raise exception 'A selected lead changed, closed, or is no longer assigned to you. Nothing was returned. Open a new preview.' using errcode='40001';end if;
 select jsonb_agg(jsonb_build_object('division',division,'count',lead_count)) into destinations
 from (select division,count(*) lead_count from public.leads where id=any(ids) group by division) d;
 update public.leads set assigned_to=null,assigned_at=null,status='unassigned',updated_at=now()
 where id=any(ids) and assigned_to=who and status='assigned';
 get diagnostics n=row_count;
 if n<>expected then raise exception 'Some assignments changed. Nothing was returned.';end if;
 -- Unassignment is intentionally not recorded by the assignment-delivery trigger.
 -- Record the user's explicit return as one receipt per destination pool.
 insert into public.lead_delivery_receipts(sender_id,sender_name,source_division,source_name,destination_division,destination_name,recipient_id,recipient_name,lead_count,lead_ids)
 select who,sender,l.division,d.name,l.division,d.name,null,null,count(*)::integer,array_agg(l.id order by l.id)
 from public.leads l join public.divisions d on d.id=l.division where l.id=any(ids) group by l.division,d.name;
 insert into private.my_lead_pool_returns(request_id,actor_id,fingerprint,lead_count) values(p_request_id,who,signature,n);
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
 values(who,'own_leads_returned_to_pool','lead',p_request_id::text,jsonb_build_object('count',n,'lead_ids',ids,'destinations',destinations));
 return n;
end $$;
create or replace function public.return_my_leads_to_pool(p_leads jsonb,p_request_id uuid)
returns integer language sql security invoker set search_path='' as $$select private.return_my_leads_to_pool(p_leads,p_request_id)$$;
revoke all on function private.return_my_leads_to_pool(jsonb,uuid),public.return_my_leads_to_pool(jsonb,uuid) from public,anon;
grant execute on function private.return_my_leads_to_pool(jsonb,uuid),public.return_my_leads_to_pool(jsonb,uuid) to authenticated;
