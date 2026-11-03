-- Rollback-only synthetic leads/clients/deals. Existing account identities are
-- referenced to exercise this explicitly requested attribution correction.
begin;
do $test$
declare
 owner_id uuid; owner_session uuid; actor uuid; lead_id uuid; profile_id uuid; client_id uuid; deal_id uuid;
 source_agency text:='owner'; expected text; sale_time timestamptz; row_num integer; label text; result jsonb; denied boolean;
 nathan uuid:='f411ecbb-2477-4cb6-902f-a69db6b6edd6'; dylan uuid:='8c14394a-ad5b-48f6-84a2-2cfa6dc23378'; adolfo uuid:='7a24126c-5892-4568-80ed-de57215be22d';
 onyx text:='division_1bd8c26ef4e9400c866e81425403b721';
begin
 select p.id,s.id into owner_id,owner_session from public.profiles p join auth.sessions s on s.user_id=p.id where p.is_super_admin and p.active and not p.archived and (s.not_after is null or s.not_after>now()) limit 1;
 if owner_id is null then raise exception 'Live owner session required';end if;
 if not exists(select 1 from public.profiles where id=nathan and role='admin' and division=onyx and active and not archived) then raise exception 'Nathan role/agency wrong';end if;
 if (select count(*) from public.profiles where id in(dylan,adolfo) and role='agent' and division='vivid_life' and active and not archived)<>2 then raise exception 'Dylan/Adolfo role/agency wrong';end if;
 for row_num in 1..7 loop
  actor:=case when row_num in (1,2) then nathan when row_num in(3,4,5) then dylan else adolfo end;
  sale_time:=case row_num when 1 then timestamptz '2026-09-15 12:00 America/Detroit' when 3 then timestamptz '2026-10-31 23:59:59 America/Detroit' when 4 then timestamptz '2026-11-01 00:00 America/Detroit' when 6 then timestamptz '2026-10-31 23:59:59 America/Detroit' else now()+interval '1 day' end;
  expected:=case when actor=nathan then onyx when sale_time>=timestamptz '2026-11-01 00:00 America/Detroit' then 'vivid_life' else source_agency end;
  lead_id:=gen_random_uuid();profile_id:=gen_random_uuid();client_id:=gen_random_uuid();deal_id:=gen_random_uuid();
  perform set_config('request.jwt.claims','{}',true);
  insert into public.leads(id,first_name,last_name,phone,division,status) values(lead_id,'Synthetic','Credit test','2025550199',source_agency,'unassigned');
  insert into private.agent_portable_leads(lead_id,agent_id,origin_division) values(lead_id,actor,source_agency);
  update public.leads set assigned_to=actor,status='closed' where id=lead_id;
  insert into private.book_crm_profiles(id,agent_id,details) values(profile_id,actor,'{"client_name":"Synthetic credit test"}');
  insert into private.book_crm_clients(id,profile_id,agent_id,client_name,phone,carrier,policy_type,monthly_payment) values(client_id,profile_id,actor,'Synthetic credit test','2025550199','Fixture','term',100);
  perform set_config('lld.crm_client_id',client_id::text,true);
  insert into public.closed_business(id,lead_id,agent_id,carrier,policy_type,monthly_premium,application_date,created_at) values(deal_id,lead_id,actor,'Fixture','term',100,(sale_time at time zone 'America/Detroit')::date,sale_time);
  perform set_config('lld.crm_client_id','',true);
  if (select division from public.chat_messages where source_deal_id=deal_id) is distinct from expected then raise exception 'New sale credit incorrect for scenario %',row_num;end if;
  if (select division from public.leads where id=lead_id) is distinct from source_agency then raise exception 'Lead origin changed';end if;
 end loop;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',owner_id,'session_id',owner_session,'role','authenticated','aal','aal2')::text,true);
 result:=private.leaderboard_period(onyx,'month',null);
 if not exists(select 1 from jsonb_array_elements(result->'rankings') r where r->>'agent_id'=nathan::text and (r->>'ap')::numeric>=6057.60) then raise exception 'Nathan November Onyx production missing';end if;
 result:=private.leaderboard_period('vivid_life','month',null);
 if not exists(select 1 from jsonb_array_elements(result->'rankings') r where r->>'agent_id'=dylan::text and (r->>'ap')::numeric>=3799.20) then raise exception 'Dylan November Vivid production missing';end if;
 if exists(select 1 from jsonb_array_elements(result->'rankings') r where r->>'agent_id'=nathan::text and (r->>'ap')::numeric>0) then raise exception 'Nathan remains credited to Vivid';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',dylan,'session_id',gen_random_uuid(),'role','authenticated','aal','aal1')::text,true);
 denied:=false;begin perform private.leaderboard_period(onyx,'month',null);exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'Unverified agent session admitted';end if;
 perform set_config('request.jwt.claims','{}',true);
 denied:=false;begin perform private.leaderboard_period(onyx,'month',null);exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'Anonymous session admitted';end if;
end $test$;
rollback;
select 'PASS: Nathan all dates, Dylan/Adolfo month boundary and future deals, chat credit, leaderboard credit, preserved source/roles, and verified-session restrictions; all fixtures rolled back' result;
