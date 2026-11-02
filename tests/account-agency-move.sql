-- Synthetic fixtures only; execute inside BEGIN / ROLLBACK.
do $test$
declare source_div text:='fixture_move_'||gen_random_uuid()::text; owner_id uuid; owner_session uuid; admin_id uuid:=gen_random_uuid(); agent uuid:=gen_random_uuid(); disabled uuid:=gen_random_uuid(); leader uuid:=gen_random_uuid(); member uuid:=gen_random_uuid();
 open_id uuid:=gen_random_uuid(); closed_id uuid:=gen_random_uuid(); portable_id uuid:=gen_random_uuid(); agent_lead uuid:=gen_random_uuid(); other_lead uuid:=gen_random_uuid();
 client_id uuid:=gen_random_uuid(); crm_id uuid:=gen_random_uuid(); deal_id uuid:=gen_random_uuid(); pending_id uuid; completed_id uuid; fresh_session uuid:=gen_random_uuid();
 before_leads jsonb; before_clients jsonb; before_deals jsonb; before_waivers jsonb; before_other jsonb; result jsonb; denied boolean;
begin
 select p.id,s.id into owner_id,owner_session from public.profiles p join auth.sessions s on s.user_id=p.id
 where p.is_super_admin and p.role='admin' and p.active and not p.archived and (s.not_after is null or s.not_after>now()) limit 1;
 if owner_id is null then raise exception 'A live owner session is required for this rollback-only test';end if;
 perform set_config('request.jwt.claims','{}',true);
 insert into public.divisions(id,name) values(source_div,'Synthetic source agency');
 insert into auth.users(id,email) select x,x||'@example.invalid' from unnest(array[admin_id,agent,disabled,leader,member]) x;
 insert into public.profiles(id,full_name,role,active,division,is_team_leader) values
 (admin_id,'Synthetic admin','admin',true,source_div,false),(agent,'Synthetic agent','agent',true,source_div,false),
 (disabled,'Synthetic disabled admin','admin',false,'vivid_life',false),(leader,'Synthetic leader','agent',true,source_div,true),(member,'Synthetic member','agent',true,source_div,false);
 update public.profiles set team_leader_id=leader where id=member;
 insert into private.master_admin_accounts(user_id,granted_by) values(admin_id,owner_id);
 insert into private.admin_division_access(user_id,division) values(admin_id,'owner'),(admin_id,'vivid_life');
 insert into private.extra_lead_read_access(user_id,division) values(admin_id,'owner');
 insert into auth.sessions(id,user_id,aal,created_at) values(admin_id,admin_id,'aal2',now()),(agent,agent,'aal2',now());
 insert into private.portal_onboarding_waivers(user_id,reason,granted_by) values(admin_id,'Rollback fixture',owner_id),(agent,'Rollback fixture',owner_id);
 insert into public.leads(id,first_name,division,status,assigned_to,call_notes,lead_type) values
 (open_id,'Synthetic open',source_div,'assigned',admin_id,'Keep notes','Fixture'),
 (closed_id,'Synthetic closed',source_div,'closed',admin_id,'Keep closed notes','Fixture'),
 (portable_id,'Synthetic portable','owner','assigned',admin_id,'Keep source agency','Fixture'),
 (agent_lead,'Synthetic agent lead',source_div,'assigned',agent,'Keep agent notes','Fixture'),
 (other_lead,'Synthetic other lead',source_div,'assigned',member,'Unrelated lead','Fixture');
 insert into private.book_crm_profiles(id,agent_id,details) values(crm_id,admin_id,'{"client_name":"Synthetic client"}');
 insert into private.book_crm_clients(id,profile_id,agent_id,client_name,phone,carrier,policy_type,monthly_payment) values(client_id,crm_id,admin_id,'Synthetic client','2025550101','Fixture carrier','term',100);
 perform set_config('lld.crm_client_id',client_id::text,true);
 insert into public.closed_business(id,agent_id,lead_id,carrier,policy_type,monthly_premium,application_date) values(deal_id,admin_id,closed_id,'Fixture carrier','term',100,current_date);
 perform set_config('lld.crm_client_id','',true);
 perform set_config('request.jwt.claims',jsonb_build_object('sub',agent,'session_id',agent,'role','authenticated','aal','aal2')::text,true);
 insert into public.lead_requests(lead_type,quantity,note) values('Fixture',10,'Synthetic pending request') returning id into pending_id;
 insert into public.lead_requests(lead_type,quantity,note) values('Fixture',10,'Synthetic completed request') returning id into completed_id;
 update public.lead_requests set status='completed' where id=completed_id;
 select jsonb_agg(to_jsonb(l) order by id) into before_leads from public.leads l where id=any(array[open_id,closed_id,portable_id,agent_lead,other_lead]);
 select to_jsonb(c) into before_clients from private.book_crm_clients c where id=client_id;
 select to_jsonb(d) into before_deals from public.closed_business d where id=deal_id;
 select jsonb_agg(to_jsonb(w) order by user_id) into before_waivers from private.portal_onboarding_waivers w where user_id=any(array[admin_id,agent]);
 select to_jsonb(p) into before_other from public.profiles p where id=member;
 if has_function_privilege('anon','public.move_account_as_agent(uuid,text,text,text)','execute') or has_function_privilege('anon','private.account_agent_move_preview(uuid)','execute') then raise exception 'Anonymous move exposed';end if;
 set local role authenticated;
 denied:=false;begin perform public.account_agent_move_preview(admin_id);exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'Agent preview admitted';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',admin_id,'session_id',admin_id,'role','authenticated','aal','aal2')::text,true);
 denied:=false;begin perform public.move_account_as_agent(agent,'vivid_life','agent',source_div);exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'Master gained Super Master role controls';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',owner_id,'session_id',owner_session,'role','authenticated','aal','aal1')::text,true);
 denied:=false;begin perform public.account_agent_move_preview(admin_id);exception when sqlstate 'PT403' then denied:=true;end;if not denied then raise exception 'Password-only move admitted';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',owner_id,'session_id',owner_session,'role','authenticated','aal','aal2')::text,true);
 result:=public.account_agent_move_preview(admin_id);if (result->>'open_leads')::int<>2 or (result->>'deals')::int<>1 or not (result->>'is_master_admin')::boolean then raise exception 'Move preview incorrect';end if;
 denied:=false;begin perform public.move_account_as_agent(owner_id,'vivid_life','admin','vivid_life');exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'Super Master demotion admitted';end if;
 denied:=false;begin perform public.move_account_as_agent(leader,'vivid_life','agent',source_div);exception when raise_exception then denied:=sqlerrm like '%team members%';end;if not denied then raise exception 'Leader abandoned team';end if;
 denied:=false;begin perform public.move_account_as_agent(admin_id,'vivid_life','agent',source_div);exception when raise_exception then denied:=sqlerrm like '%account changed%';end;if not denied then raise exception 'Stale role accepted';end if;
 denied:=false;begin perform public.move_account_as_agent(admin_id,'owner','admin',source_div);exception when raise_exception then denied:=true;end;if not denied then raise exception 'Owner destination accepted';end if;
 result:=public.move_account_as_agent(admin_id,'vivid_life','admin',source_div);
 if result->>'role'<>'agent' or (result->>'all_leads_kept')::int<>3 or (result->>'deals_kept')::int<>1 or not (result->>'sign_in_again')::boolean then raise exception 'Admin move incomplete';end if;
 perform public.move_account_as_agent(agent,'vivid_life','agent',source_div);
 perform public.move_account_as_agent(disabled,'vivid_life','admin','vivid_life');
 denied:=false;begin perform public.move_account_as_agent(admin_id,'vivid_life','admin',source_div);exception when raise_exception then denied:=sqlerrm like '%account changed%';end;if not denied then raise exception 'Duplicate/stale move admitted';end if;
 reset role;
 if before_leads is distinct from (select jsonb_agg(to_jsonb(l) order by id) from public.leads l where id=any(array[open_id,closed_id,portable_id,agent_lead,other_lead]))
 or before_clients is distinct from (select to_jsonb(c) from private.book_crm_clients c where id=client_id)
 or before_deals is distinct from (select to_jsonb(d) from public.closed_business d where id=deal_id)
 or before_waivers is distinct from (select jsonb_agg(to_jsonb(w) order by user_id) from private.portal_onboarding_waivers w where user_id=any(array[admin_id,agent]))
 or before_other is distinct from (select to_jsonb(p) from public.profiles p where id=member) then raise exception 'Business records, waivers or other account changed';end if;
 if exists(select 1 from private.admin_division_access where user_id=admin_id) or exists(select 1 from private.extra_lead_read_access where user_id=admin_id) or exists(select 1 from private.master_admin_accounts where user_id=admin_id) then raise exception 'Elevated access retained';end if;
 if (select count(*) from public.profiles where id=any(array[admin_id,agent]) and role='agent' and active and not archived and not is_team_leader and team_leader_id is null and division='vivid_life' and created_by_admin_id=owner_id)<>2 then raise exception 'Destination or regular-agent role incorrect';end if;
 if not exists(select 1 from public.profiles where id=disabled and not active and not archived and role='agent') then raise exception 'Disabled account reactivated';end if;
 if (select count(*) from private.agent_portable_leads where lead_id=any(array[open_id,closed_id,portable_id,agent_lead]))<>4 then raise exception 'Portable permission missing';end if;
 if not exists(select 1 from public.lead_requests where id=pending_id and division='vivid_life' and recipient_id=owner_id) or not exists(select 1 from public.lead_requests where id=completed_id and division=source_div and status='completed') then raise exception 'Pending request routing or completed history incorrect';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',admin_id,'session_id',admin_id,'role','authenticated','aal','aal2')::text,true);
 if private.verified_portal_session() then raise exception 'Old admin session still valid';end if;
 insert into auth.sessions(id,user_id,aal,created_at) values(fresh_session,admin_id,'aal2',now());
 perform set_config('request.jwt.claims',jsonb_build_object('sub',admin_id,'session_id',fresh_session,'role','authenticated','aal','aal2')::text,true);
 set local role authenticated;
 if cardinality(public.my_admin_divisions())<>0 then raise exception 'Regular agent retains admin agencies';end if;
 if (select count(*) from public.leads where id=any(array[open_id,closed_id,portable_id]))<>3 or exists(select 1 from public.leads where id=other_lead) then raise exception 'Agent lost personal leads or gained agency access';end if;
 reset role;
end $test$;
select 'PASS: Super Master-only move/demotion, full record snapshots, portable leads, removed grants, pending routing, disabled/same-agency handling, stale/team checks and session/RLS boundaries' as result;
