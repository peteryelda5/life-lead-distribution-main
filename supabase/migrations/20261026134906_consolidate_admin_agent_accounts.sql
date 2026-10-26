-- A maintenance-only consolidation path. No public RPC or self-service grants.
create table private.admin_account_consolidations (
 source_id uuid primary key references public.profiles(id),
 target_id uuid not null references public.profiles(id),
 actor_id uuid not null references public.profiles(id),
 reason text not null check(length(btrim(reason))>0),
 completed_at timestamptz not null default now(),
 before_state jsonb not null,
 counts jsonb not null,
 check(source_id<>target_id)
);
alter table private.admin_account_consolidations enable row level security;
revoke all on private.admin_account_consolidations from public,anon,authenticated,service_role;

-- Remains immediate during normal application writes; maintenance defers only
-- while moving both sides of this compound owner/profile reference.
alter table private.book_crm_clients alter constraint book_crm_policy_profile deferrable initially immediate;

create policy "admins read personally assigned leads" on public.leads
 for select to authenticated
 using (assigned_to=(select auth.uid()) and status in ('assigned','closed')
  and (select private.verified_portal_session())
  and exists(select 1 from public.profiles p where p.id=(select auth.uid()) and p.role='admin'));

CREATE OR REPLACE FUNCTION public.enforce_lead_division()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare caller_role public.user_role; caller_super boolean; caller_div text; agent_div text;
begin
 if tg_op in ('INSERT','UPDATE') and private.book_crm_lead_return_permitted(new) then return new;end if;
 if tg_op='UPDATE' and new.division is distinct from old.division then
  if not (
   (private.can_transfer_lead_pool(old.division,new.division) and old.division<>'legacy_life' and old.status='unassigned' and old.assigned_to is null and new.status='unassigned' and new.assigned_to is null)
   or (private.can_recall_agency_pool(old.division,new.division) and old.status='unassigned' and old.assigned_to is null and new.status='unassigned' and new.assigned_to is null and not exists(select 1 from public.closed_business b where b.lead_id=old.id))
   or (old.status='closed' and new.status='closed' and old.assigned_to is not null and new.assigned_to=old.assigned_to and public.admin_can_access_division(old.division) and public.admin_can_access_division(new.division) and exists(select 1 from public.profiles p where p.id=new.assigned_to and p.role='agent' and p.division=new.division and not coalesce(p.archived,false)))
  ) then raise exception 'Lead division change is not allowed outside an authorized pool or agent transfer.' using errcode='42501'; end if;
 end if;
 if auth.uid() is not null then
  select p.role,p.is_super_admin,p.division into caller_role,caller_super,caller_div from public.profiles p where p.id=auth.uid() and p.active=true;
  if caller_role='admin'::public.user_role and not (
   tg_op='UPDATE' and old.assigned_to=auth.uid() and new.assigned_to=auth.uid()
   and new.division=old.division and exists(select 1 from private.agent_portable_leads x
     where x.lead_id=new.id and x.agent_id=auth.uid() and x.origin_division=new.division)
  ) then
   if coalesce(caller_super,false) then
    if new.division is null then new.division:=caller_div; end if;
    if tg_op='INSERT' and new.division not in ('owner','vivid_life') then raise exception 'Master can add or move leads only to Vivid Life or Master' using errcode='42501';end if;
    if tg_op='INSERT' and new.owner_admin_id is null then new.owner_admin_id:=auth.uid();end if;
   else
    if caller_div is null then raise exception 'Admin division is not configured';end if;
    if tg_op='UPDATE' and not public.admin_can_access_division(old.division) then raise exception 'You cannot manage leads in another division' using errcode='42501';end if;
    if not public.admin_can_access_division(new.division) then raise exception 'You cannot add or move leads to another division' using errcode='42501';end if;
    if tg_op='INSERT' then new.owner_admin_id:=auth.uid();end if;
   end if;
  end if;
 end if;
 if new.division is null then new.division:='owner';end if;
 if new.assigned_to is not null then
  if exists(select 1 from public.profiles p where p.id=new.assigned_to and p.role='admin') then
   if not private.admin_can_receive_lead(new.assigned_to,new.division) and not exists(
    select 1 from private.agent_portable_leads x where x.lead_id=new.id
    and x.agent_id=new.assigned_to and x.origin_division=new.division
   ) then
    raise exception 'Admin recipient cannot access this agency' using errcode='42501';
   end if;
  else
  select p.division into agent_div from public.profiles p where p.id=new.assigned_to and p.role='agent'::public.user_role;
  if agent_div is null or (agent_div<>new.division and not (
   tg_op='UPDATE' and new.status in ('assigned','closed') and new.division=old.division
   and exists(select 1 from private.agent_portable_leads x where x.lead_id=new.id and x.agent_id=new.assigned_to and x.origin_division=new.division)
  )) then raise exception 'Lead and agent must belong to the same division';end if;
  end if;
 end if;
 return new;
