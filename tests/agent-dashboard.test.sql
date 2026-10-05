begin;
do $$declare a uuid; b uuid; m uuid; d jsonb; expected bigint;
begin
select id into a from public.profiles where role='agent' and active and not archived limit 1;
select id into b from public.profiles where role='agent' and active and not archived and id<>a limit 1;
select id into m from public.profiles where is_super_admin limit 1;
perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'role','authenticated','aal','aal2')::text,true);
d:=public.agent_dashboard();
select count(*) into expected from public.leads where assigned_to=a and status='assigned';
if (d->>'agent_id')::uuid<>a or (d->>'assigned')::bigint<>expected then raise exception 'Own scope totals incorrect';end if;
if exists(select 1 from jsonb_array_elements(d->'recent') r join public.closed_business c on c.id=(r->>'id')::uuid where c.agent_id<>a) then raise exception 'Foreign deal exposed';end if;
begin perform public.agent_dashboard(b); raise exception 'Foreign agent accessible';exception when insufficient_privilege then null;end;
perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'role','authenticated','aal','aal1')::text,true);
begin perform public.agent_dashboard();raise exception 'MFA bypass';exception when insufficient_privilege then null;end;
perform set_config('request.jwt.claims',jsonb_build_object('sub',m,'role','authenticated','aal','aal2')::text,true);
d:=public.agent_dashboard(a);
if (d->>'agent_id')::uuid<>a or (d->>'assigned')::bigint<>expected then raise exception 'Master preview differs';end if;
end $$;
rollback;