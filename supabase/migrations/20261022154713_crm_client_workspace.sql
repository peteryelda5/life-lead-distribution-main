-- Extend the existing private book; retain PIN, agency scope and production accounting.
alter table private.book_crm_clients
 add column effective_date date,
 add column alternate_phone text not null default '',
 add column date_of_birth date,
 add column mortgage_balance numeric(14,2) check (mortgage_balance >= 0),
 add column pipeline_stage text check (pipeline_stage in ('new','contacted','submitted','approved','in_force','lapsed','cancelled'));

create table private.book_crm_tasks (
 id uuid primary key default gen_random_uuid(), client_id uuid not null references private.book_crm_clients(id) on delete cascade,
 title text not null check (length(trim(title)) between 1 and 300), due_at timestamptz not null,
 completed_at timestamptz, created_by uuid not null references public.profiles(id),
 created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create index book_crm_tasks_client_due on private.book_crm_tasks(client_id,due_at,id);
create index book_crm_tasks_creator on private.book_crm_tasks(created_by);
create table private.book_crm_activity (
 id uuid primary key default gen_random_uuid(), client_id uuid not null references private.book_crm_clients(id) on delete cascade,
 actor_id uuid not null references public.profiles(id), kind text not null check (kind in ('created','updated','stage','note','task_added','task_completed','task_reopened')),
 body text not null check (length(body)<=5000), created_at timestamptz not null default now()
);
create index book_crm_activity_client_time on private.book_crm_activity(client_id,created_at desc,id);
create index book_crm_activity_actor on private.book_crm_activity(actor_id);
alter table private.book_crm_tasks enable row level security;
alter table private.book_crm_activity enable row level security;
revoke all on private.book_crm_tasks,private.book_crm_activity from public,anon,authenticated;

-- Issued is not proof that coverage is in force; never invent historical effective dates.
create function private.book_crm_stage(p_stage text,p_status text) returns text
language sql immutable set search_path='' as $$
 select coalesce(p_stage,case p_status when 'active' then 'in_force' when 'issued' then 'approved' when 'submitted' then 'submitted' when 'lapsed' then 'lapsed' when 'cancelled' then 'cancelled' else 'new' end)
$$;
create function private.book_crm_stage_label(p_stage text) returns text
language sql immutable set search_path='' as $$
 select case p_stage when 'new' then 'New prospect' when 'contacted' then 'Contacted' when 'submitted' then 'Application submitted' when 'approved' then 'Approved' when 'in_force' then 'In force' when 'lapsed' then 'Lapsed' when 'cancelled' then 'Cancelled' end
$$;

-- This unexposed view has no client grants. All reads below enforce the existing book scope.
create view private.book_crm_records as
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
 t.id next_task_id,t.title next_task_title,t.due_at next_task_due
from private.book_crm_clients c join public.profiles p on p.id=c.agent_id
left join public.closed_business d on d.id=c.deal_id left join private.book_deal_comp x on x.deal_id=d.id
left join lateral(select g.* from private.book_comp_grid g where g.agent_id=c.agent_id and g.carrier=lower(trim(coalesce(d.carrier,c.carrier))) and g.policy_type=lower(trim(coalesce(d.policy_type,c.policy_type))) and g.effective_date<=coalesce(d.application_date,c.application_date) order by g.effective_date desc limit 1)g on true
left join lateral(select t.id,t.title,t.due_at from private.book_crm_tasks t where t.client_id=c.id and t.completed_at is null order by t.due_at,t.id limit 1)t on true;
revoke all on private.book_crm_records from public,anon,authenticated;

create function private.book_crm_workspace(p_page int default 1,p_search text default '',p_agent uuid default null,p_stage text default '',p_limit int default 50,p_view text default 'clients',p_task_status text default 'open') returns jsonb
language plpgsql stable security definer set search_path='' as $$
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
 tasks as materialized (select t.*,f.client_name,f.agent_name,f.pipeline_stage from private.book_crm_tasks t join filtered f on f.id=t.client_id where (p_task_status='open' and t.completed_at is null) or (p_task_status='completed' and t.completed_at is not null)),
 taskpage as (select * from tasks order by due_at,id limit lim offset offn)
 select jsonb_build_object(
 'rows',case when p_view='clients' then coalesce((select jsonb_agg(to_jsonb(paged) order by created_at desc,id) from paged),'[]') else '[]'::jsonb end,
 'pipeline',case when p_view='pipeline' then coalesce((select jsonb_agg(to_jsonb(ranked)-'rn' order by created_at desc,id) from ranked where rn<=25),'[]') else '[]'::jsonb end,
 'tasks',case when p_view='tasks' then coalesce((select jsonb_agg(to_jsonb(taskpage) order by due_at,id) from taskpage),'[]') else '[]'::jsonb end,
 'task_count',(select count(*) from tasks), 'count',(select count(*) from filtered),
 'stage_counts',coalesce((select jsonb_object_agg(pipeline_stage,n) from (select pipeline_stage,count(*) n from permitted group by pipeline_stage)s),'{}'),
 'monthly_payment',(select coalesce(sum(monthly_payment),0) from filtered where status in ('active','issued')),
 'estimated_advance',(select coalesce(sum(estimated_advance),0) from filtered where status in ('active','issued')),
 'followups_due',(select count(*) from private.book_crm_tasks t join permitted f on f.id=t.client_id where completed_at is null and due_at<=now())
 ) into result;
 return result;
end;$$;

create function private.book_crm_detail(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare r private.book_crm_records%rowtype;
begin
 if auth.uid() is null or not private.book_is_unlocked() then raise exception 'Book of Business is locked. Enter your PIN.' using errcode='42501';end if;
 select * into r from private.book_crm_records where id=p_id;
 if not found or not private.book_crm_can_access(r.agent_id,r.deal_id) then raise exception 'Client not available to your account' using errcode='42501';end if;
 return jsonb_build_object('client',to_jsonb(r),
 'tasks',coalesce((select jsonb_agg(to_jsonb(t) order by t.completed_at nulls first,t.due_at,t.id) from (select * from private.book_crm_tasks where client_id=p_id order by completed_at nulls first,due_at,id limit 100)t),'[]'),
 'activity',coalesce((select jsonb_agg(to_jsonb(a) order by a.created_at desc,a.id) from (select a.*,p.full_name actor_name from private.book_crm_activity a join public.profiles p on p.id=a.actor_id where a.client_id=p_id order by a.created_at desc,a.id limit 100)a),'[]'));
end;$$;

create function private.book_crm_save_v2(p_id uuid,p_fields jsonb,p_expected_updated_at timestamptz default null,p_expected_deal jsonb default null) returns jsonb
language plpgsql security definer set search_path='' as $$
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
 if stage<>all(array['new','contacted','submitted','approved','in_force','lapsed','cancelled']) then raise exception 'Choose a valid pipeline stage';end if;
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
end;$$;

create function private.book_crm_action(p_client uuid,p_action text,p_id uuid,p_title text default '',p_due_at timestamptz default null,p_body text default '',p_expected_updated_at timestamptz default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare c private.book_crm_clients%rowtype; t private.book_crm_tasks%rowtype;
begin
 if auth.uid() is null or not private.book_is_unlocked() then raise exception 'Book of Business is locked. Enter your PIN.' using errcode='42501';end if;
 select * into c from private.book_crm_clients where id=p_client;
 if not found or not private.book_crm_can_access(c.agent_id,c.deal_id) then raise exception 'Client not available to your account' using errcode='42501';end if;
 if p_id is null then raise exception 'Request ID required';end if;
 if p_action='note' then
 if coalesce(length(trim(p_body)),0) not between 1 and 5000 then raise exception 'Enter a note (up to 5000 characters)';end if;
 insert into private.book_crm_activity(id,client_id,actor_id,kind,body) values(p_id,p_client,auth.uid(),'note',trim(p_body)) on conflict(id) do nothing;
 elsif p_action='task' then
 if coalesce(length(trim(p_title)),0) not between 1 and 300 or p_due_at is null then raise exception 'Task title and due date are required';end if;
 insert into private.book_crm_tasks(id,client_id,title,due_at,created_by) values(p_id,p_client,trim(p_title),p_due_at,auth.uid()) on conflict(id) do nothing;
 if found then insert into private.book_crm_activity(client_id,actor_id,kind,body) values(p_client,auth.uid(),'task_added','Follow-up scheduled: '||trim(p_title));end if;
 elsif p_action in ('complete','reopen') then
 select * into t from private.book_crm_tasks where id=p_id and client_id=p_client for update;
 if not found then raise exception 'Task not found';end if;
 if t.updated_at is distinct from p_expected_updated_at then raise sqlstate 'PT409' using message='Task changed. Refresh and try again.';end if;
 update private.book_crm_tasks set completed_at=case when p_action='complete' then clock_timestamp() else null end,updated_at=clock_timestamp() where id=p_id;
 insert into private.book_crm_activity(client_id,actor_id,kind,body) values(p_client,auth.uid(),case when p_action='complete' then 'task_completed' else 'task_reopened' end,case when p_action='complete' then 'Completed: ' else 'Reopened: ' end||t.title);
 else raise exception 'Invalid client action';end if;
 return jsonb_build_object('ok',true);
end;$$;

create function public.book_crm_workspace(p_page int default 1,p_search text default '',p_agent uuid default null,p_stage text default '',p_limit int default 50,p_view text default 'clients',p_task_status text default 'open') returns jsonb language sql security invoker set search_path='' as $$select private.book_crm_workspace(p_page,p_search,p_agent,p_stage,p_limit,p_view,p_task_status)$$;
create function public.book_crm_detail(p_id uuid) returns jsonb language sql security invoker set search_path='' as $$select private.book_crm_detail(p_id)$$;
create function public.book_crm_save_v2(p_id uuid,p_fields jsonb,p_expected_updated_at timestamptz default null,p_expected_deal jsonb default null) returns jsonb language sql security invoker set search_path='' as $$select private.book_crm_save_v2(p_id,p_fields,p_expected_updated_at,p_expected_deal)$$;
create function public.book_crm_action(p_client uuid,p_action text,p_id uuid,p_title text default '',p_due_at timestamptz default null,p_body text default '',p_expected_updated_at timestamptz default null) returns jsonb language sql security invoker set search_path='' as $$select private.book_crm_action(p_client,p_action,p_id,p_title,p_due_at,p_body,p_expected_updated_at)$$;
revoke all on function private.book_crm_stage(text,text),private.book_crm_stage_label(text) from public,anon,authenticated;
revoke all on function private.book_crm_workspace(int,text,uuid,text,int,text,text),public.book_crm_workspace(int,text,uuid,text,int,text,text),private.book_crm_detail(uuid),public.book_crm_detail(uuid),private.book_crm_save_v2(uuid,jsonb,timestamptz,jsonb),public.book_crm_save_v2(uuid,jsonb,timestamptz,jsonb),private.book_crm_action(uuid,text,uuid,text,timestamptz,text,timestamptz),public.book_crm_action(uuid,text,uuid,text,timestamptz,text,timestamptz) from public,anon,authenticated;
grant execute on function private.book_crm_workspace(int,text,uuid,text,int,text,text),public.book_crm_workspace(int,text,uuid,text,int,text,text),private.book_crm_detail(uuid),public.book_crm_detail(uuid),private.book_crm_save_v2(uuid,jsonb,timestamptz,jsonb),public.book_crm_save_v2(uuid,jsonb,timestamptz,jsonb),private.book_crm_action(uuid,text,uuid,text,timestamptz,text,timestamptz),public.book_crm_action(uuid,text,uuid,text,timestamptz,text,timestamptz) to authenticated;
notify pgrst,'reload schema';
