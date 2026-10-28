begin;
create or replace function private.portal_onboarding_allowed() returns boolean language sql stable security definer set search_path='' as $test$ select true $test$;
do $$
declare actor uuid; agent uuid; req uuid; result jsonb; batch text:='__quantity_rollback_'||gen_random_uuid()::text;
begin
 select id into actor from public.profiles where is_super_admin and active limit 1;
 select id into agent from public.profiles where role='agent' and active and not coalesce(archived,false) and division='vivid_life' limit 1;
 insert into public.leads(first_name,phone,division,status,lead_type,state) select 'Synthetic quantity test','2025550199','owner','unassigned',batch,'MI' from generate_series(1,1001);
 perform set_config('request.jwt.claims',jsonb_build_object('sub',agent,'role','authenticated','aal','aal2')::text,true);
 execute 'set local role authenticated';
 insert into public.lead_requests(lead_type,quantity) values(batch,100) returning id into req;
 execute 'reset role';
 perform set_config('request.jwt.claims',jsonb_build_object('sub',actor,'role','authenticated','aal','aal2')::text,true);
 execute 'set local role authenticated';
 result:=public.fulfill_lead_request(req,'owner',batch,'{MI}',1001,0);
 if (result->>'sent')::int<>1001 or result->>'status'<>'completed' or (result->>'remaining')::int<>0 then raise exception 'Extra send failed';end if;
 if not exists(select 1 from public.lead_requests where id=req and quantity=100 and fulfilled_quantity=1001) then raise exception 'Request was overwritten';end if;
 if (select count(*) from public.leads where lead_type=batch and assigned_to=agent and division='vivid_life')<>1001 then raise exception 'Incorrect assignment';end if;
 execute 'reset role';
end $$;
rollback;
select 'PASS: 100 requested, 1001 delivered across internal transfer chunks; original request preserved; all test data rolled back' as result;
