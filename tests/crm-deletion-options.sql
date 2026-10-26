begin;
do $$
declare actor uuid; sid uuid:=gen_random_uuid(); person private.book_crm_profiles; versions jsonb; result jsonb;
 lead_count bigint; deal_count bigint; policy private.book_crm_clients; sibling uuid:=gen_random_uuid(); lead uuid; removed boolean;
begin
 select id into actor from public.profiles where role='admin' and is_super_admin and active and not archived limit 1;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',actor,'role','authenticated','aal','aal2','session_id',sid)::text,true);
 insert into private.book_unlocks(user_id,session_id,expires_at) values(actor,sid::text,now()+interval '15 minutes');
 select p.* into person from private.book_crm_profiles p where p.agent_id=actor and exists(select 1 from private.book_crm_clients c where c.profile_id=p.id) order by p.id limit 1;
 select jsonb_agg(jsonb_build_object('id',id,'updated_at',updated_at,'deal_version',deal_version) order by id) into versions from private.book_crm_records where profile_id=person.id;
 select count(*) into lead_count from public.leads;select count(*) into deal_count from public.closed_business;
 -- Stale dialogs fail before removing records.
 begin
  perform public.book_crm_profile_delete_option(person.id,person.updated_at-interval '1 day',versions,false);
  raise exception 'Stale deletion accepted';
 exception when sqlstate 'PT409' then null;end;
 perform set_config('role','authenticated',true);
 result:=public.book_crm_profile_delete_option(person.id,person.updated_at,versions,false);
 perform set_config('role','postgres',true);
 if result->>'returned_to_leads'<>'false' or exists(select 1 from private.book_crm_profiles where id=person.id) or exists(select 1 from private.book_crm_clients where profile_id=person.id) then raise exception 'Delete-only left the client';end if;
 if (select count(*) from public.leads)<>lead_count or (select count(*) from public.closed_business)<>deal_count or exists(select 1 from private.book_crm_lead_returns where profile_id=person.id) then raise exception 'Delete-only changed leads or production';end if;
 -- Default return behavior stays available to old and new clients.
 select p.* into person from private.book_crm_profiles p where p.agent_id=actor and exists(select 1 from private.book_crm_clients c where c.profile_id=p.id) order by p.id limit 1;
 select jsonb_agg(jsonb_build_object('id',id,'updated_at',updated_at,'deal_version',deal_version) order by id) into versions from private.book_crm_records where profile_id=person.id;
 result:=public.book_crm_profile_delete(person.id,person.updated_at,versions);
 if result->>'returned_lead_id' is null or not exists(select 1 from public.leads where id=(result->>'returned_lead_id')::uuid and assigned_to=actor and status='assigned') then raise exception 'Return option failed';end if;
 -- A deleted closed deal removes exactly its policy, not a sibling policy.
 select c.* into policy from private.book_crm_clients c join public.closed_business d on d.id=c.deal_id where exists(select 1 from public.profiles p where p.id=c.agent_id and p.active and not p.archived) and coalesce((select division from public.leads where id=d.lead_id),(select division from public.profiles where id=c.agent_id))=any(private.my_admin_divisions()) order by c.id limit 1;
 if policy.id is null then raise exception 'No closed policy fixture';end if;
 insert into private.book_crm_clients select (jsonb_populate_record(null::private.book_crm_clients,to_jsonb(policy)||jsonb_build_object('id',sibling,'deal_id',null,'production_recorded',false))).*;
 insert into private.book_crm_tasks(client_id,title,due_at,created_by) values(policy.id,'Rollback cleanup check',now(),actor);
 select lead_id into lead from public.closed_business where id=policy.deal_id;
 perform set_config('role','authenticated',true);
 removed:=public.remove_closed_deal(policy.deal_id);
 perform set_config('role','postgres',true);
 if not removed or exists(select 1 from private.book_crm_clients where id=policy.id) or exists(select 1 from private.book_crm_tasks where client_id=policy.id) then raise exception 'Closed-deal policy was not cleaned up';end if;
 if not exists(select 1 from private.book_crm_profiles where id=policy.profile_id) or not exists(select 1 from private.book_crm_clients where id=sibling) then raise exception 'Sibling policy/profile was deleted';end if;
 if not exists(select 1 from public.audit_logs where action='crm_policy_removed_with_closed_deal' and entity_id=policy.id::text and details->'before'->'policy'->>'deal_id'=policy.deal_id::text) then raise exception 'Cleanup snapshot missing';end if;
 if lead is not null and exists(select 1 from public.leads l join public.profiles p on p.id=l.assigned_to where l.id=lead and p.active and not p.archived and l.status<>'assigned') then raise exception 'Active owner lead not reopened';end if;
 if public.remove_closed_deal(policy.deal_id) then raise exception 'Repeated deal deletion should be a no-op';end if;
 if has_function_privilege('anon','public.book_crm_profile_delete_option(uuid,timestamptz,jsonb,boolean)','execute') then raise exception 'Anonymous deletion exposed';end if;
end $$;
select 'PASS: delete-only leaves leads and production unchanged; default return works; stale versions fail; closed-deal deletion removes only the linked policy, archives history, retains siblings, and is repeat-safe' result;
rollback;
