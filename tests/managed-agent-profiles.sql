begin;
create temp table managed_test_actors on commit drop as
select distinct on (p.id) p.id,p.role,p.is_super_admin,p.is_team_leader,p.division,s.id sid from public.profiles p join auth.sessions s on s.user_id=p.id
where p.active and not p.archived and (s.not_after is null or s.not_after>now()) order by p.id,s.created_at desc;
create temp table managed_test_target on commit drop as
select p.id,p.division,a.id leader_id,to_jsonb(p) original from public.profiles p join managed_test_actors a on a.role='agent' and a.is_team_leader and p.division=a.division where p.role='agent' and not p.is_team_leader and not p.archived and p.id<>a.id limit 1;
update public.profiles p set team_leader_id=t.leader_id from managed_test_target t where p.id=t.id;
grant select on managed_test_actors,managed_test_target to authenticated;
set local role authenticated;
do $test$
declare actor record; target record; data jsonb; row jsonb; rejected boolean; ordinary record; foreign_id uuid;
begin
 select * into strict target from managed_test_target;
 for actor in select * from managed_test_actors where role='admin' or id=target.leader_id loop
  perform set_config('request.jwt.claims',jsonb_build_object('sub',actor.id,'session_id',actor.sid,'role','authenticated','aal','aal2')::text,true);
  data:=public.managed_agent_profiles();
  for row in select value from jsonb_array_elements(data->'rows') loop
   if actor.role='agent' and (row->>'team_leader_id' is distinct from actor.id::text or row->>'division' is distinct from actor.division or (row->>'is_team_leader')::boolean) then raise exception 'Leader scope leak';end if;
   if actor.role='admin' and not public.admin_can_manage_agent((row->>'id')::uuid) then raise exception 'Admin scope leak';end if;
  end loop;
 end loop;
 select * into strict actor from managed_test_actors where id=target.leader_id;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',actor.id,'session_id',actor.sid,'role','authenticated','aal','aal2')::text,true);
 if jsonb_array_length(public.managed_agent_profiles(target.id)->'rows')<>1 then raise exception 'Own agent missing';end if;
 perform public.manage_direct_agent(target.id,'rename','Profile test name');
 perform public.manage_direct_agent(target.id,'disable');
 data:=public.managed_agent_profiles(target.id)->'rows'->0;
 if data->>'full_name'<>'Profile test name' or (data->>'active')::boolean then raise exception 'Name/disable did not persist';end if;
 select id into strict foreign_id from managed_test_actors where role='admin' limit 1;
 rejected:=false;begin perform public.managed_agent_profiles(foreign_id);exception when insufficient_privilege then rejected:=true;end;if not rejected then raise exception 'Foreign profile readable';end if;
 rejected:=false;begin perform public.manage_direct_agent(foreign_id,'disable');exception when insufficient_privilege then rejected:=true;end;if not rejected then raise exception 'Admin account editable by leader';end if;
 rejected:=false;begin perform public.manage_direct_agent(actor.id,'disable');exception when insufficient_privilege then rejected:=true;end;if not rejected then raise exception 'Self disable admitted';end if;
 begin perform public.manage_direct_agent(target.id,'enable');raise exception 'Enable accepted';exception when others then if sqlerrm<>'Unsupported action' then raise;end if;end;
 select * into strict ordinary from managed_test_actors where role='agent' and not is_team_leader and id<>target.id limit 1;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',ordinary.id,'session_id',ordinary.sid,'role','authenticated','aal','aal2')::text,true);
 rejected:=false;begin perform public.managed_agent_profiles();exception when insufficient_privilege or sqlstate 'PT403' then rejected:=true;end;if not rejected then raise exception 'Ordinary agent admitted';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',actor.id,'session_id',gen_random_uuid(),'aal','aal1')::text,true);
 rejected:=false;begin perform public.managed_agent_profiles();exception when insufficient_privilege then rejected:=true;end;if not rejected then raise exception 'Unverified session admitted';end if;
 if has_function_privilege('anon','public.managed_agent_profiles(uuid,uuid)','execute') or has_function_privilege('anon','public.manage_direct_agent(uuid,text,text)','execute') then raise exception 'Anonymous execution granted';end if;
end $test$;
reset role;
do $test$
begin
 if exists(select 1 from managed_test_target t join public.profiles p using(id) where (to_jsonb(p)-'full_name'-'active'-'team_leader_id'-'updated_at') is distinct from (t.original-'full_name'-'active'-'team_leader_id'-'updated_at')) then raise exception 'Other account fields changed';end if;
 if exists(select 1 from auth.sessions s join managed_test_target t on t.id=s.user_id where s.not_after is null or s.not_after>now()) then raise exception 'Disabled agent session still active';end if;
end $test$;
rollback;
select 'PASS: agency and direct-team scope, licensing read, rename, disable/session expiry, ordinary agent/foreign/self/unverified/anonymous rejection; changes rolled back' result;
