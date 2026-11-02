-- Synthetic fixtures only. Execute inside BEGIN / ROLLBACK; never commit.
do $test$
declare owner_id uuid; owner_session uuid; leader uuid:=gen_random_uuid(); member uuid:=gen_random_uuid(); scoped uuid:=gen_random_uuid(); outsider uuid:=gen_random_uuid(); portable uuid:=gen_random_uuid();
 lead_open uuid:=gen_random_uuid(); lead_closed uuid:=gen_random_uuid(); member_lead uuid:=gen_random_uuid(); admin_lead uuid:=gen_random_uuid(); portable_lead uuid:=gen_random_uuid();
 policy_id uuid:=gen_random_uuid(); profile_id uuid:=gen_random_uuid(); deal_id uuid:=gen_random_uuid(); fresh_session uuid:=gen_random_uuid();
 before_leads jsonb; before_client jsonb; before_crm jsonb; before_deal jsonb; before_closed jsonb; before_team jsonb; preview jsonb; result jsonb; denied boolean;
begin
 select p.id,s.id into owner_id,owner_session from public.profiles p join auth.sessions s on s.user_id=p.id
 where p.role='admin' and p.is_super_admin and p.active and not p.archived and (s.not_after is null or s.not_after>now()) limit 1;
 if owner_id is null then raise exception 'A live owner session is required for the rollback-only test';end if;
 insert into auth.users(id,email) select x,x||'@example.invalid' from unnest(array[leader,member,scoped,outsider,portable]) x;
 insert into public.profiles(id,full_name,role,active,division,is_team_leader)
 values(leader,'Disable fixture leader','agent',true,'vivid_life',true),(member,'Disable fixture member','agent',true,'vivid_life',false),
 (scoped,'Disable fixture admin','admin',true,'vivid_life',false),(outsider,'Disable fixture other agency','agent',true,'legacy_life',false),
 (portable,'Disable fixture portable','agent',true,'legacy_life',false);
 update public.profiles set team_leader_id=leader where id=member;
 insert into auth.sessions(id,user_id,aal,created_at) select x,x,'aal2',now() from unnest(array[leader,member,scoped,outsider,portable]) x;
 insert into private.portal_onboarding_waivers(user_id,reason,granted_by) select x,'Rollback-only test',owner_id from unnest(array[leader,member,portable]) x;
 insert into public.leads(id,first_name,last_name,division,status,assigned_to,call_notes,lead_type)
 values(lead_open,'Synthetic','Open','vivid_life','assigned',leader,'Keep the notes','Fixture folder'),
 (lead_closed,'Synthetic','Closed','vivid_life','closed',leader,'Keep closed notes','Fixture folder'),
 (member_lead,'Synthetic','Member','vivid_life','assigned',member,'Unchanged member notes','Fixture folder'),
 (admin_lead,'Synthetic','Admin','vivid_life','assigned',scoped,'Unchanged admin notes','Fixture folder'),
 (portable_lead,'Synthetic','Portable','legacy_life','assigned',portable,'Keep original agency','Fixture folder');
 insert into private.agent_portable_leads(lead_id,agent_id,origin_division) values(portable_lead,portable,'legacy_life');
 update public.profiles set division='vivid_life' where id=portable;
 insert into private.book_crm_profiles(id,agent_id,details) values(profile_id,leader,'{"client_name":"Synthetic client"}');
 insert into private.book_crm_clients(id,profile_id,agent_id,client_name,phone,carrier,policy_type,monthly_payment)
 values(policy_id,profile_id,leader,'Synthetic client','2025550101','Fixture carrier','term',100);
 perform set_config('lld.crm_client_id',policy_id::text,true);
 insert into public.closed_business(id,agent_id,lead_id,carrier,policy_type,monthly_premium,application_date) values(deal_id,leader,lead_closed,'Fixture carrier','term',100,current_date);
 perform set_config('lld.crm_client_id','',true);
 select jsonb_agg(to_jsonb(l) order by l.id) into before_leads from public.leads l where id=any(array[lead_open,lead_closed,member_lead,admin_lead,portable_lead]);
 select to_jsonb(l) into before_closed from public.leads l where id=lead_closed;
 select to_jsonb(c) into before_client from private.book_crm_clients c where id=policy_id;
 select to_jsonb(c) into before_crm from private.book_crm_profiles c where id=profile_id;
 select to_jsonb(d) into before_deal from public.closed_business d where id=deal_id;
 select to_jsonb(p) into before_team from public.profiles p where id=member;
 if has_function_privilege('anon','public.disable_portal_account(uuid,boolean,text,text)','execute')
 or has_function_privilege('anon','private.disable_portal_account(uuid,boolean,text,text)','execute')
 or has_function_privilege('anon','public.account_disable_preview(uuid)','execute')
 or has_function_privilege('authenticated','private.account_disable_target(uuid)','execute') then raise exception 'Unsafe RPC grants';end if;
 set local role authenticated;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',owner_id,'role','authenticated','aal','aal1','session_id',owner_session)::text,true);
 denied:=false;begin perform public.disable_portal_account(leader);exception when sqlstate 'PT403' then denied:=true;end;if not denied then raise exception 'Password-only disable admitted';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',scoped,'role','authenticated','aal','aal2','session_id',scoped)::text,true);
 preview:=public.account_disable_preview(leader);if (preview->>'open_leads')::int<>1 or (preview->>'closed_deals')::int<>1 then raise exception 'Preview counts incorrect';end if;
 denied:=false;begin perform public.disable_portal_account(outsider);exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'Foreign agency disable admitted';end if;
 denied:=false;begin perform public.disable_portal_account(scoped);exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'Self-disable admitted';end if;
 denied:=false;begin perform public.disable_portal_account(owner_id);exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'Master disable admitted';end if;
 preview:=public.account_disable_preview(portable);if (preview->>'can_reclaim')::boolean then raise exception 'Foreign source reclaim offered';end if;
 denied:=false;begin perform public.disable_portal_account(portable,true);exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'Foreign source reclaim admitted';end if;
 reset role;
 if not (select active from public.profiles where id=portable) or not exists(select 1 from public.leads where id=portable_lead and assigned_to=portable) then raise exception 'Rejected reclaim partially mutated account';end if;
 set local role authenticated;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',member,'role','authenticated','aal','aal2','session_id',member)::text,true);
 denied:=false;begin perform public.disable_portal_account(leader);exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'Agent disabled an account';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',owner_id,'role','authenticated','aal','aal2','session_id',owner_session)::text,true);
 denied:=false;begin perform public.disable_portal_account(leader,true,'admin','vivid_life');exception when raise_exception then denied:=sqlerrm like '%account changed%';end;if not denied then raise exception 'Stale role accepted';end if;
 denied:=false;begin perform public.disable_portal_account(leader,true,'agent','legacy_life');exception when raise_exception then denied:=sqlerrm like '%account changed%';end;if not denied then raise exception 'Stale agency accepted';end if;
 result:=public.disable_portal_account(leader);
 if result->>'mode'<>'keep_everything' or (result->>'reclaimed_leads')::int<>0 then raise exception 'Unsafe default';end if;
 reset role;
 if (select active or archived or not is_team_leader from public.profiles where id=leader) then raise exception 'Disable changed team/archived state';end if;
 if before_leads is distinct from (select jsonb_agg(to_jsonb(l) order by l.id) from public.leads l where id=any(array[lead_open,lead_closed,member_lead,admin_lead,portable_lead])) then raise exception 'Keep mode changed a lead';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',leader,'role','authenticated','aal','aal2','session_id',leader)::text,true);
 if private.verified_portal_session() then raise exception 'Disabled session still valid';end if;
 set local role authenticated;
 denied:=false;begin perform public.require_portal_onboarding();exception when sqlstate 'PT403' then denied:=true;end;if not denied then raise exception 'Disabled account passed portal guard';end if;
 if exists(select 1 from public.leads where id=lead_open) then raise exception 'Disabled account can read leads through RLS';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',owner_id,'role','authenticated','aal','aal2','session_id',owner_session)::text,true);
 denied:=false;begin perform public.disable_portal_account(leader,true);exception when raise_exception then denied:=sqlerrm like '%already disabled%';end;if not denied then raise exception 'Duplicate disable reclaimed leads';end if;
 perform public.enable_agent(leader);
 reset role;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',leader,'role','authenticated','aal','aal2','session_id',leader)::text,true);
 if private.verified_portal_session() then raise exception 'Old session revived on enable';end if;
 insert into auth.sessions(id,user_id,aal,created_at) values(fresh_session,leader,'aal2',now());
 perform set_config('request.jwt.claims',jsonb_build_object('sub',leader,'role','authenticated','aal','aal2','session_id',fresh_session)::text,true);
 if not private.verified_portal_session() then raise exception 'Fresh login denied after enable';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',owner_id,'role','authenticated','aal','aal2','session_id',owner_session)::text,true);
 set local role authenticated;
 perform public.disable_agent(leader);
 reset role;
 if before_leads is distinct from (select jsonb_agg(to_jsonb(l) order by l.id) from public.leads l where id=any(array[lead_open,lead_closed,member_lead,admin_lead,portable_lead])) then raise exception 'Legacy disable reclaimed leads';end if;
 set local role authenticated;
 perform public.enable_agent(leader);
 result:=public.disable_portal_account(leader,true,'agent','vivid_life');
 if (result->>'reclaimed_leads')::int<>1 then raise exception 'Wrong reclaim count';end if;
 reset role;
 if not exists(select 1 from public.leads where id=lead_open and status='unassigned' and assigned_to is null and assigned_at is null and division='vivid_life' and call_notes='Keep the notes' and lead_type='Fixture folder') then raise exception 'Reclaim lost lead content/source';end if;
 if before_closed is distinct from (select to_jsonb(l) from public.leads l where id=lead_closed) then raise exception 'Closed lead changed';end if;
 if before_client is distinct from (select to_jsonb(c) from private.book_crm_clients c where id=policy_id)
 or before_crm is distinct from (select to_jsonb(c) from private.book_crm_profiles c where id=profile_id)
 or before_deal is distinct from (select to_jsonb(d) from public.closed_business d where id=deal_id) then raise exception 'Client or sales history changed';end if;
 if before_team is distinct from (select to_jsonb(p) from public.profiles p where id=member) or not exists(select 1 from public.leads where id=member_lead and assigned_to=member) then raise exception 'Team member or their leads changed';end if;
 if not exists(select 1 from public.audit_logs where entity_id=leader::text and actor_id=owner_id and details->>'mode'='return_open_leads' and (details->>'reclaimed_leads')::int=1) then raise exception 'Reclaim audit missing';end if;
 set local role authenticated;
 perform public.set_scoped_admin_access(scoped,false);
 reset role;
 if not exists(select 1 from public.leads where id=admin_lead and assigned_to=scoped) then raise exception 'Legacy admin disable changed assignments';end if;
 set local role authenticated;
 perform public.set_scoped_admin_access(scoped,true);
 result:=public.disable_portal_account(scoped,true,'admin','vivid_life');
 if (result->>'reclaimed_leads')::int<>1 then raise exception 'Admin personal reclaim failed';end if;
 reset role;
 if not exists(select 1 from public.leads where id=member_lead and assigned_to=member) or not (select active from public.profiles where id=member) then raise exception 'Admin disable affected whole agency';end if;
 -- Keeping portable leads requires no new cross-agency powers.
 insert into auth.sessions(id,user_id,aal,created_at) values(gen_random_uuid(),scoped,'aal2',now());
 set local role authenticated;
 perform public.set_scoped_admin_access(scoped,true);
 reset role;
 select id into fresh_session from auth.sessions where user_id=scoped and not_after is null limit 1;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',scoped,'role','authenticated','aal','aal2','session_id',fresh_session)::text,true);
 set local role authenticated;
 result:=public.disable_portal_account(portable,false);
 reset role;
 if not exists(select 1 from public.leads where id=portable_lead and assigned_to=portable and division='legacy_life') or not exists(select 1 from private.agent_portable_leads where lead_id=portable_lead) then raise exception 'Keep mode lost portable assignment';end if;
end $test$;
select 'PASS: keep/reclaim, record snapshots, legacy defaults, sessions/RLS, re-enable, source scopes, team/admin isolation, stale/duplicate rejection and audit' as result;
