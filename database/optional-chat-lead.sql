alter table public.closed_business alter column lead_id drop not null;
alter table public.closed_business add column chat_request_id uuid;
create unique index closed_business_chat_request on public.closed_business(chat_request_id) where chat_request_id is not null;
create function private.chat_deal_agents(p_division text) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not coalesce(p_division=any(private.leaderboard_divisions()),false) then raise exception 'Division access denied';end if;
 return (select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.full_name) order by p.full_name),'[]'::jsonb) from public.profiles p where p.division=p_division and p.active and not coalesce(p.archived,false) and (p.role='agent' or p.id=auth.uid()) and (public.is_admin() or p.id=auth.uid()));
end $$;
revoke all on function private.chat_deal_agents(text) from public,anon;
grant execute on function private.chat_deal_agents(text) to authenticated;
create function public.chat_deal_agents(p_division text) returns jsonb language sql stable security invoker set search_path='' as $$select private.chat_deal_agents(p_division)$$;
revoke all on function public.chat_deal_agents(text) from public,anon;
grant execute on function public.chat_deal_agents(text) to authenticated;
create function private.chat_standalone_deal(p_division text,p_agent_id uuid,p_request_id uuid,p_carrier text,p_policy_type text,p_monthly_premium numeric,p_application_date date,p_policy_number text default null,p_notes text default null) returns uuid language plpgsql security definer set search_path='' as $$
declare v_id uuid;
begin
 if auth.uid() is null or not coalesce(p_division=any(private.leaderboard_divisions()),false) then raise exception 'Division access denied';end if;
 if p_agent_id is null or not exists(select 1 from public.profiles where id=p_agent_id and division=p_division and active and not coalesce(archived,false) and (role='agent' or id=auth.uid())) or (not public.is_admin() and p_agent_id is distinct from auth.uid()) then raise exception 'Choose an active agent in this division';end if;
 if p_request_id is null then raise exception 'Request ID required';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_request_id::text,741));
 select id into v_id from public.closed_business where chat_request_id=p_request_id and agent_id=p_agent_id;
 if found then return v_id;end if;
 if coalesce(btrim(p_carrier),'')='' or coalesce(btrim(p_policy_type),'')='' or char_length(p_carrier)>200 or char_length(p_policy_type)>100 then raise exception 'Carrier and policy type required';end if;
 if p_monthly_premium is null or p_monthly_premium<0 or p_monthly_premium>1000000 or p_monthly_premium::text in ('NaN','Infinity','-Infinity') then raise exception 'Enter a valid monthly premium';end if;
 if p_application_date is null or p_application_date<date '2000-01-01' or p_application_date>(now() at time zone 'America/Detroit')::date then raise exception 'Enter a valid application date';end if;
 if char_length(p_policy_number)>200 or char_length(p_notes)>10000 then raise exception 'Policy number or notes too long';end if;
 insert into public.closed_business(agent_id,chat_request_id,carrier,policy_type,monthly_premium,application_date,policy_number,notes) values(p_agent_id,p_request_id,btrim(p_carrier),btrim(p_policy_type),p_monthly_premium,p_application_date,nullif(btrim(p_policy_number),''),nullif(btrim(p_notes),'')) returning id into v_id;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'standalone_deal_closed','closed_business',v_id::text,jsonb_build_object('division',p_division,'agent_id',p_agent_id));
 return v_id;
end $$;
revoke all on function private.chat_standalone_deal(text,uuid,uuid,text,text,numeric,date,text,text) from public,anon;
grant execute on function private.chat_standalone_deal(text,uuid,uuid,text,text,numeric,date,text,text) to authenticated;
create function public.chat_standalone_deal(p_division text,p_agent_id uuid,p_request_id uuid,p_carrier text,p_policy_type text,p_monthly_premium numeric,p_application_date date,p_policy_number text default null,p_notes text default null) returns uuid language sql security invoker set search_path='' as $$select private.chat_standalone_deal(p_division,p_agent_id,p_request_id,p_carrier,p_policy_type,p_monthly_premium,p_application_date,p_policy_number,p_notes)$$;
revoke all on function public.chat_standalone_deal(text,uuid,uuid,text,text,numeric,date,text,text) from public,anon;
grant execute on function public.chat_standalone_deal(text,uuid,uuid,text,text,numeric,date,text,text) to authenticated;
