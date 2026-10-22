-- Existing CRM rows retain their IDs, policy data, tasks, deal links and commission snapshots.
-- A private shared profile groups policies; no name/phone-based automatic merging.
create function private.book_crm_contact_fields(p_row jsonb) returns jsonb
language sql immutable set search_path='' as $$
 select coalesce(jsonb_object_agg(key,value),'{}'::jsonb) from jsonb_each(p_row) where key=any(array['client_name','address_line1','address_line2','city','state','zip','phone','email','alternate_phone','date_of_birth','mortgage_balance'])
$$;
create table private.book_crm_profiles (
 id uuid primary key, agent_id uuid not null references public.profiles(id), details jsonb not null check(jsonb_typeof(details)='object'),
 created_at timestamptz not null default now(),updated_at timestamptz not null default now(),unique(id,agent_id)
);
create index book_crm_profiles_agent_created on private.book_crm_profiles(agent_id,created_at desc,id);
alter table private.book_crm_profiles enable row level security;
revoke all on private.book_crm_profiles from public,anon,authenticated;
alter table private.book_crm_clients add column profile_id uuid;
insert into private.book_crm_profiles(id,agent_id,details,created_at,updated_at)
 select id,agent_id,private.book_crm_contact_fields(to_jsonb(c)),created_at,updated_at from private.book_crm_clients c;
update private.book_crm_clients set profile_id=id;
alter table private.book_crm_clients alter column profile_id set not null;
alter table private.book_crm_clients add constraint book_crm_policy_profile foreign key(profile_id,agent_id) references private.book_crm_profiles(id,agent_id);
create index book_crm_clients_profile on private.book_crm_clients(profile_id,created_at,id);

-- Old application tabs and the closed-business insert trigger remain compatible.
create function private.book_crm_attach_profile() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if tg_op='UPDATE' then
  if new.profile_id is distinct from old.profile_id or new.agent_id is distinct from old.agent_id then raise exception 'Policy owner and client cannot be changed here';end if;
  return new;
 end if;
 if new.profile_id is null then
  select profile_id into new.profile_id from private.book_crm_clients where id=new.id;
  if new.profile_id is null then
   new.profile_id:=new.id;
   insert into private.book_crm_profiles(id,agent_id,details,created_at,updated_at)
    values(new.id,new.agent_id,private.book_crm_contact_fields(to_jsonb(new)),new.created_at,new.updated_at);
  end if;
 end if;
 return new;
end;$$;
create trigger book_crm_attach_profile before insert or update of profile_id,agent_id on private.book_crm_clients for each row execute function private.book_crm_attach_profile();

-- Keep the legacy contact columns in sync while preserving each policy's own fields.
create function private.book_crm_sync_contact() returns trigger
language plpgsql security definer set search_path='' as $$
declare info jsonb:=private.book_crm_contact_fields(to_jsonb(new)); prior jsonb; shared private.book_crm_clients%rowtype;
begin
 select details into prior from private.book_crm_profiles where id=new.profile_id;
 if info is not distinct from prior then return new;end if;
 if exists(select 1 from private.book_crm_clients c where c.profile_id=new.profile_id and c.id<>new.id and not private.book_crm_can_access(c.agent_id,c.deal_id)) then
  raise exception 'Refresh the portal and use an authorized account to edit this shared client' using errcode='42501';
 end if;
 update private.book_crm_profiles set details=info,updated_at=clock_timestamp() where id=new.profile_id;
 shared:=new;
 update private.book_crm_clients set client_name=shared.client_name,address_line1=shared.address_line1,address_line2=shared.address_line2,city=shared.city,state=shared.state,zip=shared.zip,phone=shared.phone,email=shared.email,alternate_phone=shared.alternate_phone,date_of_birth=shared.date_of_birth,mortgage_balance=shared.mortgage_balance,updated_at=clock_timestamp() where profile_id=new.profile_id and id<>new.id;
 insert into private.book_clients(deal_id,client_name,phone,email,updated_by)
  select deal_id,new.client_name,nullif(new.phone,''),nullif(new.email,''),auth.uid() from private.book_crm_clients where profile_id=new.profile_id and deal_id is not null
  on conflict(deal_id) do update set client_name=excluded.client_name,phone=excluded.phone,email=excluded.email,updated_by=excluded.updated_by;
 return new;
