-- Verify every active admin/team leader can retrieve their personal production.
-- Temporary PIN unlocks and session claims are rolled back; client records are read only.
begin;
create temporary table crm_personal_actors on commit drop as
 select p.id,p.role,p.is_team_leader,gen_random_uuid() sid,
 coalesce((select jsonb_agg(d.id) from public.closed_business d where d.agent_id=p.id),'[]'::jsonb) expected
 from public.profiles p join public.divisions a on a.id=p.division
 where p.active and not coalesce(p.archived,false) and not a.archived
 and (p.role='admin' or p.is_team_leader);
insert into private.book_unlocks(user_id,session_id,expires_at)
 select id,sid::text,now()+interval '15 minutes' from crm_personal_actors;
grant select on crm_personal_actors to authenticated;
set local role authenticated;
do $$
declare actor record; result jsonb; grouped jsonb; board jsonb; deal jsonb; row jsonb; details jsonb;
begin
 if not exists(select 1 from crm_personal_actors where role='admin') or not exists(select 1 from crm_personal_actors where is_team_leader) then raise exception 'Test needs active admins and team leaders';end if;
 for actor in select * from crm_personal_actors loop
  perform set_config('request.jwt.claims',jsonb_build_object('sub',actor.id,'aal','aal2','session_id',actor.sid)::text,true);
  if not exists(select 1 from jsonb_array_elements(public.book_grid()->'agents') a where a->>'id'=actor.id::text) then raise exception 'Current user missing from permitted agents';end if;
  result:=public.book_crm_workspace(p_agent=>actor.id,p_limit=>2000);
  grouped:=public.book_crm_profiles_list(p_agent=>actor.id,p_limit=>2000);
  board:=public.book_crm_pipeline(p_agent=>actor.id,p_limit=>2000,p_view=>'list');
  if exists(select 1 from jsonb_array_elements(result->'rows') r where r->>'agent_id'<>actor.id::text)
   or exists(select 1 from jsonb_array_elements(grouped->'rows') r where r->>'agent_id'<>actor.id::text)
   or exists(select 1 from jsonb_array_elements(board->'rows') r where r->>'agent_id'<>actor.id::text)
  then raise exception 'Personal filter returned someone else''s record';end if;
  for deal in select * from jsonb_array_elements(actor.expected) loop
   select r into row from jsonb_array_elements(result->'rows') r where r->'deal_id'=deal;
   if row is null then raise exception 'Personal closed deal missing from CRM';end if;
   if not exists(select 1 from jsonb_array_elements(grouped->'rows') g cross join lateral jsonb_array_elements(g->'policies') p where p->>'id'=row->>'id') then raise exception 'Personal policy missing from grouped clients';end if;
   if not exists(select 1 from jsonb_array_elements(board->'rows') r where r->'deal_id'=deal) then raise exception 'Personal closed deal missing from pipeline';end if;
   details:=public.book_crm_profile_detail((row->>'id')::uuid);
   if details->'client'->>'agent_id'<>actor.id::text then raise exception 'Cannot open own closed deal';end if;
  end loop;
 end loop;
end $$;
reset role;
select 'PASS: every active admin/team leader has a personal filter target, all own closed deals in clients and pipeline, and working policy detail access; changes rolled back' result,
 count(*) accounts,sum(jsonb_array_length(expected)) closed_deals from crm_personal_actors;
rollback;
