-- Carrier problems belong to the policy's agent through the existing task scope.
alter table private.book_crm_tasks
 add column source text not null default 'manual' check(source in ('manual','carrier_status')),
 add column priority text not null default 'normal' check(priority in ('normal','high')),
 add column carrier_status text check(carrier_status in ('initial_premium_failed','grace_period','late_offer_period','lapsed','cancelled','declined'));
-- Reuse one automated task per policy, including when a later issue reopens it.
create unique index book_crm_tasks_carrier_policy on private.book_crm_tasks(client_id) where source='carrier_status';

create function private.book_crm_sync_carrier_task(p_policy uuid,p_status text,p_actor uuid,p_reopen boolean default false) returns void
language plpgsql security definer set search_path='' as $$
declare t private.book_crm_tasks%rowtype; label text; stamp timestamptz:=clock_timestamp(); event text;
begin
 select * into t from private.book_crm_tasks where client_id=p_policy and source='carrier_status' for update;
 if p_status=any(array['initial_premium_failed','grace_period','late_offer_period','lapsed','cancelled','declined']) then
  label:=case p_status when 'initial_premium_failed' then 'Initial premium failed' when 'grace_period' then 'Grace period'
   when 'late_offer_period' then 'Late offer period' when 'lapsed' then 'Lapsed' when 'cancelled' then 'Cancelled' when 'declined' then 'Declined' end;
  if t.id is null then
   insert into private.book_crm_tasks(client_id,title,due_at,created_by,source,priority,carrier_status)
   values(p_policy,'Carrier follow-up: '||label,stamp,p_actor,'carrier_status','high',p_status);
   event:='task_added';
  elsif t.carrier_status is distinct from p_status or p_reopen then
   update private.book_crm_tasks set title='Carrier follow-up: '||label,priority='high',carrier_status=p_status,
    due_at=case when t.completed_at is null then t.due_at else stamp end,completed_at=null,updated_at=stamp where id=t.id;
   event:=case when t.completed_at is null then 'updated' else 'task_reopened' end;
  end if;
  if event is not null then
   insert into private.book_crm_activity(client_id,actor_id,kind,body,metadata)
   values(p_policy,p_actor,event,'Action required: '||label||'. Follow up with the client and carrier.',jsonb_build_object('event','carrier_followup','status',p_status));
  end if;
 elsif t.id is not null and t.completed_at is null then
  update private.book_crm_tasks set completed_at=stamp,updated_at=stamp where id=t.id;
  insert into private.book_crm_activity(client_id,actor_id,kind,body,metadata)
  values(p_policy,p_actor,'task_completed','Carrier follow-up cleared after carrier status changed to '||replace(p_status,'_',' ')||'.',jsonb_build_object('event','carrier_followup_resolved','status',p_status));
 end if;
end;$$;
create function private.book_crm_carrier_task_trigger() returns trigger
language plpgsql security definer set search_path='' as $$
declare reopen boolean:=false;
begin
 if tg_op='UPDATE' then reopen:=(new.status,new.carrier,new.policy_type,new.policy_number) is distinct from (old.status,old.carrier,old.policy_type,old.policy_number);end if;
 perform private.book_crm_sync_carrier_task(new.policy_id,new.status,new.recorded_by,reopen);
 return new;
end;$$;
revoke all on function private.book_crm_sync_carrier_task(uuid,text,uuid,boolean),private.book_crm_carrier_task_trigger() from public,anon,authenticated;
create trigger book_crm_carrier_task after insert or update on private.book_crm_carrier_status for each row execute function private.book_crm_carrier_task_trigger();

-- Include existing, identity-matched problem statuses; never infer carrier evidence.
do $$ declare r record;begin
 for r in select s.policy_id,s.status,s.recorded_by from private.book_crm_carrier_status s join private.book_crm_records c on c.id=s.policy_id
 where c.carrier_status_current and s.status in ('initial_premium_failed','grace_period','late_offer_period','lapsed','cancelled','declined')
 loop perform private.book_crm_sync_carrier_task(r.policy_id,r.status,r.recorded_by,false);end loop;
end;$$;