end;$$;
create trigger book_crm_sync_contact after insert or update of client_name,address_line1,address_line2,city,state,zip,phone,email,alternate_phone,date_of_birth,mortgage_balance on private.book_crm_clients for each row execute function private.book_crm_sync_contact();
revoke all on function private.book_crm_contact_fields(jsonb),private.book_crm_attach_profile(),private.book_crm_sync_contact() from public,anon,authenticated;

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
 t.id next_task_id,t.title next_task_title,t.due_at next_task_due,c.profile_id
from private.book_crm_clients c join public.profiles p on p.id=c.agent_id
left join public.closed_business d on d.id=c.deal_id left join private.book_deal_comp x on x.deal_id=d.id
left join lateral(select g.* from private.book_comp_grid g where g.agent_id=c.agent_id and g.carrier=lower(trim(coalesce(d.carrier,c.carrier))) and g.policy_type=lower(trim(coalesce(d.policy_type,c.policy_type))) and g.effective_date<=coalesce(d.application_date,c.application_date) order by g.effective_date desc limit 1)g on true
left join lateral(select t.id,t.title,t.due_at from private.book_crm_tasks t where t.client_id=c.id and t.completed_at is null order by t.due_at,t.id limit 1)t on true;
revoke all on private.book_crm_records from public,anon,authenticated;

create function private.book_crm_profiles_list(p_page int default 1,p_search text default '',p_agent uuid default null,p_stage text default '',p_limit int default 50) returns jsonb
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
  'policy_count',count(r.id),'policies',jsonb_agg(jsonb_build_object('id',r.id,'carrier',r.carrier,'policy_type',r.policy_type,'policy_number',r.policy_number,'monthly_payment',r.monthly_payment,'effective_date',r.effective_date,'pipeline_stage',r.pipeline_stage,'status',r.status,'estimated_advance',r.estimated_advance) order by r.created_at,r.id),
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

