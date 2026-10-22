-- Carrier confirmations are independent of the agent-selected pipeline/production status.
-- No historical pipeline or issued status is treated as carrier evidence.
create table private.book_crm_carrier_status (
 policy_id uuid primary key references private.book_crm_clients(id) on delete cascade,
 status text not null check(status in ('unverified','pending','underwriting','approved','issued','in_force','lapsed','cancelled','declined')),
 source text, confirmed_on date, reference text not null check(length(trim(reference)) between 1 and 500),
 notes text not null default '' check(length(notes)<=2000),
 carrier text not null,policy_type text not null,policy_number text not null,
 recorded_by uuid not null references public.profiles(id),recorded_at timestamptz not null default clock_timestamp(),
 check((status='unverified' and source is null and confirmed_on is null) or
       (status<>'unverified' and source is not null and source in ('carrier_portal','carrier_email','carrier_statement','carrier_phone') and confirmed_on is not null))
);
create index book_crm_carrier_status_actor on private.book_crm_carrier_status(recorded_by);
alter table private.book_crm_carrier_status enable row level security;
revoke all on private.book_crm_carrier_status from public,anon,authenticated;

alter table private.book_crm_activity add column metadata jsonb;

create function private.book_crm_carrier_status_save(p_policy uuid,p_status text,p_source text,p_confirmed_on date,p_reference text,p_notes text,p_expected_updated_at timestamptz) returns jsonb
language plpgsql security definer set search_path='' as $$
declare c private.book_crm_clients%rowtype; r jsonb; prior jsonb; saved jsonb; stamp timestamptz:=clock_timestamp();
begin
 if auth.uid() is null or not private.book_is_unlocked() then raise exception 'Book of Business is locked. Enter your PIN.' using errcode='42501';end if;
 if p_policy is null or p_status is null or p_status<>all(array['unverified','pending','underwriting','approved','issued','in_force','lapsed','cancelled','declined']) then raise exception 'Choose a valid carrier status';end if;
 if coalesce(length(trim(p_reference)),0) not between 1 and 500 or coalesce(length(p_notes),0)>2000 then raise exception 'Enter a carrier reference or reset reason (up to 500 characters); notes allow 2000 characters';end if;
 if p_status<>'unverified' and (p_source is null or p_source<>all(array['carrier_portal','carrier_email','carrier_statement','carrier_phone']) or p_confirmed_on is null or p_confirmed_on>current_date or p_confirmed_on<date '1900-01-01') then raise exception 'Choose a carrier source and a confirmation date that is not in the future';end if;
 if p_status='unverified' then p_source:=null;p_confirmed_on:=null;end if;
 perform pg_advisory_xact_lock(hashtextextended(p_policy::text,49412));
 select * into c from private.book_crm_clients where id=p_policy for update;
 if not found or not private.book_crm_can_access(c.agent_id,c.deal_id) then raise exception 'Policy not available to your account' using errcode='42501';end if;
 if c.updated_at is distinct from p_expected_updated_at then raise sqlstate 'PT409' using message='Policy changed. Reopen the policy before recording carrier status.';end if;
 select to_jsonb(v) into r from private.book_crm_records v where v.id=p_policy;
 if p_status<>'unverified' and (coalesce(trim(r->>'carrier'),'')='' or coalesce(trim(r->>'policy_type'),'')='') then raise exception 'Record the carrier and policy type first';end if;
 select to_jsonb(s) into prior from private.book_crm_carrier_status s where policy_id=p_policy;
 insert into private.book_crm_carrier_status(policy_id,status,source,confirmed_on,reference,notes,carrier,policy_type,policy_number,recorded_by,recorded_at)
 values(p_policy,p_status,p_source,p_confirmed_on,trim(p_reference),trim(coalesce(p_notes,'')),coalesce(r->>'carrier',''),coalesce(r->>'policy_type',''),coalesce(r->>'policy_number',''),auth.uid(),stamp)
 on conflict(policy_id) do update set status=excluded.status,source=excluded.source,confirmed_on=excluded.confirmed_on,reference=excluded.reference,notes=excluded.notes,carrier=excluded.carrier,policy_type=excluded.policy_type,policy_number=excluded.policy_number,recorded_by=excluded.recorded_by,recorded_at=excluded.recorded_at;
 -- Only the concurrency version changes. Pipeline, production, premium and deal are untouched.
 update private.book_crm_clients set updated_at=stamp where id=p_policy;
 select to_jsonb(s) into saved from private.book_crm_carrier_status s where policy_id=p_policy;
 insert into private.book_crm_activity(client_id,actor_id,kind,body,metadata)
 values(p_policy,auth.uid(),'updated',case when p_status='unverified' then 'Carrier status reset to Unverified. Reason: '||trim(p_reference)
 else 'Carrier status recorded: '||initcap(replace(p_status,'_',' '))||' · '||initcap(replace(p_source,'_',' '))||' · confirmed '||p_confirmed_on::text||'. Reference: '||trim(p_reference) end,
 jsonb_build_object('event','carrier_status','before',prior,'after',saved));
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'crm_carrier_status_saved','crm_policy',p_policy::text,jsonb_build_object('before',prior,'after',saved));
 return jsonb_build_object('ok',true,'id',p_policy,'updated_at',stamp);
