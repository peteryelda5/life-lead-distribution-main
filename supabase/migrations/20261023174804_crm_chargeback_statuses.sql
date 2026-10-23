-- Add Chargeback independently to agent pipeline and carrier confirmation.
-- A status change does not reverse recorded production or commission snapshots.
alter table private.book_crm_clients drop constraint book_crm_clients_pipeline_stage_check;
alter table private.book_crm_clients add constraint book_crm_clients_pipeline_stage_check CHECK ((pipeline_stage = ANY (ARRAY['chargeback'::text, 'new'::text, 'contacted'::text, 'submitted'::text, 'approved'::text, 'in_force'::text, 'lapsed'::text, 'cancelled'::text])));

alter table private.book_crm_clients drop constraint book_crm_clients_status_check;
alter table private.book_crm_clients add constraint book_crm_clients_status_check CHECK ((status = ANY (ARRAY['chargeback'::text, 'draft'::text, 'submitted'::text, 'active'::text, 'issued'::text, 'lapsed'::text, 'cancelled'::text])));

alter table private.book_crm_carrier_status drop constraint book_crm_carrier_status_status_check;
alter table private.book_crm_carrier_status add constraint book_crm_carrier_status_status_check CHECK ((status = ANY (ARRAY['chargeback'::text, 'unverified'::text, 'pending'::text, 'underwriting'::text, 'approved'::text, 'issued'::text, 'in_force'::text, 'initial_premium_failed'::text, 'grace_period'::text, 'late_offer_period'::text, 'lapsed'::text, 'cancelled'::text, 'declined'::text])));

alter table private.book_crm_tasks drop constraint book_crm_tasks_carrier_status_check;
alter table private.book_crm_tasks add constraint book_crm_tasks_carrier_status_check CHECK ((carrier_status = ANY (ARRAY['chargeback'::text, 'initial_premium_failed'::text, 'grace_period'::text, 'late_offer_period'::text, 'lapsed'::text, 'cancelled'::text, 'declined'::text])));

