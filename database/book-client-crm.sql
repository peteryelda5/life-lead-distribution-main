create table private.book_crm_clients(
 id uuid primary key default gen_random_uuid(),agent_id uuid not null references public.profiles(id),client_name text not null,
 address_line1 text not null default '',address_line2 text not null default '',city text not null default '',state text not null default '',zip text not null default '',phone text not null default '',email text not null default '',
 carrier text not null default '',policy_type text not null default '',monthly_payment numeric(12,2) not null default 0 check(monthly_payment>=0),policy_number text not null default '',application_date date not null default current_date,
 status text not null default 'draft' check(status in ('draft','submitted','active','issued','lapsed','cancelled')),notes text not null default '',
 deal_id uuid unique references public.closed_business(id) on delete set null,production_recorded boolean not null default false,created_at timestamptz not null default now(),updated_at timestamptz not null default now());
alter table private.book_crm_clients enable row level security;
revoke all on private.book_crm_clients from public,anon,authenticated;
create index book_crm_agent_created on private.book_crm_clients(agent_id,created_at desc,id);
create function private.book_crm_can_access(p_agent uuid,p_deal uuid default null) returns boolean language sql stable security definer set search_path='' as $$
 select private.verified_portal_session() and (p_agent=auth.uid() or public.is_super_admin() or public.admin_can_manage_agent(p_agent) or exists(select 1 from public.closed_business d where d.id=p_deal and private.can_read_admin_sale(d.agent_id,d.lead_id)));
$$;
create function private.book_crm_closed_insert() returns trigger language plpgsql security definer set search_path='' as $$
declare client_id uuid:=nullif(current_setting('lld.crm_client_id',true),'')::uuid;
begin
 if client_id is not null then
 update private.book_crm_clients set deal_id=new.id,production_recorded=true where id=client_id and agent_id=new.agent_id;
 if found then return new;end if;
 end if;
 insert into private.book_crm_clients(agent_id,client_name,phone,email,state,carrier,policy_type,monthly_payment,policy_number,application_date,status,notes,deal_id,production_recorded)
 select new.agent_id,coalesce(b.client_name,nullif(trim(concat_ws(' ',l.first_name,l.last_name)),''),'Client not linked'),coalesce(b.phone,l.phone,''),coalesce(b.email,l.email,''),coalesce(l.state,''),new.carrier,new.policy_type,new.monthly_premium,coalesce(new.policy_number,''),coalesce(new.application_date,current_date),'issued',coalesce(new.notes,''),new.id,true
 from (select 1)z left join public.leads l on l.id=new.lead_id left join private.book_clients b on b.deal_id=new.id;
 return new;
