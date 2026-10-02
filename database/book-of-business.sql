-- Personal PIN gate, effective-dated compensation and immutable rate snapshots.
create table private.book_pins(user_id uuid primary key references public.profiles(id) on delete cascade,pin_hash text not null,failures int not null default 0,locked_until timestamptz);
create table private.book_unlocks(user_id uuid not null references public.profiles(id) on delete cascade,session_id text not null,expires_at timestamptz not null,primary key(user_id,session_id));
create table private.book_comp_grid(id uuid primary key default gen_random_uuid(),agent_id uuid not null references public.profiles(id),carrier text not null,policy_type text not null,comp_percent numeric(7,3) not null check(comp_percent between 0 and 200),advance_percent numeric(7,3) not null check(advance_percent between 0 and 100),effective_date date not null,updated_by uuid not null references public.profiles(id),updated_at timestamptz not null default now(),unique(agent_id,carrier,policy_type,effective_date));
create table private.book_deal_comp(deal_id uuid primary key references public.closed_business(id) on delete cascade,grid_id uuid not null references private.book_comp_grid(id),comp_percent numeric not null,advance_percent numeric not null,captured_at timestamptz not null default now());
alter table private.book_pins enable row level security;
alter table private.book_unlocks enable row level security;
alter table private.book_comp_grid enable row level security;
alter table private.book_deal_comp enable row level security;
revoke all on private.book_pins,private.book_unlocks,private.book_comp_grid,private.book_deal_comp from public,anon,authenticated;
create index book_comp_agent_date on private.book_comp_grid(agent_id,effective_date desc);
create function private.book_is_unlocked() returns boolean language sql stable security definer set search_path='' as $$
select private.verified_portal_session() and exists(select 1 from private.book_unlocks u where u.user_id=auth.uid() and u.session_id=auth.jwt()->>'session_id' and u.expires_at>now());
$$;
create function private.book_access(p_action text,p_pin text default null,p_old_pin text default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare r private.book_pins%rowtype; sid text:=auth.jwt()->>'session_id';
begin
 if not private.verified_portal_session() or auth.uid() is null or coalesce(sid,'')='' then raise exception 'Verified sign-in required' using errcode='42501';end if;
 -- Serialize setup and attempts for this user, including when no PIN row exists yet.
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text,94831));
 select * into r from private.book_pins where user_id=auth.uid() for update;
 if p_action='status' then return jsonb_build_object('has_pin',r.user_id is not null,'unlocked',private.book_is_unlocked(),'expires_at',(select expires_at from private.book_unlocks where user_id=auth.uid() and session_id=sid));end if;
 if p_action='lock' then delete from private.book_unlocks where user_id=auth.uid() and session_id=sid;return jsonb_build_object('has_pin',r.user_id is not null,'unlocked',false);end if;
 if p_action not in ('set','unlock','change') then raise exception 'Unknown action';end if;
 if r.locked_until>now() then return jsonb_build_object('error','Too many attempts. Try again in 15 minutes.');end if;
 if p_pin is null or p_pin !~ '^[0-9]{6}$' then return jsonb_build_object('error','Use a six-digit PIN.');end if;
 if (p_action='set' and r.user_id is not null) or (p_action in ('unlock','change') and r.user_id is null) then return jsonb_build_object('error','Refresh and try again.');end if;
 if r.user_id is not null and extensions.crypt(case when p_action='change' then coalesce(p_old_pin,'') else p_pin end,r.pin_hash)<>r.pin_hash then
 update private.book_pins set failures=case when coalesce(locked_until,'epoch')<=now() and failures>=5 then 1 else failures+1 end,locked_until=case when coalesce(locked_until,'epoch')<=now() and failures>=5 then null when failures>=4 then now()+interval '15 minutes' else null end where user_id=auth.uid();
 return jsonb_build_object('error','Incorrect PIN. Five failed attempts lock access for 15 minutes.');
 end if;
 if p_action in ('set','change') then
 insert into private.book_pins(user_id,pin_hash) values(auth.uid(),extensions.crypt(p_pin,extensions.gen_salt('bf',10))) on conflict(user_id) do update set pin_hash=excluded.pin_hash,failures=0,locked_until=null;
 delete from private.book_unlocks where user_id=auth.uid();
 else update private.book_pins set failures=0,locked_until=null where user_id=auth.uid();end if;
 insert into private.book_unlocks values(auth.uid(),sid,now()+interval '15 minutes') on conflict(user_id,session_id) do update set expires_at=excluded.expires_at;
 return jsonb_build_object('has_pin',true,'unlocked',true,'expires_at',now()+interval '15 minutes');