end;$$;
create function public.book_crm_carrier_status_save(p_policy uuid,p_status text,p_source text,p_confirmed_on date,p_reference text,p_notes text,p_expected_updated_at timestamptz) returns jsonb
language sql security invoker set search_path='' as $$select private.book_crm_carrier_status_save(p_policy,p_status,p_source,p_confirmed_on,p_reference,p_notes,p_expected_updated_at)$$;
revoke all on function private.book_crm_carrier_status_save(uuid,text,text,date,text,text,timestamptz),public.book_crm_carrier_status_save(uuid,text,text,date,text,text,timestamptz) from public,anon,authenticated;
grant execute on function private.book_crm_carrier_status_save(uuid,text,text,date,text,text,timestamptz),public.book_crm_carrier_status_save(uuid,text,text,date,text,text,timestamptz) to authenticated;

create or replace view private.book_crm_records as
select c.id,c.agent_id,c.client_name,c.address_line1,c.address_line2,c.city,c.state,c.zip,c.phone,c.email,
 coalesce(d.carrier,c.carrier) carrier,coalesce(d.policy_type,c.policy_type) policy_type,
 coalesce(d.monthly_premium,c.monthly_payment) monthly_payment,
 case when d.id is null then c.policy_number else coalesce(d.policy_number,'') end policy_number,
 coalesce(d.application_date,c.application_date) application_date,c.status,c.notes,c.deal_id,c.production_recorded,c.created_at,c.updated_at,
 c.effective_date,c.alternate_phone,c.date_of_birth,c.mortgage_balance,private.book_crm_stage(c.pipeline_stage,c.status) pipeline_stage,
 p.full_name agent_name,
 case when x.deal_id is not null then round(d.annual_premium*x.comp_percent/100*x.advance_percent/100,2)
 when d.id is null and g.id is not null then round(c.monthly_payment*12*g.comp_percent/100*g.advance_percent/100,2) end estimated_advance,
 coalesce(x.comp_percent,g.comp_percent) comp_percent,coalesce(x.advance_percent,g.advance_percent) advance_percent,
 case when d.id is null then null else jsonb_build_object('carrier',d.carrier,'policy_type',d.policy_type,'monthly_premium',d.monthly_premium,'application_date',d.application_date,'policy_number',d.policy_number,'notes',d.notes) end deal_version,
 t.id next_task_id,t.title next_task_title,t.due_at next_task_due,c.profile_id,
 coalesce(cs.status,'unverified') carrier_status,cs.source carrier_status_source,cs.confirmed_on carrier_confirmed_on,
 cs.reference carrier_status_reference,cs.notes carrier_status_notes,cs.recorded_at carrier_status_recorded_at,
 cs.recorded_by carrier_status_recorded_by,cp.full_name carrier_status_recorded_by_name,
 (cs.policy_id is not null and cs.carrier=coalesce(d.carrier,c.carrier) and cs.policy_type=coalesce(d.policy_type,c.policy_type)
 and cs.policy_number=case when d.id is null then c.policy_number else coalesce(d.policy_number,'') end) carrier_status_current,
 cs.carrier carrier_status_carrier,cs.policy_type carrier_status_policy_type,cs.policy_number carrier_status_policy_number
