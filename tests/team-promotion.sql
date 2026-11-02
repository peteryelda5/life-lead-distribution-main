-- Synthetic fixtures only. Execute inside BEGIN / ROLLBACK, never commit.
do $test$
declare owner_id uuid; leader uuid:=gen_random_uuid(); member uuid:=gen_random_uuid(); disabled uuid:=gen_random_uuid(); archived_member uuid:=gen_random_uuid();
 outsider uuid:=gen_random_uuid(); scoped uuid:=gen_random_uuid(); second_leader uuid:=gen_random_uuid(); sid uuid; other_sid uuid:=gen_random_uuid();
 leader_lead uuid:=gen_random_uuid(); member_lead uuid:=gen_random_uuid(); other_lead uuid:=gen_random_uuid(); policy_id uuid:=gen_random_uuid(); profile_id uuid:=gen_random_uuid();
 deal_id uuid:=gen_random_uuid(); pending_id uuid; completed_id uuid; target text; destination text; fresh_name text:='Promotion fixture '||gen_random_uuid();
 ids uuid[]; result jsonb; preview jsonb; before_leads jsonb; before_client jsonb; before_deal jsonb; before_profile jsonb; denied boolean; n bigint;
begin
 -- Reuse a live owner identity/session only inside this rolled-back SQL test.
 -- The production constraint correctly forbids creating another Master Admin.
 select p.id,s.id into owner_id,sid from public.profiles p join auth.sessions s on s.user_id=p.id
 where p.role='admin' and p.is_super_admin and p.active and not p.archived and (s.not_after is null or s.not_after>now()) limit 1;
 if owner_id is null then raise exception 'A live owner session is required for this rollback-only test';end if;
 ids:=array[member,disabled,archived_member];
 insert into auth.users(id,email) select x,x||'@example.invalid' from unnest(array[leader,member,disabled,archived_member,outsider,scoped,second_leader]) x;
 insert into public.profiles(id,full_name,role,active,division,is_super_admin,is_team_leader)
 values(scoped,'Promotion test scoped','admin',true,'vivid_life',false,false),
 (leader,'Promotion test leader','agent',true,'vivid_life',false,true),(second_leader,'Promotion test empty leader','agent',true,'vivid_life',false,true),
 (member,'Promotion test member','agent',true,'vivid_life',false,false),(disabled,'Promotion test disabled','agent',false,'vivid_life',false,false),
 (archived_member,'Promotion test archived','agent',false,'vivid_life',false,false),(outsider,'Promotion test outsider','agent',true,'vivid_life',false,false);
 update public.profiles set team_leader_id=leader where id=any(ids);
 update public.profiles set archived=true where id=archived_member;
 insert into auth.sessions(id,user_id,aal,created_at) values(other_sid,scoped,'aal2',now());
 insert into private.portal_onboarding_waivers(user_id,reason,granted_by) values(member,'Rollback-only test',owner_id),(leader,'Rollback-only test',owner_id);
 -- Fixtures exercise the real lead/client triggers, with fictional data.
 insert into public.leads(id,first_name,last_name,division,status,assigned_to,call_notes,lead_type)
 values(leader_lead,'Synthetic','Leader','vivid_life','assigned',leader,'Keep this note','Fixture folder'),
 (member_lead,'Synthetic','Member','vivid_life','assigned',member,'Keep member note','Fixture folder'),
 (other_lead,'Synthetic','Other','vivid_life','assigned',outsider,'Unrelated record','Other folder');
 insert into private.book_crm_profiles(id,agent_id,details) values(profile_id,leader,'{"client_name":"Synthetic client"}');
 insert into private.book_crm_clients(id,profile_id,agent_id,client_name,phone,carrier,policy_type,monthly_payment)
 values(policy_id,profile_id,leader,'Synthetic client','2025550101','Fixture carrier','term',100);
 perform set_config('lld.crm_client_id',policy_id::text,true);
 insert into public.closed_business(id,agent_id,carrier,policy_type,monthly_premium,application_date) values(deal_id,leader,'Fixture carrier','term',100,current_date);
 perform set_config('lld.crm_client_id','',true);
 -- Existing pending requests must follow the team; completed history stays put.
 perform set_config('request.jwt.claims',jsonb_build_object('sub',member,'role','authenticated','aal','aal2','session_id',sid)::text,true);
 -- The route validates session binding; use the member's own fixture session.
 insert into auth.sessions(id,user_id,aal,created_at) values(member,member,'aal2',now());
 perform set_config('request.jwt.claims',jsonb_build_object('sub',member,'role','authenticated','aal','aal2','session_id',member)::text,true);
 insert into public.lead_requests(lead_type,quantity,note) values('Fixture folder',10,'Fixture pending') returning id into pending_id;
 insert into public.lead_requests(lead_type,quantity,note) values('Fixture folder',10,'Fixture completed') returning id into completed_id;
 update public.lead_requests set status='completed' where id=completed_id;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',owner_id,'role','authenticated','aal','aal2','session_id',sid)::text,true);
 select jsonb_agg(to_jsonb(l) order by l.id) into before_leads from public.leads l where id=any(array[leader_lead,member_lead,other_lead]);
 select to_jsonb(c) into before_client from private.book_crm_clients c where id=policy_id;
 select to_jsonb(c) into before_profile from private.book_crm_profiles c where id=profile_id;
 select to_jsonb(d) into before_deal from public.closed_business d where id=deal_id;
 -- Dormant grants must not become broad admin access after promotion.
 insert into private.admin_division_access(user_id,division) values(leader,'legacy_life');
 insert into private.extra_lead_read_access(user_id,division) values(leader,'owner');
 preview:=public.team_admin_promotion_preview(leader);
 if jsonb_array_length(preview->'members')<>3 or (preview->>'open_leads')::int<>2 or (preview->>'closed_deals')::int<>1 then raise exception 'Preview omitted team or retained records';end if;
 if exists(select 1 from jsonb_array_elements(preview->'agencies') a where a->>'id'='owner') then raise exception 'Unsafe destination offered';end if;
 if not exists(select 1 from jsonb_array_elements(preview->'agencies') a where a->>'id'='vivid_life') then raise exception 'Current agency missing from preview';end if;
 -- Authenticated wrapper privileges are intentional; anonymous calls are denied.
 if has_function_privilege('anon','public.promote_team_leader_with_agency(uuid,text,uuid[],text,text)','execute') or has_function_privilege('anon','private.team_admin_promotion_preview(uuid)','execute') then raise exception 'Anonymous RPC exposure';end if;
 set local role authenticated;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',owner_id,'role','authenticated','aal','aal1','session_id',sid)::text,true);
 denied:=false;begin perform public.team_admin_promotion_preview(leader);exception when sqlstate 'PT403' then denied:=true;end;if not denied then raise exception 'Password-only owner admitted';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',scoped,'role','authenticated','aal','aal2','session_id',other_sid)::text,true);
 denied:=false;begin perform public.promote_team_leader_with_agency(leader,'vivid_life',ids,null,fresh_name);exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'Scoped admin promoted a team';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',member,'role','authenticated','aal','aal2','session_id',member)::text,true);
 denied:=false;begin perform public.team_admin_promotion_preview(leader);exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'Agent read owner preview';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',owner_id,'role','authenticated','aal','aal2','session_id',sid)::text,true);
 denied:=false;begin perform public.promote_team_leader_with_agency(leader,'vivid_life',array[member],null,fresh_name);exception when raise_exception then denied:=sqlerrm like '%team changed%';end;if not denied then raise exception 'Stale roster accepted';end if;
 denied:=false;begin perform public.promote_team_leader_with_agency(leader,'legacy_life',ids,null,fresh_name);exception when raise_exception then denied:=sqlerrm like '%agency changed%';end;if not denied then raise exception 'Stale agency accepted';end if;
 denied:=false;begin perform public.promote_team_leader_with_agency(leader,'vivid_life',ids,'owner',null);exception when raise_exception then denied:=sqlerrm like '%active agency%';end;if not denied then raise exception 'Master agency allowed';end if;
 result:=public.promote_team_leader_with_agency(leader,'vivid_life',ids,null,fresh_name);destination:=result->>'division';
 if (result->>'members_moved')::int<>3 or (result->>'pending_requests_moved')::int<>1 then raise exception 'Incomplete transfer result';end if;
 reset role;
 if not exists(select 1 from public.profiles where id=leader and role='admin' and not is_super_admin and not is_team_leader and division=destination) then raise exception 'Wrong promoted role';end if;
 if (select count(*) from public.profiles where id=any(ids) and role='agent' and division=destination and team_leader_id is null and created_by_admin_id=leader)<>3 then raise exception 'Team not attached to new admin';end if;
 if exists(select 1 from public.profiles where id=disabled and active) or not exists(select 1 from public.profiles where id=archived_member and archived and not active) then raise exception 'Disabled or archived account reactivated';end if;
 if exists(select 1 from public.profiles where id=outsider and division<>'vivid_life') then raise exception 'Unrelated agent moved';end if;
 if before_leads is distinct from (select jsonb_agg(to_jsonb(l) order by l.id) from public.leads l where id=any(array[leader_lead,member_lead,other_lead])) then raise exception 'Lead content, ownership or source changed';end if;
 if before_client is distinct from (select to_jsonb(c) from private.book_crm_clients c where id=policy_id) or before_profile is distinct from (select to_jsonb(c) from private.book_crm_profiles c where id=profile_id) or before_deal is distinct from (select to_jsonb(d) from public.closed_business d where id=deal_id) then raise exception 'Client or sales history changed';end if;
 if (select count(*) from private.agent_portable_leads where lead_id=any(array[leader_lead,member_lead]) and origin_division='vivid_life')<>2 then raise exception 'Portable lead permission missing';end if;
 if not exists(select 1 from public.lead_requests where id=pending_id and division=destination and recipient_id=leader) or not exists(select 1 from public.lead_requests where id=completed_id and division='vivid_life' and status='completed') then raise exception 'Request routing/history incorrect';end if;
 if not exists(select 1 from public.audit_logs where action='team_leader_promoted_with_agency' and entity_id=leader::text and actor_id=owner_id) then raise exception 'Missing promotion audit';end if;
 set local role authenticated;
 denied:=false;begin perform public.promote_team_leader_with_agency(leader,'vivid_life',ids,null,fresh_name||' retry');exception when raise_exception then denied:=sqlerrm like '%already promoted%';end;if not denied then raise exception 'Duplicate promotion accepted';end if;
 -- An empty-team leader can become admin of their current agency, without creating another one.
 result:=public.promote_team_leader_with_agency(second_leader,'vivid_life','{}','vivid_life',null);
 if (result->>'members_moved')::int<>0 or result->>'division'<>'vivid_life' then raise exception 'Current agency or empty team failed';end if;
 reset role;
 insert into auth.sessions(id,user_id,aal,created_at) values(leader,leader,'aal2',now());
 perform set_config('request.jwt.claims',jsonb_build_object('sub',leader,'role','authenticated','aal','aal2','session_id',leader)::text,true);
 set local role authenticated;
 if public.my_admin_divisions() is distinct from array[destination] or cardinality(public.my_extra_lead_divisions())<>0 then raise exception 'Promoted admin gained unrelated agency access';end if;
 if not public.admin_can_manage_agent(member) or public.admin_can_manage_agent(outsider) then raise exception 'New admin scope incorrect';end if;
 -- Actual live RLS must keep personal leads visible and other agents private.
 if not exists(select 1 from public.leads where id=leader_lead) then raise exception 'Admin lost personal lead';end if;
 if exists(select 1 from public.leads where id=other_lead) then raise exception 'Old agency unrelated lead exposed';end if;
 reset role;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',member,'role','authenticated','aal','aal2','session_id',member)::text,true);
 if private.lead_request_route()->>'recipient_id'<>leader::text then raise exception 'Future requests do not route to promoted admin';end if;
 -- An owner token without a live session must not read the preview.
 perform set_config('request.jwt.claims',jsonb_build_object('sub',owner_id,'role','authenticated','aal','aal2','session_id',gen_random_uuid())::text,true);
 denied:=false;begin perform public.team_admin_promotion_preview(outsider);exception when sqlstate 'PT403' then denied:=true;end;if not denied then raise exception 'Owner without live session admitted';end if;
end $test$;
select 'PASS: owner/MFA enforcement, stale roster/agency, atomic promotion, existing/new agency, empty/disabled/archived members, unchanged leads/CRM/history, portable lead access, request routing, scope isolation, audit and repeat rejection' as result;