end;$$;
create function private.book_capture(p_agent uuid default null) returns void language sql security definer set search_path='' as $$
insert into private.book_deal_comp(deal_id,grid_id,comp_percent,advance_percent)
select c.id,g.id,g.comp_percent,g.advance_percent from public.closed_business c
join lateral(select g.* from private.book_comp_grid g where g.agent_id=c.agent_id and g.carrier=lower(trim(c.carrier)) and g.policy_type=lower(trim(c.policy_type)) and g.effective_date<=coalesce(c.application_date,c.created_at::date) order by g.effective_date desc limit 1)g on true
where (p_agent is null or c.agent_id=p_agent) and not exists(select 1 from private.book_deal_comp x where x.deal_id=c.id)
on conflict(deal_id) do nothing;
$$;
create function private.book_capture_deal() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if TG_OP='UPDATE' and (new.agent_id is distinct from old.agent_id or new.carrier is distinct from old.carrier or new.policy_type is distinct from old.policy_type or new.application_date is distinct from old.application_date) then delete from private.book_deal_comp where deal_id=new.id;end if;
 insert into private.book_deal_comp(deal_id,grid_id,comp_percent,advance_percent)
 select new.id,g.id,g.comp_percent,g.advance_percent from private.book_comp_grid g where g.agent_id=new.agent_id and g.carrier=lower(trim(new.carrier)) and g.policy_type=lower(trim(new.policy_type)) and g.effective_date<=coalesce(new.application_date,new.created_at::date) order by g.effective_date desc limit 1 on conflict(deal_id) do nothing;
 return new;
end;$$;
create trigger book_capture_closed after insert or update of agent_id,carrier,policy_type,application_date on public.closed_business for each row execute function private.book_capture_deal();
create function private.book_data(p_page integer default 1,p_search text default '',p_agent uuid default null) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 if not private.book_is_unlocked() then raise exception 'Book of Business is locked. Enter your PIN.' using errcode='42501';end if;
 with permitted as (
 select c.id,c.agent_id,p.full_name agent_name,c.carrier,c.policy_type,c.monthly_premium,c.annual_premium,c.application_date,c.policy_number,c.created_at,
 coalesce(nullif(trim(concat_ws(' ',l.first_name,l.last_name)),''),'Client not linked') client_name,l.phone,l.email,
 x.comp_percent,x.advance_percent,case when x.deal_id is not null then round(c.annual_premium*x.comp_percent/100*x.advance_percent/100,2) end estimated_advance
 from public.closed_business c join public.profiles p on p.id=c.agent_id left join public.leads l on l.id=c.lead_id left join private.book_deal_comp x on x.deal_id=c.id
 where (c.agent_id=auth.uid() or public.is_super_admin() or public.admin_can_manage_agent(c.agent_id) or private.can_read_admin_sale(c.agent_id,c.lead_id)) and (p_agent is null or c.agent_id=p_agent)
 ),filtered as(select * from permitted where coalesce(p_search,'')='' or concat_ws(' ',client_name,agent_name,carrier,policy_type,policy_number) ilike '%'||left(p_search,100)||'%'),paged as(select * from filtered order by created_at desc,id limit 100 offset (greatest(1,least(coalesce(p_page,1),100000))-1)*100)
 select jsonb_build_object('rows',coalesce((select jsonb_agg(to_jsonb(paged)) from paged),'[]'::jsonb),'count',(select count(*) from filtered),'estimated_advance',(select coalesce(sum(estimated_advance),0) from filtered),'missing_comp',(select count(*) from filtered where estimated_advance is null)) into result;
 return result;
