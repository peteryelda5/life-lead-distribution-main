begin;
do $$
declare m uuid; a uuid; foreign_agent uuid; l public.leads%rowtype; d public.closed_business%rowtype; fields jsonb; expected jsonb; r jsonb;
begin
 select id into m from public.profiles where active and is_super_admin limit 1;
 select id into a from public.profiles where active and role='agent' and division='vivid_life' and not archived limit 1;
 select id into foreign_agent from public.profiles where active and role='agent' and division='legacy_life' and not archived limit 1;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',m,'aal','aal2','session_id','edit-master-test')::text,true);
 perform public.book_access('set','492816');perform public.book_grid('save',a,'__edit_test__','Final Expense',80,75,'2026-01-01');
 insert into public.leads(first_name,last_name,phone,division,status,assigned_to,csv_headers,csv_values) values('Edit','Test','5551234567','vivid_life','closed',a,'[]','[]') returning * into l;
 insert into public.closed_business(lead_id,agent_id,carrier,policy_type,monthly_premium,application_date) values(l.id,a,'__edit_test__','Final Expense',100,'2026-10-02') returning * into d;
 expected:=jsonb_build_object('carrier',d.carrier,'policy_type',d.policy_type,'monthly_premium',d.monthly_premium,'application_date',d.application_date,'policy_number',d.policy_number,'notes',d.notes);fields:=expected||jsonb_build_object('monthly_premium',150);
 perform set_config('request.jwt.claims',jsonb_build_object('sub',foreign_agent,'aal','aal2','session_id','edit-foreign-test')::text,true);
 begin perform public.correct_closed_deal(d.id,expected,fields,'Test correction');raise exception 'Foreign deal edit allowed';exception when insufficient_privilege then null;end;
 begin perform public.correct_closed_lead(d.id,l.updated_at,'{"first_name":"Forbidden"}', 'Test correction');raise exception 'Foreign client edit allowed';exception when insufficient_privilege then null;end;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'aal','aal2','session_id','edit-agent-test')::text,true);
 perform public.correct_closed_lead(d.id,l.updated_at,'{"first_name":"Corrected"}', 'Client confirmed name');
 if (select first_name from public.leads where id=l.id)<>'Corrected' then raise exception 'Own client edit failed';end if;
 if not exists(select 1 from public.lead_corrections where deal_id=d.id and actor_id=a) then raise exception 'History missing';end if;
 perform public.correct_closed_deal(d.id,expected,fields,'Corrected premium');
 if (select annual_premium from public.closed_business where id=d.id)<>1800 then raise exception 'Annual premium not updated';end if;
 perform public.book_access('set','492816');r:=public.book_data(1,'__edit_test__');if (r->>'estimated_advance')::numeric<>1080 then raise exception 'Advance not updated: %',r;end if;
 begin perform public.correct_closed_deal(d.id,expected,fields,'Stale edit');raise exception 'Stale edit allowed';exception when sqlstate 'PT409' then null;end;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'aal','aal1','session_id','edit-agent-test')::text,true);
 begin perform public.correct_closed_deal(d.id,fields,expected,'MFA bypass test');raise exception 'MFA bypass';exception when insufficient_privilege then null;end;
 if has_function_privilege('anon','public.correct_closed_deal(uuid,jsonb,jsonb,text)','execute') then raise exception 'Anonymous edit enabled';end if;
end $$;
rollback;