create function private.book_crm_profile_detail(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare pid uuid; person private.book_crm_profiles%rowtype; result jsonb;
begin
 if auth.uid() is null or not private.book_is_unlocked() then raise exception 'Book of Business is locked. Enter your PIN.' using errcode='42501';end if;
 select profile_id into pid from private.book_crm_clients where id=p_id;
 pid:=coalesce(pid,p_id);
 select * into person from private.book_crm_profiles where id=pid;
 if not found or not exists(select 1 from private.book_crm_clients c where c.profile_id=pid and private.book_crm_can_access(c.agent_id,c.deal_id)) then raise exception 'Client not available to your account' using errcode='42501';end if;
 with policies as materialized (select r.* from private.book_crm_records r where r.profile_id=pid and private.book_crm_can_access(r.agent_id,r.deal_id)),
 tasks as (select t.*,r.carrier,r.policy_type,r.policy_number from private.book_crm_tasks t join policies r on r.id=t.client_id order by t.completed_at nulls first,t.due_at,t.id limit 100),
 activity as (select a.*,p.full_name actor_name,r.carrier,r.policy_type,r.policy_number from private.book_crm_activity a join policies r on r.id=a.client_id join public.profiles p on p.id=a.actor_id order by a.created_at desc,a.id limit 100)
 select jsonb_build_object(
  'profile',person.details||jsonb_build_object('id',person.id,'agent_id',person.agent_id,'updated_at',person.updated_at,'created_at',person.created_at),
  'can_manage_profile',private.book_crm_can_access(person.agent_id,null),
  'client',(select to_jsonb(r) from policies r order by (r.id=p_id) desc,r.created_at,r.id limit 1),
  'policies',coalesce((select jsonb_agg(to_jsonb(r) order by r.created_at,r.id) from policies r),'[]'),
  'tasks',coalesce((select jsonb_agg(to_jsonb(t) order by t.completed_at nulls first,t.due_at,t.id) from tasks t),'[]'),
  'activity',coalesce((select jsonb_agg(to_jsonb(a) order by a.created_at desc,a.id) from activity a),'[]')) into result;
 return result;
end;$$;

create function private.book_crm_policy_save(p_client uuid,p_policy uuid,p_fields jsonb,p_expected_updated_at timestamptz default null,p_expected_deal jsonb default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare person private.book_crm_profiles%rowtype; c private.book_crm_clients%rowtype; shared private.book_crm_clients%rowtype; result jsonb; is_new boolean; current_policy jsonb;
begin
 if auth.uid() is null or not private.book_is_unlocked() then raise exception 'Book of Business is locked. Enter your PIN.' using errcode='42501';end if;
 if p_client is null or p_policy is null or p_fields is null or jsonb_typeof(p_fields)<>'object' or exists(select 1 from jsonb_object_keys(p_fields) k where k<>all(array['carrier','policy_type','monthly_payment','policy_number','application_date','effective_date','pipeline_stage','notes'])) then raise exception 'Invalid policy fields';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_client::text,49413));
 select * into person from private.book_crm_profiles where id=p_client;
 if not found then raise exception 'Client not available to your account' using errcode='42501';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_policy::text,49412));
 select * into c from private.book_crm_clients where id=p_policy for update;
 is_new:=not found;
 if not is_new then
  if c.profile_id<>p_client or not private.book_crm_can_access(c.agent_id,c.deal_id) then raise exception 'Policy not available to your account' using errcode='42501';end if;
  -- Retrying a successful create with the same ID does not create or overwrite a policy.
  if p_expected_updated_at is null then
   select to_jsonb(r) into current_policy from private.book_crm_records r where r.id=p_policy;
   if not exists(select 1 from jsonb_each(p_fields) f where current_policy->f.key is distinct from case when f.value='""'::jsonb and f.key='effective_date' then 'null'::jsonb else f.value end) then
    return jsonb_build_object('ok',true,'id',p_policy,'profile_id',p_client,'deal_id',c.deal_id);
   end if;
   raise sqlstate 'PT409' using message='Policy already exists or changed. Refresh the client before editing.';
  end if;
 else
  if p_expected_updated_at is not null then raise exception 'Policy no longer available';end if;
  if not private.book_crm_can_access(person.agent_id,null) or not exists(select 1 from public.profiles where id=person.agent_id and active and not coalesce(archived,false) and role in ('admin','agent')) then raise exception 'Choose an authorized active agent' using errcode='42501';end if;
  if coalesce(length(trim(p_fields->>'carrier')),0)=0 or coalesce(length(trim(p_fields->>'policy_type')),0)=0 or coalesce(nullif(p_fields->>'monthly_payment','')::numeric,0)<=0 or nullif(p_fields->>'application_date','') is null then raise exception 'Carrier, policy type, monthly premium and application date are required';end if;
  if coalesce(p_fields->>'pipeline_stage','submitted') in ('submitted','approved','in_force') and nullif(p_fields->>'effective_date','') is null then raise exception 'Enter the policy effective date';end if;
  shared:=jsonb_populate_record(null::private.book_crm_clients,person.details);
  insert into private.book_crm_clients(id,profile_id,agent_id,client_name,address_line1,address_line2,city,state,zip,phone,email,alternate_phone,date_of_birth,mortgage_balance,pipeline_stage)
   values(p_policy,p_client,person.agent_id,shared.client_name,shared.address_line1,shared.address_line2,shared.city,shared.state,shared.zip,shared.phone,shared.email,shared.alternate_phone,shared.date_of_birth,shared.mortgage_balance,'new') returning * into c;
  p_expected_updated_at:=c.updated_at;
 end if;
 result:=private.book_crm_save_v2(p_policy,p_fields,p_expected_updated_at,p_expected_deal);
 if is_new then insert into private.book_crm_activity(client_id,actor_id,kind,body) values(p_policy,auth.uid(),'created','Policy added to client profile');end if;
 return result||jsonb_build_object('profile_id',p_client);