CREATE OR REPLACE FUNCTION private.book_crm_stage(p_stage text, p_status text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
 select coalesce(p_stage,case p_status when 'active' then 'in_force' when 'issued' then 'approved' when 'submitted' then 'submitted' when 'lapsed' then 'lapsed' when 'cancelled' then 'cancelled' when 'chargeback' then 'chargeback' else 'new' end)
$function$;

CREATE OR REPLACE FUNCTION private.book_crm_stage_label(p_stage text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
 select case p_stage when 'new' then 'New prospect' when 'contacted' then 'Contacted' when 'submitted' then 'Application submitted' when 'approved' then 'Approved' when 'in_force' then 'In force' when 'lapsed' then 'Lapsed' when 'cancelled' then 'Cancelled' when 'chargeback' then 'Chargeback' end
$function$;

CREATE OR REPLACE FUNCTION private.book_crm_save(p_id uuid, p_fields jsonb, p_expected_updated_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_expected_deal jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare c private.book_crm_clients%rowtype; owner_id uuid; d public.closed_business%rowtype; price numeric; app_date date; policy_status text; before_row jsonb;
begin
 if not private.book_is_unlocked() then raise exception 'Book of Business is locked. Enter your PIN.' using errcode='42501';end if;
 if p_id is null or p_fields is null or jsonb_typeof(p_fields)<>'object' or exists(select 1 from jsonb_object_keys(p_fields) k where k<>all(array['agent_id','client_name','address_line1','address_line2','city','state','zip','phone','email','carrier','policy_type','monthly_payment','policy_number','application_date','status','notes'])) then raise exception 'Invalid client fields';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,49412));
 select * into c from private.book_crm_clients where id=p_id for update;
 if found then
 if not private.book_crm_can_access(c.agent_id,c.deal_id) then raise exception 'Client not available to your account' using errcode='42501';end if;
 if c.updated_at is distinct from p_expected_updated_at then raise sqlstate 'PT409' using message='Client changed. Reopen the client and try again.';end if;
 owner_id:=c.agent_id;before_row:=to_jsonb(c);
 else
 if p_expected_updated_at is not null then raise exception 'Client no longer available';end if;
 owner_id:=coalesce(nullif(p_fields->>'agent_id','')::uuid,auth.uid());
 if not private.book_crm_can_access(owner_id) or not exists(select 1 from public.profiles where id=owner_id and active and not coalesce(archived,false) and role in ('admin','agent')) then raise exception 'Choose an authorized active agent' using errcode='42501';end if;
 end if;
 if coalesce(length(trim(p_fields->>'client_name')),0) not between 1 and 200 then raise exception 'Client name is required (up to 200 characters)';end if;
 if exists(select 1 from jsonb_each_text(p_fields)kv where kv.key in ('address_line1','address_line2','city','carrier','policy_type','policy_number') and length(kv.value)>200) or coalesce(length(p_fields->>'phone'),0)>50 or coalesce(length(p_fields->>'email'),0)>254 or coalesce(length(p_fields->>'notes'),0)>5000 or coalesce(length(p_fields->>'state'),0)>50 or coalesce(length(p_fields->>'zip'),0)>20 then raise exception 'One or more client fields are too long';end if;
 price:=coalesce(nullif(p_fields->>'monthly_payment','')::numeric,0);app_date:=coalesce(nullif(p_fields->>'application_date','')::date,current_date);policy_status:=coalesce(p_fields->>'status','draft');
 if price<0 or price>100000 or policy_status<>all(array['draft','submitted','active','issued','lapsed','cancelled','chargeback']) then raise exception 'Valid monthly payment and policy status required';end if;
 if policy_status in ('active','issued') and (price<=0 or coalesce(length(trim(p_fields->>'carrier')),0)=0 or coalesce(length(trim(p_fields->>'policy_type')),0)=0) then raise exception 'Active / Issued needs carrier, policy type and a positive monthly payment';end if;
 if c.deal_id is not null then
 select * into d from public.closed_business where id=c.deal_id for update;
 if p_expected_deal is distinct from jsonb_build_object('carrier',d.carrier,'policy_type',d.policy_type,'monthly_premium',d.monthly_premium,'application_date',d.application_date,'policy_number',d.policy_number,'notes',d.notes) then raise sqlstate 'PT409' using message='Linked deal changed. Reopen the client and try again.';end if;
 -- A recorded deal still needs complete policy details, even if policy status later changes.
 if price<=0 or coalesce(length(trim(p_fields->>'carrier')),0)=0 or coalesce(length(trim(p_fields->>'policy_type')),0)=0 then raise exception 'Recorded policy needs carrier, policy type and monthly payment';end if;
 end if;
 insert into private.book_crm_clients(id,agent_id,client_name,address_line1,address_line2,city,state,zip,phone,email,carrier,policy_type,monthly_payment,policy_number,application_date,status,notes)
 values(p_id,owner_id,trim(p_fields->>'client_name'),coalesce(p_fields->>'address_line1',''),coalesce(p_fields->>'address_line2',''),coalesce(p_fields->>'city',''),coalesce(p_fields->>'state',''),coalesce(p_fields->>'zip',''),coalesce(p_fields->>'phone',''),coalesce(p_fields->>'email',''),trim(coalesce(p_fields->>'carrier','')),trim(coalesce(p_fields->>'policy_type','')),price,coalesce(p_fields->>'policy_number',''),app_date,policy_status,coalesce(p_fields->>'notes',''))
 on conflict(id) do update set client_name=excluded.client_name,address_line1=excluded.address_line1,address_line2=excluded.address_line2,city=excluded.city,state=excluded.state,zip=excluded.zip,phone=excluded.phone,email=excluded.email,carrier=excluded.carrier,policy_type=excluded.policy_type,monthly_payment=excluded.monthly_payment,policy_number=excluded.policy_number,application_date=excluded.application_date,status=excluded.status,notes=excluded.notes,updated_at=now();
 if c.deal_id is not null then
 update public.closed_business set carrier=trim(p_fields->>'carrier'),policy_type=trim(p_fields->>'policy_type'),monthly_premium=price,application_date=app_date,policy_number=nullif(trim(p_fields->>'policy_number'),''),notes=nullif(trim(p_fields->>'notes'),'') where id=c.deal_id;
 elsif policy_status in ('active','issued') and not coalesce(c.production_recorded,false) then
 perform set_config('lld.crm_client_id',p_id::text,true);
 insert into public.closed_business(agent_id,carrier,policy_type,monthly_premium,application_date,policy_number,notes) values(owner_id,trim(p_fields->>'carrier'),trim(p_fields->>'policy_type'),price,app_date,nullif(trim(p_fields->>'policy_number'),''),nullif(trim(p_fields->>'notes'),''));
 perform set_config('lld.crm_client_id','',true);
 end if;
 select * into c from private.book_crm_clients where id=p_id;
 if c.deal_id is not null then
 insert into private.book_clients(deal_id,client_name,phone,email,updated_by) values(c.deal_id,c.client_name,nullif(c.phone,''),nullif(c.email,''),auth.uid()) on conflict(deal_id) do update set client_name=excluded.client_name,phone=excluded.phone,email=excluded.email,updated_by=auth.uid();
 end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'crm_client_saved','crm_client',p_id::text,jsonb_build_object('before',before_row,'after',to_jsonb(c)));
 return jsonb_build_object('ok',true,'id',p_id,'deal_id',c.deal_id);
