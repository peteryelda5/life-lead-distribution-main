-- Owner requested readable chat/deal previews on phones and prompt delivery.
-- Access, mutes and read receipts continue to come from the existing inbox.
create or replace function private.portal_chat_preview(p_body text)
returns text language plpgsql immutable set search_path='' as $$
declare media jsonb; preview text:=coalesce(p_body,'');
begin
 if preview like 'VIVID_MEDIA:%' then
  begin media:=substr(preview,13)::jsonb;
   preview:=case when coalesce(media->>'name','') ~* '\.gif$' then 'GIF' else 'Photo' end
    ||case when nullif(trim(media->>'caption'),'') is not null then ': '||trim(media->>'caption') else '' end;
  exception when others then preview:='Photo attachment';end;
 elsif preview like 'LLD_RESOURCE:%' then
  begin media:=substr(preview,14)::jsonb;preview:='Shared file: '||coalesce(nullif(media->>'name',''),'Document');
  exception when others then preview:='Shared a file';end;
 end if;
 return left(preview,500)||case when length(preview)>500 then '…' else '' end;
end $$;
revoke all on function private.portal_chat_preview(text) from public,anon,authenticated;

CREATE OR REPLACE FUNCTION private.portal_notification_items()
 RETURNS TABLE(event_key text, category text, title text, body text, target jsonb, occurred_at timestamp with time zone, source_read boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare me public.profiles; divisions text[]; chat_divisions text[]; since_at timestamptz:=now()-interval '30 days';
begin
 if not private.verified_portal_session() then raise exception 'Verified login required' using errcode='42501';end if;
 select * into me from public.profiles where id=auth.uid();
 divisions:=private.my_admin_divisions();chat_divisions:=private.shared_chat_divisions();
 return query
 select 'delivery:'||r.id,'leads',case when r.recipient_id=me.id then 'New leads assigned to you' when me.role='admin' then 'Leads delivered to your agency' else 'Leads delivered to your team' end,
  r.lead_count||' leads · '||coalesce(r.sender_name,'Your team')||' → '||coalesce(r.recipient_name,r.destination_name,'Agency pool'),
  jsonb_build_object('tab',case when r.recipient_id=me.id then 'my-leads' when me.role='admin' then 'activity' else 'dashboard' end),r.delivered_at,false
 from public.lead_delivery_receipts r
 where r.delivered_at>=since_at and (r.recipient_id=me.id or r.destination_division=any(divisions) or (me.is_team_leader and exists(select 1 from public.profiles p where p.id=r.recipient_id and p.team_leader_id=me.id and p.division=me.division and p.active and not coalesce(p.archived,false))));
 return query
 select 'request-in:'||r.id,'requests','Lead request from '||r.agent_name,
  r.quantity||' '||r.lead_type||' leads requested · '||case when r.status='pending' then 'Needs a response' else r.status end,
  jsonb_build_object('tab','lead-requests','id',r.id),r.created_at,r.status<>'pending'
 from public.lead_requests r where r.created_at>=since_at and r.agent_id<>me.id
  and private.can_manage_lead_request(r.agent_id,r.division);
 return query
 select 'request-out:'||r.id,'requests',case when r.status='declined' then 'Lead request declined' when r.status='completed' then 'Lead request handled' else 'Lead request updated' end,
  r.fulfilled_quantity||' of '||r.quantity||' '||r.lead_type||' leads delivered. Open the request to view the response.',
  jsonb_build_object('tab','lead-requests','id',r.id),r.updated_at,false
 from public.lead_requests r where r.agent_id=me.id and r.updated_at>=since_at
  and (r.status<>'pending' or r.fulfilled_quantity>0 or nullif(r.response,'') is not null);
 return query
 select 'callback:'||case when c.recording_path is not null or c.recording_pending then 'voicemail:' else 'missed:' end||c.id,'calls',case when c.recording_path is not null or c.recording_pending then 'New voicemail' else 'Missed callback' end,
  c.caller_phone||' called you. Open callbacks to see the matching lead.',
  jsonb_build_object('tab','power-dialer','view','callbacks','id',c.id),coalesce(c.completed_at,c.created_at),c.seen_at is not null and c.recording_path is null and not c.recording_pending
 from public.dialer_callbacks c where c.user_id=me.id and c.livemode and c.created_at>=since_at
  and (c.status in ('missed','voicemail') or c.recording_path is not null or c.recording_pending);
 return query
 select 'priority:'||t.id,'calls',case when t.source='power' then 'Answered lead needs follow-up' else 'Callback is due' end,
  coalesce(nullif(concat_ws(' ',l.first_name,l.last_name),''),t.phone)||' · '||t.reason,
  jsonb_build_object('tab','power-dialer','view','priority','id',t.id),t.due_at,false
 from public.dialer_priority_tasks t left join public.leads l on l.id=t.lead_id and l.assigned_to=me.id
 where t.user_id=me.id and t.livemode and t.resolved_at is null and t.due_at<=now();
 return query
 select 'group:'||c.id,'chat',case when c.kind='direct' then 'New direct message' else 'New message in '||c.name end,
  coalesce(p.full_name,'A teammate')||': '||private.portal_chat_preview(m.body),
  jsonb_build_object('tab','live-chat','conversation',c.id,'message_id',m.id::text),m.created_at,m.id<=coalesce(pref.last_read,0)
 from private.portal_conversations c
 left join private.portal_chat_preferences pref on pref.user_id=me.id and pref.chat_key='group:'||c.id
 join lateral (select x.id,x.author_id,x.body,x.created_at from private.portal_conversation_messages x
   where x.conversation_id=c.id and x.author_id<>me.id and x.created_at>=since_at and (coalesce(pref.mode,'all')<>'mentions' or position('@'||me.full_name in x.body)>0) order by x.id desc limit 1) m on true
 left join public.profiles p on p.id=m.author_id
 where me.id=any(c.members) and private.portal_conversation_access(c.id)
  and coalesce(pref.mode,'all')<>'muted';
 return query
 select 'channel:'||room,'chat','New message in #'||room,
  m.author_name||': '||private.portal_chat_preview(m.body),jsonb_build_object('tab','live-chat','room',room,'message_id',m.id::text),m.created_at,m.id<=coalesce(pref.last_read,0)
 from unnest(array['general','deals','resources']) room
 left join private.portal_chat_preferences pref on pref.user_id=me.id and pref.chat_key='channel:'||room
 join lateral (select x.id,x.author_name,x.body,x.created_at from public.chat_messages x where x.channel=room
   and coalesce(x.kind,'text')<>'deal' and x.division=any(chat_divisions) and x.author_id<>me.id and x.created_at>=since_at
   and (coalesce(pref.mode,'all')<>'mentions' or me.id=any(x.mention_ids)) order by x.id desc limit 1) m on true
 where coalesce(pref.mode,'all')<>'muted';
 -- Match the shared leaderboard's agency scope, including its Legacy isolation.
 -- Created-at stays stable across corrections. No client records or policy numbers in previews.
 return query
 select 'deal:'||cb.id,'deals',p.full_name||' closed a deal',
  concat_ws(' · ',d.name,nullif(cb.carrier,''),nullif(cb.policy_type,''),'$'||to_char(cb.monthly_premium,'FM999,999,999,990.00')||'/month','$'||to_char(cb.annual_premium,'FM999,999,999,990.00')||' annual premium'),
  jsonb_build_object('tab','leaderboard','celebration','corner','agent_name',p.full_name,
   'agency_name',d.name,'annual_premium',cb.annual_premium),cb.created_at,false
 from public.closed_business cb join public.profiles p on p.id=cb.agent_id
 left join public.leads l on l.id=cb.lead_id
 join public.divisions d on d.id=coalesce(l.division,p.division)
 where cb.created_at>=since_at and cb.created_at<=now()
  and coalesce(l.division,p.division)=any(private.sales_board_divisions());
 return query
 select 'announcement:'||a.id,'announcements',a.title,'A new portal announcement is available.',
  jsonb_build_object('tab','announcements','id',a.id),a.created_at,false
 from public.portal_announcements a where a.created_at>=since_at and a.created_by<>me.id
  and (a.division is null or a.division=me.division or a.division=any(divisions));
 return query
 select 'goal:'||g.user_id||':'||g.month,'team','Your production goal was updated',
  'View your goal and progress for '||to_char(g.month,'Month YYYY')||'.',jsonb_build_object('tab','dashboard'),g.updated_at,false
 from private.portal_monthly_goals g where g.user_id=me.id and g.set_by<>me.id and g.updated_at>=since_at;
 return query
 select 'team:'||p.id,'team','New team member',p.full_name||' joined your team.',
  jsonb_build_object('tab',case when me.role='admin' then 'agents' else 'dashboard' end),p.created_at,false
 from public.profiles p where p.created_at>=since_at and p.id<>me.id and p.active and not coalesce(p.archived,false)
  and ((me.role='admin' and p.role='agent' and p.division=any(divisions))
    or (me.is_team_leader and p.team_leader_id=me.id and p.division=me.division));
 return query
 select 'billing:'||a.user_id||':'||a.livemode,'billing','Calling plan needs attention',
  'Your calling plan is '||replace(a.subscription_status,'_',' ')||'. Review Numbers & billing.',
  jsonb_build_object('tab','power-dialer','view','billing'),coalesce(a.verified_at,a.period_end,a.period_start,me.created_at),false
 from public.dialer_accounts a where a.user_id=me.id and a.livemode and a.subscription_status in ('past_due','unpaid','incomplete');
end $function$
;

create or replace function private.portal_push_batch(p_test uuid default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare d private.portal_push_devices; q private.portal_push_deliveries; n record; jobs jsonb:='[]'; lease_id uuid; valid_item boolean;
begin
 if p_test is null and pg_try_advisory_xact_lock(829117,1) then
  delete from private.portal_push_deliveries where created_at<now()-interval '7 days';
  update private.portal_push_deliveries set state='failed' where state in ('pending','sending') and (created_at<now()-interval '1 hour' or (attempts>=5 and next_attempt<=now()));
  for d in select * from private.portal_push_devices where enabled order by scanned_at limit 100 loop
   if not private.portal_push_session_valid(d.user_id,d.session_id) then
    update private.portal_push_devices set enabled=false where id=d.id;continue;
   end if;
   insert into private.portal_push_deliveries(device_id,event_key,event_version,category,occurred_at)
    select d.id,x.event_key,case when x.category='chat' then coalesce(x.target->>'message_id',x.occurred_at::text) else x.occurred_at::text end,x.category,x.occurred_at
    from private.portal_push_items(d.user_id,d.session_id) x
    left join private.portal_notification_receipts receipt on receipt.user_id=d.user_id and receipt.event_key=x.event_key
    left join private.portal_notification_preferences pref on pref.user_id=d.user_id
    where x.occurred_at>d.started_at and x.occurred_at>=now()-interval '1 hour' and x.occurred_at<=now()
     and x.category=any(d.categories) and not(x.category=any(coalesce(pref.muted_categories,'{}')))
     and not x.source_read and not coalesce(receipt.read_at>=x.occurred_at,false) and not coalesce(receipt.archived_at>=x.occurred_at,false)
     and (x.category<>'chat' or not exists(select 1 from private.portal_push_deliveries prior
      where prior.device_id=d.id and prior.event_key=x.event_key and prior.event_version ~ '^[0-9]+$'
      and x.target->>'message_id' ~ '^[0-9]+$' and prior.event_version::numeric>(x.target->>'message_id')::numeric))
    on conflict(device_id,event_key,event_version) do nothing;
   update private.portal_push_devices set scanned_at=now() where id=d.id;
  end loop;
 end if;
 for q in select * from private.portal_push_deliveries where state in ('pending','sending') and next_attempt<=now()
   and attempts<5 and created_at>=now()-interval '1 hour' and (p_test is null or id=p_test)
   order by created_at,id limit 30 for update skip locked loop
  select * into d from private.portal_push_devices where id=q.device_id;
  if not d.enabled or not private.portal_push_session_valid(d.user_id,d.session_id) then
   update private.portal_push_deliveries set state='skipped' where id=q.id;continue;
  end if;
  if q.category='test' then
   select 'Phone notifications are ready'::text title,'Vivid Life Portal can now send alerts to this device.'::text body into n;valid_item:=true;
  else
   select x.* into n from private.portal_push_items(d.user_id,d.session_id) x
    left join private.portal_notification_receipts receipt on receipt.user_id=d.user_id and receipt.event_key=x.event_key
    left join private.portal_notification_preferences pref on pref.user_id=d.user_id
    where x.event_key=q.event_key and x.category=any(d.categories)
     and (case when x.category='chat' then coalesce(x.target->>'message_id',x.occurred_at::text) else x.occurred_at::text end)=q.event_version
     and not(x.category=any(coalesce(pref.muted_categories,'{}'))) and not x.source_read
     and not coalesce(receipt.read_at>=x.occurred_at,false) and not coalesce(receipt.archived_at>=x.occurred_at,false);
   valid_item:=found;
  end if;
  if not valid_item then update private.portal_push_deliveries set state='skipped' where id=q.id;continue;end if;
  lease_id:=gen_random_uuid();
  update private.portal_push_deliveries set state='sending',attempts=attempts+1,lease=lease_id,next_attempt=now()+interval '2 minutes' where id=q.id;
  jobs:=jobs||jsonb_build_array(jsonb_build_object('id',q.id,'lease',lease_id,'category',q.category,
   'subscription',jsonb_build_object('endpoint',d.endpoint,'keys',jsonb_build_object('p256dh',d.p256dh,'auth',d.auth_key)),
   'title','Vivid Life Portal',
   'body',left(n.title||E'\n'||coalesce(n.body,''),650)));
 end loop;
 return jobs;
end $$;


-- Only the server can wake the dispatcher, after validating the caller's token
-- and second factor. A wake carries no recipients, message text or subscription.
create table private.portal_push_wakes (
 user_id uuid primary key references public.profiles(id) on delete cascade,
 last_wake timestamptz not null
);
alter table private.portal_push_wakes enable row level security;
revoke all on private.portal_push_wakes from public,anon,authenticated,service_role;
create function private.portal_push_wake(p_user uuid,p_session uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare last_at timestamptz; at_time timestamptz:=clock_timestamp();
begin
 if not private.portal_push_session_valid(p_user,p_session) then raise exception 'Sign in again to send notifications' using errcode='42501';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_user::text,8292));
 select last_wake into last_at from private.portal_push_wakes where user_id=p_user;
 if last_at>at_time-interval '2 seconds' then
  return jsonb_build_object('accepted',false,'retry_after_ms',ceil(extract(epoch from (last_at+interval '2 seconds'-at_time))*1000)::integer);
 end if;
 insert into private.portal_push_wakes(user_id,last_wake) values(p_user,at_time)
 on conflict(user_id) do update set last_wake=excluded.last_wake;
 return jsonb_build_object('accepted',true);
end $$;
create function public.portal_push_wake(p_user uuid,p_session uuid)
returns jsonb language sql security invoker set search_path='' as $$select private.portal_push_wake(p_user,p_session)$$;
revoke all on function private.portal_push_wake(uuid,uuid),public.portal_push_wake(uuid,uuid) from public,anon,authenticated;
grant execute on function private.portal_push_wake(uuid,uuid),public.portal_push_wake(uuid,uuid) to service_role;
notify pgrst,'reload schema';
