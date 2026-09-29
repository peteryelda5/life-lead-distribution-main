do $$
declare master_id uuid; agent_id uuid; other_id uuid; denied boolean;
begin
 select id into master_id from public.profiles where active and role='admin' and is_super_admin limit 1;
 select id into agent_id from public.profiles where active and role='agent' and not coalesce(archived,false) limit 1;
 select id into other_id from public.profiles where active and role='admin' and not is_super_admin limit 1;
 if master_id is null or agent_id is null or other_id is null then raise exception 'Missing test roles'; end if;
 begin
  perform set_config('request.jwt.claims',jsonb_build_object('sub',master_id,'role','authenticated','aal','aal2')::text,true);
  set local role authenticated;
  if public.open_agent_support(agent_id) is not true then raise exception 'Master denied'; end if;
  reset role;
  if not exists(select 1 from public.audit_logs where actor_id=master_id and action='agent_support_view' and entity_id=agent_id::text)
   then raise exception 'Master support access not audited'; end if;
  raise sqlstate 'ZX001' using message='rollback fixture audit';
 exception when sqlstate 'ZX001' then reset role;
 end;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',other_id,'role','authenticated','aal','aal2')::text,true);
 set local role authenticated;
 denied:=false;
 begin perform public.open_agent_support(agent_id); exception when insufficient_privilege then denied:=true; end;
 if not denied then raise exception 'Scoped admin accessed Master support view'; end if;
 reset role;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',master_id,'role','authenticated','aal','aal1')::text,true);
 set local role authenticated;
 denied:=false;
 begin perform public.open_agent_support(agent_id); exception when insufficient_privilege then denied:=true; end;
 if not denied then raise exception 'Password-only Master accessed support view'; end if;
 reset role;
end $$;