end;$function$;

CREATE OR REPLACE FUNCTION private.book_crm_save_v2(p_id uuid, p_fields jsonb, p_expected_updated_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_expected_deal jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare c private.book_crm_clients%rowtype; merged jsonb; core jsonb; result jsonb; stage text; old_stage text; eff date; dob date; bal numeric; policy_status text; is_new boolean;
begin
 if auth.uid() is null or not private.book_is_unlocked() then raise exception 'Book of Business is locked. Enter your PIN.' using errcode='42501';end if;
 if p_id is null or p_fields is null or jsonb_typeof(p_fields)<>'object' or exists(select 1 from jsonb_object_keys(p_fields) k where k<>all(array['agent_id','client_name','address_line1','address_line2','city','state','zip','phone','email','carrier','policy_type','monthly_payment','policy_number','application_date','notes','effective_date','alternate_phone','date_of_birth','mortgage_balance','pipeline_stage'])) then raise exception 'Invalid client fields';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,49412));
 select * into c from private.book_crm_clients where id=p_id for update;
 is_new:=not found;
 if not is_new then
 if not private.book_crm_can_access(c.agent_id,c.deal_id) then raise exception 'Client not available to your account' using errcode='42501';end if;
 if c.updated_at is distinct from p_expected_updated_at then raise sqlstate 'PT409' using message='Client changed. Reopen the client and try again.';end if;
 if p_fields ? 'agent_id' and p_fields->>'agent_id' is distinct from c.agent_id::text then raise exception 'Client owner cannot be changed here';end if;
 end if;
 -- Use current linked policy values when a quick stage change only sends pipeline_stage.
 select coalesce(to_jsonb(r),'{}') into merged from private.book_crm_records r where r.id=p_id;
 merged:=coalesce(merged,'{}')||p_fields;
 old_stage:=case when is_new then null else private.book_crm_stage(c.pipeline_stage,c.status) end;
 stage:=coalesce(merged->>'pipeline_stage','new');
 if stage<>all(array['new','contacted','submitted','approved','in_force','lapsed','cancelled','chargeback']) then raise exception 'Choose a valid pipeline stage';end if;
 eff:=nullif(merged->>'effective_date','')::date;dob:=nullif(merged->>'date_of_birth','')::date;bal:=nullif(merged->>'mortgage_balance','')::numeric;
 if (stage='in_force' or (is_new and stage in ('submitted','approved'))) and eff is null then raise exception 'Enter the policy effective date';end if;
 if stage='in_force' and eff>current_date then raise exception 'Coverage starts in the future. Keep this policy Approved until its effective date.';end if;
 if dob>current_date or dob<date '1900-01-01' then raise exception 'Enter a valid date of birth';end if;
 if bal<0 or bal>999999999999.99 or coalesce(length(merged->>'alternate_phone'),0)>50 then raise exception 'Invalid additional client information';end if;
 if is_new and (coalesce(length(trim(merged->>'phone')),0)=0 or coalesce(length(trim(merged->>'carrier')),0)=0 or coalesce(length(trim(merged->>'policy_type')),0)=0 or coalesce(nullif(merged->>'monthly_payment','')::numeric,0)<=0) then raise exception 'Client phone, carrier, policy type and a positive monthly premium are required';end if;
 policy_status:=case stage when 'new' then 'draft' when 'contacted' then 'draft' when 'submitted' then 'submitted' when 'approved' then case when c.status='issued' then 'issued' else 'submitted' end when 'in_force' then 'active' else stage end;
 select coalesce(jsonb_object_agg(key,value),'{}') into core from jsonb_each(merged) where key=any(array['agent_id','client_name','address_line1','address_line2','city','state','zip','phone','email','carrier','policy_type','monthly_payment','policy_number','application_date','notes']);
 result:=private.book_crm_save(p_id,core||jsonb_build_object('status',policy_status),p_expected_updated_at,p_expected_deal);
 update private.book_crm_clients set pipeline_stage=stage,effective_date=eff,alternate_phone=coalesce(merged->>'alternate_phone',''),date_of_birth=dob,mortgage_balance=bal,updated_at=clock_timestamp() where id=p_id;
 insert into private.book_crm_activity(client_id,actor_id,kind,body) values(p_id,auth.uid(),case when is_new then 'created' when old_stage is distinct from stage then 'stage' else 'updated' end,
 case when is_new then 'Client added to '||private.book_crm_stage_label(stage) when old_stage is distinct from stage then private.book_crm_stage_label(old_stage)||' → '||private.book_crm_stage_label(stage) else 'Client details updated' end);
 return result;
