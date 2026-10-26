begin;
do $$
declare actor uuid; pid uuid; stamp timestamptz; versions jsonb; result jsonb; sid uuid:=gen_random_uuid(); lid uuid;
begin
 select p.id,c.profile_id into actor,pid from private.book_crm_clients c
 join public.closed_business d on d.id=c.deal_id join public.leads l on l.id=d.lead_id
 join public.profiles p on p.id=c.agent_id
 where p.role='admin' and p.active and not p.archived and not p.is_super_admin
 and l.assigned_to=p.id and l.division<>p.division limit 1;
 if actor is null then raise exception 'Cross-agency admin fixture missing';end if;
 select updated_at into stamp from private.book_crm_profiles where id=pid;
 select jsonb_agg(jsonb_build_object('id',id,'updated_at',updated_at,'deal_version',deal_version) order by id) into versions from private.book_crm_records where profile_id=pid;
 insert into private.book_unlocks values(actor,sid::text,now()+interval '15 minutes');
 perform set_config('request.jwt.claims',jsonb_build_object('sub',actor,'role','authenticated','aal','aal2','session_id',sid)::text,true);
 perform set_config('role','authenticated',true);
 result:=public.book_crm_profile_delete_option(pid,stamp,versions,true);lid:=(result->>'returned_lead_id')::uuid;
 if not exists(select 1 from public.leads where id=lid and assigned_to=actor) then raise exception 'Returned lead is not visible';end if;
 perform public.set_lead_agent_status(lid,'call_back');
 perform set_config('role','postgres',true);
 if not exists(select 1 from private.agent_portable_leads where lead_id=lid and agent_id=actor) then raise exception 'Portable grant missing';end if;
end $$;
select 'PASS: merged admin can return an original-agency CRM client, see the returned lead and update its call status without broad agency access' result;
rollback;