end;$$;
create trigger book_crm_closed_insert after insert on public.closed_business for each row execute function private.book_crm_closed_insert();
insert into private.book_crm_clients(agent_id,client_name,phone,email,state,carrier,policy_type,monthly_payment,policy_number,application_date,status,notes,deal_id,production_recorded)
select c.agent_id,coalesce(b.client_name,nullif(trim(concat_ws(' ',l.first_name,l.last_name)),''),'Client not linked'),coalesce(b.phone,l.phone,''),coalesce(b.email,l.email,''),coalesce(l.state,''),c.carrier,c.policy_type,c.monthly_premium,coalesce(c.policy_number,''),coalesce(c.application_date,c.created_at::date),'issued',coalesce(c.notes,''),c.id,true from public.closed_business c left join public.leads l on l.id=c.lead_id left join private.book_clients b on b.deal_id=c.id;
create function private.book_crm_list(p_page int default 1,p_search text default '',p_agent uuid default null) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 if not private.book_is_unlocked() then raise exception 'Book of Business is locked. Enter your PIN.' using errcode='42501';end if;
 with permitted as(
 select c.*,p.full_name agent_name,coalesce(d.carrier,c.carrier) current_carrier,coalesce(d.policy_type,c.policy_type) current_policy_type,coalesce(d.monthly_premium,c.monthly_payment) current_monthly_payment,coalesce(d.application_date,c.application_date) current_application_date,case when d.id is null then c.policy_number else coalesce(d.policy_number,'') end current_policy_number,
 case when x.deal_id is not null then round(d.annual_premium*x.comp_percent/100*x.advance_percent/100,2) when d.id is null and g.id is not null then round(c.monthly_payment*12*g.comp_percent/100*g.advance_percent/100,2) end estimated_advance,
 coalesce(x.comp_percent,g.comp_percent) comp_percent,coalesce(x.advance_percent,g.advance_percent) advance_percent,
 case when d.id is null then null else jsonb_build_object('carrier',d.carrier,'policy_type',d.policy_type,'monthly_premium',d.monthly_premium,'application_date',d.application_date,'policy_number',d.policy_number,'notes',d.notes) end deal_version
 from private.book_crm_clients c join public.profiles p on p.id=c.agent_id left join public.closed_business d on d.id=c.deal_id left join private.book_deal_comp x on x.deal_id=d.id
 left join lateral(select g.* from private.book_comp_grid g where g.agent_id=c.agent_id and g.carrier=lower(trim(coalesce(d.carrier,c.carrier))) and g.policy_type=lower(trim(coalesce(d.policy_type,c.policy_type))) and g.effective_date<=coalesce(d.application_date,c.application_date) order by g.effective_date desc limit 1)g on true
 where private.book_crm_can_access(c.agent_id,c.deal_id) and (p_agent is null or c.agent_id=p_agent)
 ),filtered as(select * from permitted where coalesce(p_search,'')='' or concat_ws(' ',client_name,agent_name,current_carrier,current_policy_number,phone,email,address_line1,city,state,zip) ilike '%'||left(p_search,100)||'%'),paged as(select * from filtered order by created_at desc,id limit 100 offset (greatest(1,coalesce(p_page,1))-1)*100)
 select jsonb_build_object('rows',coalesce((select jsonb_agg(to_jsonb(paged)||jsonb_build_object('carrier',current_carrier,'policy_type',current_policy_type,'monthly_payment',current_monthly_payment,'application_date',current_application_date,'policy_number',current_policy_number)) from paged),'[]'::jsonb),'count',(select count(*) from filtered),'monthly_payment',(select coalesce(sum(current_monthly_payment),0) from filtered where status in ('active','issued')),'estimated_advance',(select coalesce(sum(estimated_advance),0) from filtered where status in ('active','issued')),'missing_comp',(select count(*) from filtered where estimated_advance is null and status in ('active','issued'))) into result;
 return result;
end;$$;
create function private.book_crm_save(p_id uuid,p_fields jsonb,p_expected_updated_at timestamptz default null,p_expected_deal jsonb default null) returns jsonb language plpgsql security definer set search_path='' as $$
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
 if price<0 or price>100000 or policy_status<>all(array['draft','submitted','active','issued','lapsed','cancelled']) then raise exception 'Valid monthly payment and policy status required';end if;
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
end;$$;
create function public.book_crm_list(p_page int default 1,p_search text default '',p_agent uuid default null) returns jsonb language sql set search_path='' as $$select private.book_crm_list(p_page,p_search,p_agent)$$;
create function public.book_crm_save(p_id uuid,p_fields jsonb,p_expected_updated_at timestamptz default null,p_expected_deal jsonb default null) returns jsonb language sql set search_path='' as $$select private.book_crm_save(p_id,p_fields,p_expected_updated_at,p_expected_deal)$$;
revoke all on function private.book_crm_can_access(uuid,uuid),private.book_crm_closed_insert(),private.book_crm_list(int,text,uuid),private.book_crm_save(uuid,jsonb,timestamptz,jsonb),public.book_crm_list(int,text,uuid),public.book_crm_save(uuid,jsonb,timestamptz,jsonb) from public,anon,authenticated;
grant execute on function private.book_crm_list(int,text,uuid),private.book_crm_save(uuid,jsonb,timestamptz,jsonb),public.book_crm_list(int,text,uuid),public.book_crm_save(uuid,jsonb,timestamptz,jsonb) to authenticated;
