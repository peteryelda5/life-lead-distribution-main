create table private.book_clients(deal_id uuid primary key references public.closed_business(id) on delete cascade,client_name text not null,phone text,email text,updated_by uuid not null references public.profiles(id));
alter table private.book_clients enable row level security;
revoke all on private.book_clients from public,anon,authenticated;
create function private.book_client(p_deal uuid,p_name text,p_phone text default null,p_email text default null) returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if not private.book_is_unlocked() then raise exception 'Book of Business is locked. Enter your PIN.' using errcode='42501';end if;
 if not exists(select 1 from public.closed_business c where c.id=p_deal and (c.agent_id=auth.uid() or public.is_super_admin() or public.admin_can_manage_agent(c.agent_id) or private.can_read_admin_sale(c.agent_id,c.lead_id))) then raise exception 'Deal not available to your account' using errcode='42501';end if;
 if coalesce(length(trim(p_name)),0) not between 1 and 200 or coalesce(length(p_phone),0)>50 or coalesce(length(p_email),0)>254 then raise exception 'Valid client name and contact details required';end if;
 insert into private.book_clients values(p_deal,trim(p_name),nullif(trim(p_phone),''),nullif(trim(p_email),''),auth.uid()) on conflict(deal_id) do update set client_name=excluded.client_name,phone=excluded.phone,email=excluded.email,updated_by=auth.uid();
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'book_client_updated','closed_business',p_deal::text,'{}');
 return jsonb_build_object('ok',true);
end;$$;
create function public.book_client(p_deal uuid,p_name text,p_phone text default null,p_email text default null) returns jsonb language sql set search_path='' as $$select private.book_client(p_deal,p_name,p_phone,p_email)$$;
revoke all on function private.book_client(uuid,text,text,text),public.book_client(uuid,text,text,text) from public,anon,authenticated;
grant execute on function private.book_client(uuid,text,text,text),public.book_client(uuid,text,text,text) to authenticated;
create or replace function private.book_data(p_page integer default 1,p_search text default '',p_agent uuid default null) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 if not private.book_is_unlocked() then raise exception 'Book of Business is locked. Enter your PIN.' using errcode='42501';end if;
 with permitted as (
 select c.id,c.agent_id,p.full_name agent_name,c.carrier,c.policy_type,c.monthly_premium,c.annual_premium,c.application_date,c.policy_number,c.created_at,
 coalesce(bc.client_name,nullif(trim(concat_ws(' ',l.first_name,l.last_name)),''),'Client not linked') client_name,coalesce(bc.phone,l.phone) phone,coalesce(bc.email,l.email) email,
 x.comp_percent,x.advance_percent,case when x.deal_id is not null then round(c.annual_premium*x.comp_percent/100*x.advance_percent/100,2) end estimated_advance
 from public.closed_business c join public.profiles p on p.id=c.agent_id left join public.leads l on l.id=c.lead_id left join private.book_deal_comp x on x.deal_id=c.id left join private.book_clients bc on bc.deal_id=c.id
 where (c.agent_id=auth.uid() or public.is_super_admin() or public.admin_can_manage_agent(c.agent_id) or private.can_read_admin_sale(c.agent_id,c.lead_id)) and (p_agent is null or c.agent_id=p_agent)
 ),filtered as(select * from permitted where coalesce(p_search,'')='' or concat_ws(' ',client_name,agent_name,carrier,policy_type,policy_number) ilike '%'||left(p_search,100)||'%'),paged as(select * from filtered order by created_at desc,id limit 100 offset (greatest(1,least(coalesce(p_page,1),100000))-1)*100)
 select jsonb_build_object('rows',coalesce((select jsonb_agg(to_jsonb(paged)) from paged),'[]'::jsonb),'count',(select count(*) from filtered),'estimated_advance',(select coalesce(sum(estimated_advance),0) from filtered),'missing_comp',(select count(*) from filtered where estimated_advance is null)) into result;
 return result;
end;$$;