-- Delete only the requested CRM profile and its policy children. Preserve recorded
-- production, lead status and compensation snapshots; retain a private audit snapshot.
create function private.book_crm_profile_delete(p_id uuid,p_expected_updated_at timestamptz,p_expected_policies jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare person private.book_crm_profiles%rowtype; c record; current_versions jsonb; expected_versions jsonb; snapshot jsonb; n integer;
begin
 if auth.uid() is null or not private.book_is_unlocked() then raise exception 'Book of Business is locked. Enter your PIN.' using errcode='42501';end if;
 if p_id is null or p_expected_policies is null or jsonb_typeof(p_expected_policies)<>'array' then raise exception 'Reopen the client before deleting it';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,49413));
 select * into person from private.book_crm_profiles where id=p_id;
 if not found or not private.book_crm_can_access(person.agent_id,null) then raise exception 'Client not available to your account' using errcode='42501';end if;
 -- Same profile-before-policy lock order used by Add policy. Lock rows before the
 -- profile row so legacy contact synchronization can finish without a lock cycle.
 for c in select id from private.book_crm_clients where profile_id=p_id order by id loop
  perform pg_advisory_xact_lock(hashtextextended(c.id::text,49412));
  perform 1 from private.book_crm_clients where id=c.id for update;
 end loop;
 select * into person from private.book_crm_profiles where id=p_id for update;
 if exists(select 1 from private.book_crm_clients c where c.profile_id=p_id and not private.book_crm_can_access(c.agent_id,c.deal_id)) then raise exception 'Not all policies are available to your account' using errcode='42501';end if;
 perform 1 from public.closed_business d where d.id in (select deal_id from private.book_crm_clients where profile_id=p_id) order by d.id for update;
 select jsonb_agg(jsonb_build_object('id',id,'updated_at',updated_at,'deal_version',deal_version) order by id),count(*)
 into current_versions,n from private.book_crm_records where profile_id=p_id;
 select jsonb_agg(value order by value->>'id') into expected_versions from jsonb_array_elements(p_expected_policies);
 if n=0 or person.updated_at is distinct from p_expected_updated_at or current_versions is distinct from expected_versions then
  raise sqlstate 'PT409' using message='Client or policies changed. Reopen the client before deleting it.';
 end if;
 perform 1 from private.book_crm_tasks t join private.book_crm_clients c on c.id=t.client_id where c.profile_id=p_id order by t.id for update of t;
 select jsonb_build_object('profile',to_jsonb(person),
  'policies',(select jsonb_agg(to_jsonb(c) order by c.id) from private.book_crm_clients c where c.profile_id=p_id),
  'tasks',coalesce((select jsonb_agg(to_jsonb(t)) from private.book_crm_tasks t join private.book_crm_clients c on c.id=t.client_id where c.profile_id=p_id),'[]'::jsonb),
  'activity',coalesce((select jsonb_agg(to_jsonb(a)) from private.book_crm_activity a join private.book_crm_clients c on c.id=a.client_id where c.profile_id=p_id),'[]'::jsonb),
  'carrier_statuses',coalesce((select jsonb_agg(to_jsonb(s)) from private.book_crm_carrier_status s join private.book_crm_clients c on c.id=s.policy_id where c.profile_id=p_id),'[]'::jsonb)) into snapshot;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
 values(auth.uid(),'crm_client_deleted','crm_profile',p_id::text,jsonb_build_object('before',snapshot,'policy_count',n,'production_preserved',true));
 delete from private.book_crm_clients where profile_id=p_id;
 delete from private.book_crm_profiles where id=p_id;
 return jsonb_build_object('ok',true,'id',p_id,'deleted_policies',n);
end;$$;
create function public.book_crm_profile_delete(p_id uuid,p_expected_updated_at timestamptz,p_expected_policies jsonb) returns jsonb
language sql security invoker set search_path='' as $$select private.book_crm_profile_delete(p_id,p_expected_updated_at,p_expected_policies)$$;
revoke all on function private.book_crm_profile_delete(uuid,timestamptz,jsonb),public.book_crm_profile_delete(uuid,timestamptz,jsonb) from public,anon,authenticated;
grant execute on function private.book_crm_profile_delete(uuid,timestamptz,jsonb),public.book_crm_profile_delete(uuid,timestamptz,jsonb) to authenticated;

