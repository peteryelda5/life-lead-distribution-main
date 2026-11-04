begin;
create temp table bob_scope_test on commit drop as
select p.id, s.id sid from public.profiles p join auth.sessions s on s.user_id=p.id
where p.is_super_admin and p.active and not p.archived and (s.not_after is null or s.not_after>now()) limit 1;
grant select on bob_scope_test to authenticated;
insert into private.book_unlocks(user_id,session_id,expires_at)
select id,sid::text,now()+interval '1 hour' from bob_scope_test
on conflict (user_id,session_id) do update set expires_at=excluded.expires_at;
set local role authenticated;
do $test$
declare actor record; all_rows jsonb; part jsonb; agency jsonb; batched integer:=0; denied boolean:=false;
begin
 select * into strict actor from bob_scope_test;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',actor.id,'session_id',actor.sid,'role','authenticated','aal','aal2')::text,true);
 all_rows:=public.book_crm_workspace(p_limit=>2000);
 for agency in select value from jsonb_array_elements(public.agency_branding_context()->'manageable') loop
  part:=public.book_crm_workspace_agency(p_agency=>agency->>'id',p_limit=>2000);
  if exists(select 1 from jsonb_array_elements(part->'rows') r where r->>'agent_agency_name' is distinct from agency->>'name') then raise exception 'Out-of-scope policy';end if;
  batched:=batched+(part->>'count')::int;
  if (public.book_crm_profiles_list_agency(p_agency=>agency->>'id')->>'policy_count')::int<>(part->>'count')::int or
     (public.book_crm_pipeline_agency(p_agency=>agency->>'id',p_view=>'list')->>'count')::int<>(part->>'count')::int then raise exception 'Scoped totals disagree';end if;
 end loop;
 if batched<>(all_rows->>'count')::int or batched=0 then raise exception 'Agency totals do not reconcile';end if;
 if (public.book_crm_workspace_agency(p_agency=>'__nonexistent__')->>'count')::int<>0 then raise exception 'Unknown agency leaked rows';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',actor.id,'session_id',gen_random_uuid(),'aal','aal1')::text,true);
 begin perform public.book_crm_profiles_list_agency(p_agency=>'vivid_life'); exception when insufficient_privilege then denied:=true;end;
 if not denied then raise exception 'Locked request was admitted';end if;
 if has_function_privilege('anon','public.book_crm_profiles_list_agency(text,integer,text,uuid,text,integer)','execute') then raise exception 'Anonymous execute granted';end if;
end $test$;
rollback;
select 'PASS: agency totals reconcile across profiles, policies and pipeline; locked and anonymous access restricted' as result;