end;$function$;

CREATE OR REPLACE FUNCTION private.book_crm_workspace(p_page integer DEFAULT 1, p_search text DEFAULT ''::text, p_agent uuid DEFAULT NULL::uuid, p_stage text DEFAULT ''::text, p_limit integer DEFAULT 50, p_view text DEFAULT 'clients'::text, p_task_status text DEFAULT 'open'::text)
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
end;$function$;

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
 if coalesce(p_stage,'')<>'' and p_stage<>all(array['new','contacted','submitted','approved','in_force','lapsed','cancelled','chargeback']) then raise exception 'Invalid pipeline stage';end if;
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
end;$function$;

CREATE OR REPLACE FUNCTION private.book_crm_profiles_list(p_page integer DEFAULT 1, p_search text DEFAULT ''::text, p_agent uuid DEFAULT NULL::uuid, p_stage text DEFAULT ''::text, p_limit integer DEFAULT 50)
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
end;$function$;

CREATE OR REPLACE FUNCTION private.book_crm_carrier_status_save(p_policy uuid, p_status text, p_source text, p_confirmed_on date, p_reference text, p_notes text, p_expected_updated_at timestamp with time zone, p_expected_deal jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare c private.book_crm_clients%rowtype; r jsonb; prior jsonb; saved jsonb; stamp timestamptz:=clock_timestamp();
begin
 if auth.uid() is null or not private.book_is_unlocked() then raise exception 'Book of Business is locked. Enter your PIN.' using errcode='42501';end if;
 if p_policy is null or p_status is null or p_status<>all(array['unverified','pending','underwriting','approved','issued','in_force','initial_premium_failed','grace_period','late_offer_period','lapsed','cancelled','declined','chargeback']) then raise exception 'Choose a valid carrier status';end if;
 if coalesce(length(trim(p_reference)),0) not between 1 and 500 or coalesce(length(p_notes),0)>2000 then raise exception 'Enter a carrier reference or reset reason (up to 500 characters); notes allow 2000 characters';end if;
 if p_status<>'unverified' and (p_source is null or p_source<>all(array['carrier_portal','carrier_email','carrier_statement','carrier_phone']) or p_confirmed_on is null or p_confirmed_on>current_date or p_confirmed_on<date '1900-01-01') then raise exception 'Choose a carrier source and a confirmation date that is not in the future';end if;
 if p_status='unverified' then p_source:=null;p_confirmed_on:=null;end if;
 perform pg_advisory_xact_lock(hashtextextended(p_policy::text,49412));
 select * into c from private.book_crm_clients where id=p_policy for update;
 if not found or not private.book_crm_can_access(c.agent_id,c.deal_id) then raise exception 'Policy not available to your account' using errcode='42501';end if;
 if c.updated_at is distinct from p_expected_updated_at then raise sqlstate 'PT409' using message='Policy changed. Reopen the policy before recording carrier status.';end if;
 select to_jsonb(v) into r from private.book_crm_records v where v.id=p_policy;
 if nullif(r->'deal_version','null'::jsonb) is distinct from nullif(p_expected_deal,'null'::jsonb) then raise sqlstate 'PT409' using message='Linked deal changed. Reopen the policy before recording carrier status.';end if;
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
end;$function$;

CREATE OR REPLACE FUNCTION private.book_crm_sync_carrier_task(p_policy uuid, p_status text, p_actor uuid, p_reopen boolean DEFAULT false)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t private.book_crm_tasks%rowtype; label text; stamp timestamptz:=clock_timestamp(); event text;
begin
 select * into t from private.book_crm_tasks where client_id=p_policy and source='carrier_status' for update;
 if p_status=any(array['initial_premium_failed','grace_period','late_offer_period','lapsed','cancelled','declined','chargeback']) then
  label:=case p_status when 'initial_premium_failed' then 'Initial premium failed' when 'grace_period' then 'Grace period'
   when 'late_offer_period' then 'Late offer period' when 'lapsed' then 'Lapsed' when 'cancelled' then 'Cancelled' when 'declined' then 'Declined' when 'chargeback' then 'Chargeback' end;
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
end;$function$;

notify pgrst,'reload schema';