end;$$;
create function private.book_grid(p_action text default 'list',p_agent uuid default null,p_carrier text default null,p_policy_type text default null,p_comp numeric default null,p_advance numeric default null,p_effective date default null) returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if not private.book_is_unlocked() then raise exception 'Book of Business is locked. Enter your PIN.' using errcode='42501';end if;
 if p_action in ('save','reset-pin') then
 if not public.is_super_admin() then raise exception 'Only Master can change compensation or reset PINs' using errcode='42501';end if;
 if not exists(select 1 from public.profiles where id=p_agent and active and not coalesce(archived,false)) then raise exception 'Choose an active agent or admin';end if;
 if p_action='reset-pin' then delete from private.book_unlocks where user_id=p_agent;delete from private.book_pins where user_id=p_agent;return jsonb_build_object('ok',true);end if;
 if coalesce(length(trim(p_carrier)),0) not between 1 and 100 or coalesce(length(trim(p_policy_type)),0) not between 1 and 100 or p_comp is null or p_comp not between 0 and 200 or p_advance is null or p_advance not between 0 and 100 or p_effective is null then raise exception 'Carrier, product, effective date and valid percentages required';end if;
 insert into private.book_comp_grid(agent_id,carrier,policy_type,comp_percent,advance_percent,effective_date,updated_by) values(p_agent,lower(trim(p_carrier)),lower(trim(p_policy_type)),p_comp,p_advance,p_effective,auth.uid()) on conflict(agent_id,carrier,policy_type,effective_date) do update set comp_percent=excluded.comp_percent,advance_percent=excluded.advance_percent,updated_by=auth.uid(),updated_at=now();
 perform private.book_capture(p_agent);
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'book_comp_grid_saved','profile',p_agent::text,jsonb_build_object('carrier',trim(p_carrier),'policy_type',trim(p_policy_type),'comp_percent',p_comp,'advance_percent',p_advance,'effective_date',p_effective));
 elsif p_action<>'list' then raise exception 'Unknown action';end if;
 return jsonb_build_object('rows',coalesce((select jsonb_agg(to_jsonb(g)||jsonb_build_object('agent_name',p.full_name) order by p.full_name,g.carrier,g.policy_type,g.effective_date desc) from private.book_comp_grid g join public.profiles p on p.id=g.agent_id where g.agent_id=auth.uid() or public.is_super_admin() or public.admin_can_manage_agent(g.agent_id)),'[]'::jsonb),'agents',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'full_name',p.full_name,'division',p.division) order by p.full_name) from public.profiles p where p.active and not coalesce(p.archived,false) and (p.id=auth.uid() or public.is_super_admin() or public.admin_can_manage_agent(p.id))),'[]'::jsonb));
end;$$;
create function public.book_access(p_action text,p_pin text default null,p_old_pin text default null) returns jsonb language sql set search_path='' as $$ select private.book_access(p_action,p_pin,p_old_pin) $$;
create function public.book_data(p_page integer default 1,p_search text default '',p_agent uuid default null) returns jsonb language sql set search_path='' as $$select private.book_data(p_page,p_search,p_agent)$$;
create function public.book_grid(p_action text default 'list',p_agent uuid default null,p_carrier text default null,p_policy_type text default null,p_comp numeric default null,p_advance numeric default null,p_effective date default null) returns jsonb language sql set search_path='' as $$select private.book_grid(p_action,p_agent,p_carrier,p_policy_type,p_comp,p_advance,p_effective)$$;
revoke all on function private.book_is_unlocked(),private.book_access(text,text,text),private.book_capture(uuid),private.book_capture_deal(),private.book_data(integer,text,uuid),private.book_grid(text,uuid,text,text,numeric,numeric,date),public.book_access(text,text,text),public.book_data(integer,text,uuid),public.book_grid(text,uuid,text,text,numeric,numeric,date) from public,anon,authenticated;
grant execute on function private.book_access(text,text,text),private.book_data(integer,text,uuid),private.book_grid(text,uuid,text,text,numeric,numeric,date),public.book_access(text,text,text),public.book_data(integer,text,uuid),public.book_grid(text,uuid,text,text,numeric,numeric,date) to authenticated;
