create table public.lead_requests (
 id uuid primary key default gen_random_uuid(),
 agent_id uuid not null default auth.uid() references public.profiles(id),
 recipient_id uuid not null references public.profiles(id),
 division text not null,
 agent_name text not null,
 recipient_name text not null,
 lead_type text not null check(length(btrim(lead_type)) between 1 and 120),
 quantity integer not null check(quantity between 1 and 10000),
 note text not null default '' check(length(note)<=1000),
 status text not null default 'pending' check(status in ('pending','completed','declined')),
 response text not null default '' check(length(response)<=1000),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
alter table public.lead_requests enable row level security;
create index lead_requests_agent_created on public.lead_requests(agent_id,created_at desc,id desc);
create index lead_requests_division_created on public.lead_requests(division,created_at desc,id desc);
create index lead_requests_recipient_created on public.lead_requests(recipient_id,created_at desc,id desc);
create function private.lead_request_route() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare a public.profiles; r public.profiles;
begin
 select * into a from public.profiles where id=auth.uid() and role='agent' and active and not coalesce(archived,false);
 if a.id is null or not public.is_active_agent() then raise exception 'Active agent with MFA required'; end if;
 select * into r from public.profiles where id=a.team_leader_id and id<>a.id and role='agent' and is_team_leader and active and not coalesce(archived,false) and division=a.division;
 if r.id is null then
 select * into r from public.profiles where role='admin' and active and not coalesce(archived,false) and division=a.division order by (id=a.created_by_admin_id) desc nulls last,is_super_admin desc,created_at,id limit 1;
 end if;
 if r.id is null then raise exception 'No active team leader or division admin is available. Contact your Master Admin.'; end if;
 return jsonb_build_object('agent_id',a.id,'agent_name',a.full_name,'division',a.division,'recipient_id',r.id,'recipient_name',r.full_name,'recipient_role',case when r.role='admin' then 'Division admin' else 'Team leader' end);
end $$;
revoke all on function private.lead_request_route() from public,anon;
grant execute on function private.lead_request_route() to authenticated;
create function public.my_lead_request_route() returns jsonb language sql stable security invoker set search_path='' as $$ select private.lead_request_route() $$;
revoke all on function public.my_lead_request_route() from public,anon;
grant execute on function public.my_lead_request_route() to authenticated;
create function private.can_manage_lead_request(p_agent uuid,p_division text) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.profiles me where me.id=auth.uid() and me.active and not coalesce(me.archived,false) and
 ((me.role='admin' and (me.is_super_admin or me.division=p_division)) or
 (me.role='agent' and me.is_team_leader and public.is_active_agent() and me.division=p_division and exists(select 1 from public.profiles a where a.id=p_agent and a.team_leader_id=me.id and a.division=me.division))))
$$;
revoke all on function private.can_manage_lead_request(uuid,text) from public,anon;
grant execute on function private.can_manage_lead_request(uuid,text) to authenticated;
create policy lead_request_read on public.lead_requests for select to authenticated using ((agent_id=(select auth.uid()) and (select public.is_active_agent())) or private.can_manage_lead_request(agent_id,division));
create policy lead_request_insert on public.lead_requests for insert to authenticated with check (agent_id=(select auth.uid()) and (select public.is_active_agent()) and status='pending');
create policy lead_request_update on public.lead_requests for update to authenticated using(private.can_manage_lead_request(agent_id,division)) with check(private.can_manage_lead_request(agent_id,division));
create function private.prepare_lead_request() returns trigger language plpgsql security definer set search_path='' as $$
declare r jsonb;
begin
 if TG_OP='INSERT' then
 r:=private.lead_request_route();
 new.agent_id:=(r->>'agent_id')::uuid; new.agent_name:=r->>'agent_name';new.division:=r->>'division';new.recipient_id:=(r->>'recipient_id')::uuid;new.recipient_name:=r->>'recipient_name';
 new.status:='pending';new.response:='';new.created_at:=now();new.lead_type:=btrim(new.lead_type);new.note:=btrim(new.note);
 end if;
 new.updated_at:=now();return new;
end $$;
revoke all on function private.prepare_lead_request() from public,anon,authenticated;
create trigger prepare_lead_request before insert or update on public.lead_requests for each row execute function private.prepare_lead_request();
revoke all on public.lead_requests from anon,authenticated;
grant select on public.lead_requests to authenticated;
grant insert(lead_type,quantity,note) on public.lead_requests to authenticated;
grant update(status,response) on public.lead_requests to authenticated;