end;$$;

create function private.book_crm_profile_save(p_id uuid,p_fields jsonb,p_expected_updated_at timestamptz) returns jsonb
language plpgsql security definer set search_path='' as $$
declare person private.book_crm_profiles%rowtype; shared private.book_crm_clients%rowtype; merged jsonb; first_policy uuid;
begin
 if auth.uid() is null or not private.book_is_unlocked() then raise exception 'Book of Business is locked. Enter your PIN.' using errcode='42501';end if;
 if p_id is null or p_fields is null or jsonb_typeof(p_fields)<>'object' or p_fields is distinct from private.book_crm_contact_fields(p_fields) then raise exception 'Invalid contact fields';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,49413));
 select * into person from private.book_crm_profiles where id=p_id for update;
 if not found or not private.book_crm_can_access(person.agent_id,null) then raise exception 'Client not available to your account' using errcode='42501';end if;
 if person.updated_at is distinct from p_expected_updated_at then raise sqlstate 'PT409' using message='Client contact details changed. Reopen the client and try again.';end if;
 merged:=person.details||p_fields;
 merged:=merged||jsonb_build_object('date_of_birth',nullif(merged->>'date_of_birth','')::date,'mortgage_balance',nullif(merged->>'mortgage_balance','')::numeric);
 shared:=jsonb_populate_record(null::private.book_crm_clients,merged);
 if coalesce(length(trim(shared.client_name)),0) not between 1 and 200 then raise exception 'Client name is required (up to 200 characters)';end if;
 if exists(select 1 from jsonb_each_text(merged) f where (f.key in ('address_line1','address_line2','city') and length(f.value)>200) or (f.key in ('phone','alternate_phone','state') and length(f.value)>50) or (f.key='email' and length(f.value)>254) or (f.key='zip' and length(f.value)>20)) then raise exception 'One or more contact fields are too long';end if;
 if shared.date_of_birth>current_date or shared.date_of_birth<date '1900-01-01' then raise exception 'Enter a valid date of birth';end if;
 if shared.mortgage_balance<0 or shared.mortgage_balance>999999999999.99 then raise exception 'Enter a valid mortgage balance';end if;
 -- Synchronization trigger mirrors these shared fields, never policy values, to siblings.
 select id into first_policy from private.book_crm_clients where profile_id=p_id order by id limit 1;
 update private.book_crm_clients set client_name=trim(shared.client_name),address_line1=coalesce(shared.address_line1,''),address_line2=coalesce(shared.address_line2,''),city=coalesce(shared.city,''),state=coalesce(shared.state,''),zip=coalesce(shared.zip,''),phone=coalesce(shared.phone,''),email=coalesce(shared.email,''),alternate_phone=coalesce(shared.alternate_phone,''),date_of_birth=shared.date_of_birth,mortgage_balance=shared.mortgage_balance,updated_at=clock_timestamp() where id=first_policy;
 insert into private.book_crm_activity(client_id,actor_id,kind,body) values(first_policy,auth.uid(),'updated','Shared client contact details updated');
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'crm_profile_saved','crm_profile',p_id::text,jsonb_build_object('before',person.details,'after',merged));
 return jsonb_build_object('ok',true,'id',p_id);
end;$$;