from private.book_crm_clients c join public.profiles p on p.id=c.agent_id
left join private.book_crm_carrier_status cs on cs.policy_id=c.id
left join public.profiles cp on cp.id=cs.recorded_by
left join public.closed_business d on d.id=c.deal_id left join private.book_deal_comp x on x.deal_id=d.id
left join lateral(select g.* from private.book_comp_grid g where g.agent_id=c.agent_id and g.carrier=lower(trim(coalesce(d.carrier,c.carrier))) and g.policy_type=lower(trim(coalesce(d.policy_type,c.policy_type))) and g.effective_date<=coalesce(d.application_date,c.application_date) order by g.effective_date desc limit 1)g on true
left join lateral(select t.id,t.title,t.due_at from private.book_crm_tasks t where t.client_id=c.id and t.completed_at is null order by t.due_at,t.id limit 1)t on true;
revoke all on private.book_crm_records from public,anon,authenticated;

create or replace function private.book_crm_profiles_list(p_page int default 1,p_search text default '',p_agent uuid default null,p_stage text default '',p_limit int default 50) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb; lim int:=greatest(1,least(coalesce(p_limit,50),2000)); offn int;
begin
 if auth.uid() is null or not private.book_is_unlocked() then raise exception 'Book of Business is locked. Enter your PIN.' using errcode='42501';end if;
 if coalesce(p_stage,'')<>'' and p_stage<>all(array['new','contacted','submitted','approved','in_force','lapsed','cancelled']) then raise exception 'Invalid pipeline stage';end if;
 offn:=(greatest(1,least(coalesce(p_page,1),100000))-1)*lim;
 with permitted as materialized (
  select r.* from private.book_crm_records r where private.book_crm_can_access(r.agent_id,r.deal_id) and (p_agent is null or r.agent_id=p_agent)
 ), searched as materialized (
  select * from permitted r where coalesce(p_search,'')='' or concat_ws(' ',r.client_name,r.agent_name,r.carrier,r.policy_type,r.policy_number,r.phone,r.email,r.address_line1,r.city,r.state,r.zip) ilike '%'||left(p_search,100)||'%'
 ), matched as materialized (select * from searched where coalesce(p_stage,'')='' or pipeline_stage=p_stage),
 people as materialized (select p.* from private.book_crm_profiles p where exists(select 1 from matched m where m.profile_id=p.id)),
 paged as (select p.*,a.full_name agent_name from people p join public.profiles a on a.id=p.agent_id order by p.created_at desc,p.id limit lim offset offn),
 rows as (select p.details||jsonb_build_object('id',p.id,'agent_id',p.agent_id,'agent_name',p.agent_name,'created_at',p.created_at,'updated_at',p.updated_at,
  'policy_count',count(r.id),'policies',jsonb_agg(jsonb_build_object('id',r.id,'carrier',r.carrier,'policy_type',r.policy_type,'policy_number',r.policy_number,'monthly_payment',r.monthly_payment,'effective_date',r.effective_date,'pipeline_stage',r.pipeline_stage,'status',r.status,'carrier_status',r.carrier_status,'carrier_status_current',r.carrier_status_current,'carrier_confirmed_on',r.carrier_confirmed_on,'estimated_advance',r.estimated_advance) order by r.created_at,r.id),
  'monthly_payment',coalesce(sum(r.monthly_payment) filter(where r.status in ('active','issued')),0),
  'estimated_advance',coalesce(sum(r.estimated_advance) filter(where r.status in ('active','issued')),0),
  'missing_comp',count(*) filter(where r.status in ('active','issued') and r.estimated_advance is null)) data,p.created_at,p.id
  from paged p join permitted r on r.profile_id=p.id group by p.id,p.details,p.agent_id,p.agent_name,p.created_at,p.updated_at)
 select jsonb_build_object('rows',coalesce((select jsonb_agg(data order by created_at desc,id) from rows),'[]'),
  'count',(select count(*) from people),'policy_count',(select count(*) from matched),
  'stage_counts',coalesce((select jsonb_object_agg(pipeline_stage,n) from(select pipeline_stage,count(*) n from searched group by pipeline_stage)s),'{}'),
  'monthly_payment',(select coalesce(sum(monthly_payment),0) from matched where status in ('active','issued')),
  'estimated_advance',(select coalesce(sum(estimated_advance),0) from matched where status in ('active','issued')),
  'followups_due',(select count(*) from private.book_crm_tasks t join matched r on r.id=t.client_id where t.completed_at is null and t.due_at<=now())) into result;
 return result;
end;$$;


notify pgrst,'reload schema';
