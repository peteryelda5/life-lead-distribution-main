-- Agency is the closing agent's current home agency. Apply it inside the permitted
-- record set so counts, pagination, follow-ups and exports share one scope.
CREATE OR REPLACE FUNCTION private.book_crm_workspace_agency(p_agency text, p_page integer DEFAULT 1, p_search text DEFAULT ''::text, p_agent uuid DEFAULT NULL::uuid, p_stage text DEFAULT ''::text, p_limit integer DEFAULT 50, p_view text DEFAULT 'clients'::text, p_task_status text DEFAULT 'open'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare result jsonb; lim int:=greatest(1,least(coalesce(p_limit,50),2000)); offn int;
begin
 if auth.uid() is null or not private.book_is_unlocked() then raise exception 'Book of Business is locked. Enter your PIN.' using errcode='42501'; end if;
 if coalesce(p_stage,'')<>'' and p_stage<>all(array['new','contacted','submitted','approved','in_force','lapsed','cancelled','chargeback']) then raise exception 'Invalid pipeline stage'; end if;
 if p_view<>all(array['clients','pipeline','tasks']) or p_task_status<>all(array['open','completed']) then raise exception 'Invalid view';end if;
 offn:=(greatest(1,least(coalesce(p_page,1),100000))-1)*lim;
 with permitted as materialized (
 select r.*, d.name as agent_agency_name
  from private.book_crm_records r
  left join public.profiles owner_profile on owner_profile.id=r.agent_id
  left join public.divisions d on d.id=owner_profile.division
  where (p_agency is null or owner_profile.division=p_agency) and private.book_crm_can_access(r.agent_id,r.deal_id) and (p_agent is null or r.agent_id=p_agent)
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
end;$function$;

CREATE OR REPLACE FUNCTION private.book_crm_workspace(p_page integer DEFAULT 1, p_search text DEFAULT ''::text, p_agent uuid DEFAULT NULL::uuid, p_stage text DEFAULT ''::text, p_limit integer DEFAULT 50, p_view text DEFAULT 'clients'::text, p_task_status text DEFAULT 'open'::text)
 RETURNS jsonb
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$select private.book_crm_workspace_agency(null::text,p_page,p_search,p_agent,p_stage,p_limit,p_view,p_task_status)$function$;

CREATE OR REPLACE FUNCTION public.book_crm_workspace_agency(p_agency text, p_page integer DEFAULT 1, p_search text DEFAULT ''::text, p_agent uuid DEFAULT NULL::uuid, p_stage text DEFAULT ''::text, p_limit integer DEFAULT 50, p_view text DEFAULT 'clients'::text, p_task_status text DEFAULT 'open'::text)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO ''
AS $function$select private.book_crm_workspace_agency(p_agency,p_page,p_search,p_agent,p_stage,p_limit,p_view,p_task_status)$function$;
REVOKE ALL ON FUNCTION private.book_crm_workspace_agency(text,integer,text,uuid,text,integer,text,text), public.book_crm_workspace_agency(text,integer,text,uuid,text,integer,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.book_crm_workspace_agency(text,integer,text,uuid,text,integer,text,text), public.book_crm_workspace_agency(text,integer,text,uuid,text,integer,text,text) TO authenticated;

CREATE OR REPLACE FUNCTION private.book_crm_pipeline_agency(p_agency text, p_search text DEFAULT ''::text, p_agent uuid DEFAULT NULL::uuid, p_carrier text DEFAULT ''::text, p_stage text DEFAULT ''::text, p_page integer DEFAULT 1, p_limit integer DEFAULT 50, p_view text DEFAULT 'board'::text, p_today_start timestamp with time zone DEFAULT NULL::timestamp with time zone, p_today_end timestamp with time zone DEFAULT NULL::timestamp with time zone)
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
 if coalesce(p_stage,'')<>'' and p_stage<>all(array['new','contacted','submitted','approved','in_force','lapsed','cancelled','chargeback']) then raise exception 'Invalid pipeline stage';end if;
 if day_end<=day_start or day_end-day_start>interval '48 hours' then raise exception 'Invalid follow-up day';end if;
 offn:=(greatest(1,least(coalesce(p_page,1),100000))-1)*lim;
 with permitted as materialized (
  select r.*, d.name as agent_agency_name
  from private.book_crm_records r
  left join public.profiles owner_profile on owner_profile.id=r.agent_id
  left join public.divisions d on d.id=owner_profile.division
  where (p_agency is null or owner_profile.division=p_agency) and private.book_crm_can_access(r.agent_id,r.deal_id) and (p_agent is null or r.agent_id=p_agent)
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
end;$function$;

CREATE OR REPLACE FUNCTION private.book_crm_pipeline(p_search text DEFAULT ''::text, p_agent uuid DEFAULT NULL::uuid, p_carrier text DEFAULT ''::text, p_stage text DEFAULT ''::text, p_page integer DEFAULT 1, p_limit integer DEFAULT 50, p_view text DEFAULT 'board'::text, p_today_start timestamp with time zone DEFAULT NULL::timestamp with time zone, p_today_end timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$select private.book_crm_pipeline_agency(null::text,p_search,p_agent,p_carrier,p_stage,p_page,p_limit,p_view,p_today_start,p_today_end)$function$;

CREATE OR REPLACE FUNCTION public.book_crm_pipeline_agency(p_agency text, p_search text DEFAULT ''::text, p_agent uuid DEFAULT NULL::uuid, p_carrier text DEFAULT ''::text, p_stage text DEFAULT ''::text, p_page integer DEFAULT 1, p_limit integer DEFAULT 50, p_view text DEFAULT 'board'::text, p_today_start timestamp with time zone DEFAULT NULL::timestamp with time zone, p_today_end timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO ''
AS $function$
 select private.book_crm_pipeline_agency(p_agency,p_search,p_agent,p_carrier,p_stage,p_page,p_limit,p_view,p_today_start,p_today_end)
$function$;
REVOKE ALL ON FUNCTION private.book_crm_pipeline_agency(text,text,uuid,text,text,integer,integer,text,timestamp with time zone,timestamp with time zone), public.book_crm_pipeline_agency(text,text,uuid,text,text,integer,integer,text,timestamp with time zone,timestamp with time zone) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.book_crm_pipeline_agency(text,text,uuid,text,text,integer,integer,text,timestamp with time zone,timestamp with time zone), public.book_crm_pipeline_agency(text,text,uuid,text,text,integer,integer,text,timestamp with time zone,timestamp with time zone) TO authenticated;

CREATE OR REPLACE FUNCTION private.book_crm_profiles_list_agency(p_agency text, p_page integer DEFAULT 1, p_search text DEFAULT ''::text, p_agent uuid DEFAULT NULL::uuid, p_stage text DEFAULT ''::text, p_limit integer DEFAULT 50)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare result jsonb; lim int:=greatest(1,least(coalesce(p_limit,50),2000)); offn int;
begin
 if auth.uid() is null or not private.book_is_unlocked() then raise exception 'Book of Business is locked. Enter your PIN.' using errcode='42501';end if;
 if coalesce(p_stage,'')<>'' and p_stage<>all(array['new','contacted','submitted','approved','in_force','lapsed','cancelled','chargeback']) then raise exception 'Invalid pipeline stage';end if;
 offn:=(greatest(1,least(coalesce(p_page,1),100000))-1)*lim;
 with permitted as materialized (
  select r.*, d.name as agent_agency_name
  from private.book_crm_records r
  left join public.profiles owner_profile on owner_profile.id=r.agent_id
  left join public.divisions d on d.id=owner_profile.division
  where (p_agency is null or owner_profile.division=p_agency) and private.book_crm_can_access(r.agent_id,r.deal_id) and (p_agent is null or r.agent_id=p_agent)
 ), searched as materialized (
  select * from permitted r where coalesce(p_search,'')='' or concat_ws(' ',r.client_name,r.agent_name,r.carrier,r.policy_type,r.policy_number,r.phone,r.email,r.address_line1,r.city,r.state,r.zip) ilike '%'||left(p_search,100)||'%'
 ), matched as materialized (select * from searched where coalesce(p_stage,'')='' or pipeline_stage=p_stage),
 people as materialized (select p.* from private.book_crm_profiles p where exists(select 1 from matched m where m.profile_id=p.id)),
 paged as (select p.*,a.full_name agent_name from people p join public.profiles a on a.id=p.agent_id order by p.created_at desc,p.id limit lim offset offn),
 rows as (select p.details||jsonb_build_object('id',p.id,'agent_id',p.agent_id,'agent_name',p.agent_name,'agent_agency_name',max(r.agent_agency_name),'created_at',p.created_at,'updated_at',p.updated_at,
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
end;$function$;

CREATE OR REPLACE FUNCTION private.book_crm_profiles_list(p_page integer DEFAULT 1, p_search text DEFAULT ''::text, p_agent uuid DEFAULT NULL::uuid, p_stage text DEFAULT ''::text, p_limit integer DEFAULT 50)
 RETURNS jsonb
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$select private.book_crm_profiles_list_agency(null::text,p_page,p_search,p_agent,p_stage,p_limit)$function$;

CREATE OR REPLACE FUNCTION public.book_crm_profiles_list_agency(p_agency text, p_page integer DEFAULT 1, p_search text DEFAULT ''::text, p_agent uuid DEFAULT NULL::uuid, p_stage text DEFAULT ''::text, p_limit integer DEFAULT 50)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO ''
AS $function$select private.book_crm_profiles_list_agency(p_agency,p_page,p_search,p_agent,p_stage,p_limit)$function$;
REVOKE ALL ON FUNCTION private.book_crm_profiles_list_agency(text,integer,text,uuid,text,integer), public.book_crm_profiles_list_agency(text,integer,text,uuid,text,integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.book_crm_profiles_list_agency(text,integer,text,uuid,text,integer), public.book_crm_profiles_list_agency(text,integer,text,uuid,text,integer) TO authenticated;
NOTIFY pgrst, 'reload schema';