end $function$;



create function private.consolidate_admin_agent(p_source uuid,p_target uuid,p_actor uuid,p_reason text)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare src public.profiles; dst public.profiles; before_data jsonb; counts jsonb;
 item record; part jsonb; policy_ids uuid[]; deal_ids uuid[]; lead_ids uuid[];
 n bigint; profiles_n bigint; deals_n bigint; leads_n bigint;
begin
 -- Callable only by database maintenance roles, never by portal/API roles.
 if current_user not in ('postgres','supabase_admin') then raise exception 'Database maintenance only' using errcode='42501';end if;
 if p_source=p_target or nullif(btrim(p_reason),'') is null then raise exception 'Invalid consolidation';end if;
 if not exists(select 1 from public.profiles where id=p_actor and role='admin' and is_super_admin and active and not archived) then raise exception 'Active owner required';end if;
 if exists(select 1 from private.admin_account_consolidations where source_id=p_source) then raise exception 'Account already consolidated';end if;
 -- Locks prevent concurrent client/deal writes while the two ownership columns move.
 lock table public.profiles,public.closed_business,public.leads,private.book_crm_profiles,private.book_crm_clients in access exclusive mode;
 select * into src from public.profiles where id=p_source;
 select * into dst from public.profiles where id=p_target;
 if src.role is distinct from 'agent' or dst.role is distinct from 'admin' or not dst.active or dst.archived then raise exception 'Expected agent source and active admin destination';end if;
 -- Paid subscriptions, provider assets or live call history require a provider-aware transfer.
 if exists(select 1 from public.dialer_accounts where user_id=p_source and (subscription_id is not null or paid_invoice or subscription_status not in ('none','at_cost_pending')))
 or exists(select 1 from public.dialer_at_cost where user_id=p_source and (provider_sid is not null or provisioning or coalesce(cost_usd,0)<>0))
 or exists(select 1 from public.dialer_numbers where user_id=p_source)
 or exists(select 1 from public.dialer_calls where user_id=p_source)
 or exists(select 1 from public.dialer_callbacks where user_id=p_source)
 or exists(select 1 from public.dialer_conversations where user_id=p_source)
 or exists(select 1 from public.master_dialer_numbers where user_id=p_source)
 or exists(select 1 from public.dialer_priority_tasks where user_id=p_source)
 then raise exception 'Resolve source dialer assets before consolidating';end if;
 if exists(select 1 from private.book_comp_grid s join private.book_comp_grid d on d.agent_id=p_target and (s.carrier,s.policy_type,s.effective_date)=(d.carrier,d.policy_type,d.effective_date) where s.agent_id=p_source) then raise exception 'Resolve overlapping compensation rates first';end if;
 if exists(select 1 from public.profiles where team_leader_id=p_source) then raise exception 'Transfer team membership first';end if;
 select coalesce(array_agg(id),'{}'),count(*) into policy_ids,n from private.book_crm_clients where agent_id=p_source;
 select count(*) into profiles_n from private.book_crm_profiles where agent_id=p_source;
 select coalesce(array_agg(id),'{}'),count(*) into deal_ids,deals_n from public.closed_business where agent_id=p_source;
 select coalesce(array_agg(id),'{}'),count(*) into lead_ids,leads_n from public.leads where assigned_to=p_source;
 before_data:=jsonb_build_object('source_profile',to_jsonb(src),'target_profile',to_jsonb(dst));
 for item in select * from (values
 ('public','closed_business','agent_id'),('public','leads','assigned_to'),
 ('private','book_crm_profiles','agent_id'),('private','book_crm_clients','agent_id'),
 ('private','book_comp_grid','agent_id'),('private','book_crm_lead_returns','agent_id'),
 ('private','agent_portable_leads','agent_id'),('private','leaderboard_monthly_import','agent_id'),
 ('public','chat_messages','author_id'),('private','chat_reactions','user_id'),
 ('private','chat_reads','user_id'),('private','portal_chat_preferences','user_id'),
 ('public','lead_requests','agent_id'),('public','dialer_at_cost','user_id')
 ) v(s,t,c) loop
  execute format('select coalesce(jsonb_agg(to_jsonb(x)),''[]''::jsonb) from %I.%I x where %I=$1',item.s,item.t,item.c) into part using p_source;
  before_data:=before_data||jsonb_build_object(item.s||'.'||item.t,part);
 end loop;
 before_data:=before_data||jsonb_build_object('comp_snapshots',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from private.book_deal_comp x where deal_id=any(deal_ids)));
 counts:=jsonb_build_object('policies',n,'clients',profiles_n,'closed_deals',deals_n,'leads',leads_n);
 insert into private.admin_account_consolidations(source_id,target_id,actor_id,reason,before_state,counts)
 values(p_source,p_target,p_actor,p_reason,before_data,counts);

 -- Maintain original agency and folder; these exact leads get portable ownership.
 insert into private.agent_portable_leads(lead_id,agent_id,origin_division)
 select id,p_target,division from public.leads where assigned_to=p_source
 on conflict(lead_id) do update set agent_id=excluded.agent_id,origin_division=excluded.origin_division;
 update public.leads set assigned_to=p_target where id=any(lead_ids);

 -- Avoid recalculating historical compensation or announcing old deals again.
 alter table public.closed_business disable trigger book_capture_closed;
 alter table public.closed_business disable trigger chat_deal_announcement;
 update public.closed_business set agent_id=p_target where id=any(deal_ids);
 alter table public.closed_business enable trigger book_capture_closed;
 alter table public.closed_business enable trigger chat_deal_announcement;

 set constraints private.book_crm_policy_profile deferred;
 alter table private.book_crm_clients disable trigger book_crm_attach_profile;
 update private.book_crm_profiles set agent_id=p_target,updated_at=clock_timestamp() where agent_id=p_source;
 update private.book_crm_clients set agent_id=p_target,updated_at=clock_timestamp() where id=any(policy_ids);
 set constraints private.book_crm_policy_profile immediate;
 alter table private.book_crm_clients enable trigger book_crm_attach_profile;
 update private.book_comp_grid set agent_id=p_target where agent_id=p_source;
 update private.book_crm_lead_returns set agent_id=p_target where agent_id=p_source;
 update private.leaderboard_monthly_import set agent_id=p_target where agent_id=p_source;
 update public.lead_requests set agent_id=p_target where agent_id=p_source;
 update public.lead_requests set recipient_id=p_target where recipient_id=p_source;
 update public.chat_messages set author_id=p_target where author_id=p_source;
 update private.portal_conversation_messages set author_id=p_target where author_id=p_source;
 update private.portal_conversations set owner_id=p_target where owner_id=p_source;
 insert into private.chat_reads(user_id,division,channel,last_id)
 select p_target,division,channel,last_id from private.chat_reads where user_id=p_source
 on conflict(user_id,division,channel) do update set last_id=greatest(private.chat_reads.last_id,excluded.last_id);
 insert into private.chat_reactions(message_id,user_id,emoji)
 select message_id,p_target,emoji from private.chat_reactions where user_id=p_source on conflict do nothing;
 insert into private.portal_chat_preferences(user_id,chat_key,last_read,mode)
 select p_target,chat_key,last_read,mode from private.portal_chat_preferences where user_id=p_source
 on conflict(user_id,chat_key) do update set last_read=greatest(private.portal_chat_preferences.last_read,excluded.last_read);
 delete from private.chat_reads where user_id=p_source;
 delete from private.chat_reactions where user_id=p_source;
 delete from private.portal_chat_preferences where user_id=p_source;
 -- Preserve original legal documents, audit authors, authentication factors and
 -- inactive billing setup as historical records. Never copy authentication secrets.
 update public.dialer_at_cost set enabled=false where user_id=p_source;
 update public.profiles set active=false,archived=true where id=p_source;
 -- Archived/disabled profiles fail verified_portal_session immediately, including existing JWTs.
 delete from private.portal_passkey_sessions where user_id=p_source;
 delete from private.book_unlocks where user_id=p_source;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
 values(p_actor,'admin_agent_account_consolidated','profile',p_source::text,
 jsonb_build_object('target_id',p_target,'counts',counts,'reason',p_reason));
 if exists(select 1 from private.book_crm_clients where agent_id=p_source) or exists(select 1 from public.closed_business where agent_id=p_source) or exists(select 1 from public.leads where assigned_to=p_source) then raise exception 'Incomplete consolidation';end if;
 if (select coalesce(jsonb_agg(to_jsonb(x) order by x.deal_id),'[]') from private.book_deal_comp x where deal_id=any(deal_ids)) is distinct from
 (select coalesce(jsonb_agg(value order by value->>'deal_id'),'[]') from jsonb_array_elements(before_data->'comp_snapshots')) then raise exception 'Compensation snapshots changed';end if;
 return counts||jsonb_build_object('source_id',p_source,'target_id',p_target,'ok',true);
end $$;
revoke all on function private.consolidate_admin_agent(uuid,uuid,uuid,text) from public,anon,authenticated,service_role;
notify pgrst,'reload schema';