create function public.book_crm_profiles_list(p_page int default 1,p_search text default '',p_agent uuid default null,p_stage text default '',p_limit int default 50) returns jsonb language sql security invoker set search_path='' as $$select private.book_crm_profiles_list(p_page,p_search,p_agent,p_stage,p_limit)$$;
create function public.book_crm_profile_detail(p_id uuid) returns jsonb language sql security invoker set search_path='' as $$select private.book_crm_profile_detail(p_id)$$;
create function public.book_crm_policy_save(p_client uuid,p_policy uuid,p_fields jsonb,p_expected_updated_at timestamptz default null,p_expected_deal jsonb default null) returns jsonb language sql security invoker set search_path='' as $$select private.book_crm_policy_save(p_client,p_policy,p_fields,p_expected_updated_at,p_expected_deal)$$;
create function public.book_crm_profile_save(p_id uuid,p_fields jsonb,p_expected_updated_at timestamptz) returns jsonb language sql security invoker set search_path='' as $$select private.book_crm_profile_save(p_id,p_fields,p_expected_updated_at)$$;
revoke all on function private.book_crm_profiles_list(int,text,uuid,text,int),public.book_crm_profiles_list(int,text,uuid,text,int),private.book_crm_profile_detail(uuid),public.book_crm_profile_detail(uuid),private.book_crm_policy_save(uuid,uuid,jsonb,timestamptz,jsonb),public.book_crm_policy_save(uuid,uuid,jsonb,timestamptz,jsonb),private.book_crm_profile_save(uuid,jsonb,timestamptz),public.book_crm_profile_save(uuid,jsonb,timestamptz) from public,anon,authenticated;
grant execute on function private.book_crm_profiles_list(int,text,uuid,text,int),public.book_crm_profiles_list(int,text,uuid,text,int),private.book_crm_profile_detail(uuid),public.book_crm_profile_detail(uuid),private.book_crm_policy_save(uuid,uuid,jsonb,timestamptz,jsonb),public.book_crm_policy_save(uuid,uuid,jsonb,timestamptz,jsonb),private.book_crm_profile_save(uuid,jsonb,timestamptz),public.book_crm_profile_save(uuid,jsonb,timestamptz) to authenticated;

create or replace function private.book_crm_workspace(p_page int default 1,p_search text default '',p_agent uuid default null,p_stage text default '',p_limit int default 50,p_view text default 'clients',p_task_status text default 'open') returns jsonb
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
 tasks as materialized (select t.*,f.client_name,f.agent_name,f.pipeline_stage,f.carrier,f.policy_type,f.policy_number,f.profile_id from private.book_crm_tasks t join filtered f on f.id=t.client_id where (p_task_status='open' and t.completed_at is null) or (p_task_status='completed' and t.completed_at is not null)),
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

create or replace function private.book_crm_pipeline(
 p_search text default '',p_agent uuid default null,p_carrier text default '',
 p_stage text default '',p_page int default 1,p_limit int default 50,p_view text default 'board',
 p_today_start timestamptz default null,p_today_end timestamptz default null
) returns jsonb language plpgsql stable security definer set search_path='' as $$
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
 ), todaypage as (select * from today order by due_at,id limit 8)
 select jsonb_build_object(
  'rows',case when p_view='list' then coalesce((select jsonb_agg(to_jsonb(paged) order by created_at desc,id) from paged),'[]') else '[]'::jsonb end,
  'pipeline',case when p_view='board' then coalesce((select jsonb_agg(to_jsonb(ranked)-'rn' order by created_at desc,id) from ranked where rn<=25),'[]') else '[]'::jsonb end,
  'count',(select count(*) from filtered),
  'stage_counts',coalesce((select jsonb_object_agg(pipeline_stage,n) from (select pipeline_stage,count(*) n from matched group by pipeline_stage)s),'{}'),
  'carriers',coalesce((select jsonb_agg(carrier order by carrier) from (select distinct carrier from permitted where coalesce(carrier,'')<>'')c),'[]'),
  'today_tasks',coalesce((select jsonb_agg(to_jsonb(todaypage) order by due_at,id) from todaypage),'[]'),
  'today_task_count',(select count(*) from today)
 ) into result;
 return result;
end;$$;


notify pgrst,'reload schema';