CREATE OR REPLACE FUNCTION private.book_crm_workspace(p_page integer DEFAULT 1, p_search text DEFAULT ''::text, p_agent uuid DEFAULT NULL::uuid, p_stage text DEFAULT ''::text, p_limit integer DEFAULT 50, p_view text DEFAULT 'clients'::text, p_task_status text DEFAULT 'open'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare result jsonb; lim int:=greatest(1,least(coalesce(p_limit,50),2000)); offn int;
begin
 if auth.uid() is null or not private.book_is_unlocked() then raise exception 'Book of Business is locked. Enter your PIN.' using errcode='42501'; end if;
 if coalesce(p_stage,'')<>'' and p_stage<>all(array['new','contacted','submitted','approved','in_force','lapsed','cancelled']) then raise exception 'Invalid pipeline stage'; end if;
 if p_view<>all(array['clients','pipeline','tasks']) or p_task_status<>all(array['open','completed']) then raise exception 'Invalid view';end if;
 offn:=(greatest(1,least(coalesce(p_page,1),100000))-1)*lim;
 with permitted as materialized (
 select r.* from private.book_crm_records r where private.book_crm_can_access(r.agent_id,r.deal_id) and (p_agent is null or r.agent_id=p_agent)
 and (coalesce(p_search,'')='' or concat_ws(' ',r.client_name,r.agent_name,r.carrier,r.policy_type,r.policy_number,r.phone,r.email,r.address_line1,r.city,r.state,r.zip) ilike '%'||left(p_search,100)||'%')
 ), filtered as materialized (select * from permitted where coalesce(p_stage,'')='' or pipeline_stage=p_stage),
 paged as (select * from filtered order by created_at desc,id limit lim offset offn),
 ranked as (select f.*,row_number() over(partition by pipeline_stage order by created_at desc,id) rn from filtered f),
 tasks as materialized (select t.*,f.client_name,f.agent_name,f.pipeline_stage,f.carrier,f.policy_type,f.policy_number,f.profile_id from private.book_crm_tasks t join filtered f on f.id=t.client_id where (p_task_status='open' and t.completed_at is null) or (p_task_status='completed' and t.completed_at is not null)),
 taskpage as (select * from tasks order by (priority='high') desc,due_at,id limit lim offset offn)
 select jsonb_build_object(
 'rows',case when p_view='clients' then coalesce((select jsonb_agg(to_jsonb(paged) order by created_at desc,id) from paged),'[]') else '[]'::jsonb end,
 'pipeline',case when p_view='pipeline' then coalesce((select jsonb_agg(to_jsonb(ranked)-'rn' order by created_at desc,id) from ranked where rn<=25),'[]') else '[]'::jsonb end,
 'tasks',case when p_view='tasks' then coalesce((select jsonb_agg(to_jsonb(taskpage) order by (priority='high') desc,due_at,id) from taskpage),'[]') else '[]'::jsonb end,
 'task_count',(select count(*) from tasks), 'count',(select count(*) from filtered),
 'stage_counts',coalesce((select jsonb_object_agg(pipeline_stage,n) from (select pipeline_stage,count(*) n from permitted group by pipeline_stage)s),'{}'),
 'monthly_payment',(select coalesce(sum(monthly_payment),0) from filtered where status in ('active','issued')),
 'estimated_advance',(select coalesce(sum(estimated_advance),0) from filtered where status in ('active','issued')),
 'followups_due',(select count(*) from private.book_crm_tasks t join permitted f on f.id=t.client_id where completed_at is null and due_at<=now())
 ) into result;
 return result;
end;$function$

;

CREATE OR REPLACE FUNCTION private.book_crm_pipeline(p_search text DEFAULT ''::text, p_agent uuid DEFAULT NULL::uuid, p_carrier text DEFAULT ''::text, p_stage text DEFAULT ''::text, p_page integer DEFAULT 1, p_limit integer DEFAULT 50, p_view text DEFAULT 'board'::text, p_today_start timestamp with time zone DEFAULT NULL::timestamp with time zone, p_today_end timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare result jsonb; lim int:=greatest(1,least(coalesce(p_limit,50),2000)); offn int;
 day_start timestamptz:=coalesce(p_today_start,date_trunc('day',now()));
 day_end timestamptz:=coalesce(p_today_end,date_trunc('day',now())+interval '1 day');
begin
 if auth.uid() is null or not private.book_is_unlocked() then raise exception 'Book of Business is locked. Enter your PIN.' using errcode='42501';end if;
 if p_view is null or p_view<>all(array['board','list']) then raise exception 'Invalid pipeline view';end if;
 if coalesce(p_stage,'')<>'' and p_stage<>all(array['new','contacted','submitted','approved','in_force','lapsed','cancelled']) then raise exception 'Invalid pipeline stage';end if;
 if day_end<=day_start or day_end-day_start>interval '48 hours' then raise exception 'Invalid follow-up day';end if;
 offn:=(greatest(1,least(coalesce(p_page,1),100000))-1)*lim;
 with permitted as materialized (
  select r.* from private.book_crm_records r where private.book_crm_can_access(r.agent_id,r.deal_id) and (p_agent is null or r.agent_id=p_agent)
 ), matched as materialized (
  select * from permitted r where (coalesce(p_carrier,'')='' or r.carrier=p_carrier)
  and (coalesce(p_search,'')='' or concat_ws(' ',r.client_name,r.agent_name,r.carrier,r.policy_type,r.policy_number,r.phone,r.email,r.address_line1,r.city,r.state,r.zip) ilike '%'||left(p_search,100)||'%')
 ), filtered as materialized (select * from matched where coalesce(p_stage,'')='' or pipeline_stage=p_stage),
 paged as (select * from filtered order by created_at desc,id limit lim offset offn),
 ranked as (select f.*,row_number() over(partition by pipeline_stage order by created_at desc,id) rn from filtered f),
 today as materialized (
  select t.*,f.client_name,f.agent_name,f.carrier,f.policy_type,f.policy_number,f.profile_id from private.book_crm_tasks t join filtered f on f.id=t.client_id
  where t.completed_at is null and t.due_at>=day_start and t.due_at<day_end
 ), todaypage as (select * from today order by (priority='high') desc,due_at,id limit 8)
 select jsonb_build_object(
  'rows',case when p_view='list' then coalesce((select jsonb_agg(to_jsonb(paged) order by created_at desc,id) from paged),'[]') else '[]'::jsonb end,
  'pipeline',case when p_view='board' then coalesce((select jsonb_agg(to_jsonb(ranked)-'rn' order by created_at desc,id) from ranked where rn<=25),'[]') else '[]'::jsonb end,
  'count',(select count(*) from filtered),
  'stage_counts',coalesce((select jsonb_object_agg(pipeline_stage,n) from (select pipeline_stage,count(*) n from matched group by pipeline_stage)s),'{}'),
  'carriers',coalesce((select jsonb_agg(carrier order by carrier) from (select distinct carrier from permitted where coalesce(carrier,'')<>'')c),'[]'),
  'today_tasks',coalesce((select jsonb_agg(to_jsonb(todaypage) order by (priority='high') desc,due_at,id) from todaypage),'[]'),
  'today_task_count',(select count(*) from today)
 ) into result;
 return result;
end;$function$

;

CREATE OR REPLACE FUNCTION private.book_crm_profile_detail(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare pid uuid; person private.book_crm_profiles%rowtype; result jsonb;
begin
 if auth.uid() is null or not private.book_is_unlocked() then raise exception 'Book of Business is locked. Enter your PIN.' using errcode='42501';end if;
 select profile_id into pid from private.book_crm_clients where id=p_id;
 pid:=coalesce(pid,p_id);
 select * into person from private.book_crm_profiles where id=pid;
 if not found or not exists(select 1 from private.book_crm_clients c where c.profile_id=pid and private.book_crm_can_access(c.agent_id,c.deal_id)) then raise exception 'Client not available to your account' using errcode='42501';end if;
 with policies as materialized (select r.* from private.book_crm_records r where r.profile_id=pid and private.book_crm_can_access(r.agent_id,r.deal_id)),
 tasks as (select t.*,r.carrier,r.policy_type,r.policy_number from private.book_crm_tasks t join policies r on r.id=t.client_id order by t.completed_at nulls first,(t.priority='high') desc,t.due_at,t.id limit 100),
 activity as (select a.*,p.full_name actor_name,r.carrier,r.policy_type,r.policy_number from private.book_crm_activity a join policies r on r.id=a.client_id join public.profiles p on p.id=a.actor_id order by a.created_at desc,a.id limit 100)
 select jsonb_build_object(
  'profile',person.details||jsonb_build_object('id',person.id,'agent_id',person.agent_id,'updated_at',person.updated_at,'created_at',person.created_at),
  'can_manage_profile',private.book_crm_can_access(person.agent_id,null),
  'can_delete_profile',private.book_crm_can_access(person.agent_id,null) and not exists(select 1 from private.book_crm_clients c where c.profile_id=pid and not private.book_crm_can_access(c.agent_id,c.deal_id)),
  'client',(select to_jsonb(r) from policies r order by (r.id=p_id) desc,r.created_at,r.id limit 1),
  'policies',coalesce((select jsonb_agg(to_jsonb(r) order by r.created_at,r.id) from policies r),'[]'),
  'tasks',coalesce((select jsonb_agg(to_jsonb(t) order by t.completed_at nulls first,(t.priority='high') desc,t.due_at,t.id) from tasks t),'[]'),
  'activity',coalesce((select jsonb_agg(to_jsonb(a) order by a.created_at desc,a.id) from activity a),'[]')) into result;
 return result;
end;$function$

;

notify pgrst,'reload schema';
