-- Compact closed-deal celebrations reuse the leaderboard's visibility and safe signal.
-- Additive: existing receipts, preferences and other notification categories are retained.
alter table private.portal_notification_preferences
 drop constraint portal_notification_preferences_muted_categories_check;
alter table private.portal_notification_preferences
 add constraint portal_notification_preferences_muted_categories_check
 check(muted_categories <@ array['leads','requests','calls','chat','announcements','team','billing','deals']::text[]);

create or replace function private.portal_notification_items()
returns table(event_key text,category text,title text,body text,target jsonb,occurred_at timestamptz,source_read boolean)
language plpgsql stable security definer set search_path='' as $$
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
  coalesce(p.full_name,'A teammate')||' sent a message. Open the conversation to read it.',
  jsonb_build_object('tab','live-chat','conversation',c.id),m.created_at,m.id<=coalesce(pref.last_read,0)
 from private.portal_conversations c
 left join private.portal_chat_preferences pref on pref.user_id=me.id and pref.chat_key='group:'||c.id
 join lateral (select x.id,x.author_id,x.body,x.created_at from private.portal_conversation_messages x
   where x.conversation_id=c.id and x.author_id<>me.id and x.created_at>=since_at and (coalesce(pref.mode,'all')<>'mentions' or position('@'||me.full_name in x.body)>0) order by x.id desc limit 1) m on true
 left join public.profiles p on p.id=m.author_id
 where me.id=any(c.members) and private.portal_conversation_access(c.id)
  and coalesce(pref.mode,'all')<>'muted';
 return query
 select 'channel:'||room,'chat','New message in #'||room,
  m.author_name||' posted in #'||room||'.',jsonb_build_object('tab','live-chat','room',room),m.created_at,m.id<=coalesce(pref.last_read,0)
 from unnest(array['general','deals','resources']) room
 left join private.portal_chat_preferences pref on pref.user_id=me.id and pref.chat_key='channel:'||room
 join lateral (select x.id,x.author_name,x.created_at from public.chat_messages x where x.channel=room
   and coalesce(x.kind,'text')<>'deal' and x.division=any(chat_divisions) and x.author_id<>me.id and x.created_at>=since_at
   and (coalesce(pref.mode,'all')<>'mentions' or me.id=any(x.mention_ids)) order by x.id desc limit 1) m on true
 where coalesce(pref.mode,'all')<>'muted';
 -- Match the shared leaderboard's agency scope, including its Legacy isolation.
 -- Created-at is stable across corrections; no client or policy details leave this feed.
 return query
 select 'deal:'||cb.id,'deals',p.full_name||' closed a deal',
  d.name||' · $'||to_char(cb.annual_premium,'FM999,999,999,990.00')||' annual premium',
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
end $$;
revoke all on function private.portal_notification_items() from public,anon,authenticated;

create or replace function private.portal_notifications(p_action text default 'list',p_data jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare who uuid:=auth.uid(); prefs private.portal_notification_preferences; result jsonb; offset_n integer; category_filter text; before_at timestamptz; selected_muted text[];
begin
 if not private.verified_portal_session() then raise exception 'Verified login required' using errcode='42501';end if;
 if p_action='preferences' then
  if jsonb_typeof(p_data->'muted_categories') is distinct from 'array' or jsonb_array_length(p_data->'muted_categories')>8 then raise exception 'Invalid notification categories';end if;
  select coalesce(array_agg(distinct value),'{}') into selected_muted from jsonb_array_elements_text(p_data->'muted_categories');
  if not selected_muted<@array['leads','requests','calls','chat','announcements','team','billing','deals']::text[] then raise exception 'Invalid notification categories';end if;
  insert into private.portal_notification_preferences(user_id,muted_categories,toast_enabled)
   values(who,selected_muted,coalesce((p_data->>'toast_enabled')::boolean,true))
  on conflict(user_id) do update set muted_categories=excluded.muted_categories,toast_enabled=excluded.toast_enabled;
 elsif p_action in ('read','archive','unread') then
  if jsonb_typeof(p_data->'items') is distinct from 'array' or jsonb_array_length(p_data->'items')>100 then raise exception 'Select up to 100 notifications';end if;
  if (select count(*)<>count(distinct x->>'key') from jsonb_array_elements(p_data->'items') x) then raise exception 'Select each notification once';end if;
  insert into private.portal_notification_receipts(user_id,event_key,read_at,archived_at,force_unread)
   select who,n.event_key,case when p_action='unread' then null else least(n.occurred_at,(x->>'at')::timestamptz) end,
    case when p_action='archive' then least(n.occurred_at,(x->>'at')::timestamptz) else null end,p_action='unread'
   from private.portal_notification_items() n join (select value x from jsonb_array_elements(p_data->'items') group by value) input on x->>'key'=n.event_key
   where (x->>'at') is not null
  on conflict(user_id,event_key) do update set force_unread=excluded.force_unread,read_at=case when p_action='unread' then null else greatest(private.portal_notification_receipts.read_at,excluded.read_at) end,
   archived_at=case when p_action='archive' then greatest(private.portal_notification_receipts.archived_at,excluded.archived_at) else null end;
 elsif p_action='read_all' then
  if nullif(p_data->>'before','') is null then raise exception 'Refresh notifications before marking them read';end if;
  before_at:=least((p_data->>'before')::timestamptz,now());
  if before_at is null then raise exception 'Refresh notifications before marking them read';end if;
  insert into private.portal_notification_receipts(user_id,event_key,read_at)
   select who,n.event_key,n.occurred_at from private.portal_notification_items() n where n.occurred_at<=before_at
  on conflict(user_id,event_key) do update set force_unread=false,read_at=greatest(private.portal_notification_receipts.read_at,excluded.read_at);
 elsif p_action<>'list' then raise exception 'Unknown notification action';end if;
 select * into prefs from private.portal_notification_preferences where user_id=who;
 category_filter:=nullif(p_data->>'category','all');
 if category_filter is not null and category_filter<>all(array['leads','requests','calls','chat','announcements','team','billing','deals']) then raise exception 'Invalid notification category';end if;
 offset_n:=greatest(0,least(coalesce((p_data->>'offset')::integer,0),10000));
 with items as materialized (
  select n.*,r.read_at,coalesce(r.archived_at>=n.occurred_at,false) archived,
   case when r.force_unread then false else n.source_read or coalesce(r.read_at>=n.occurred_at,false) end is_read,
   n.category=any(coalesce(prefs.muted_categories,'{}')) muted
  from private.portal_notification_items() n left join private.portal_notification_receipts r on r.user_id=who and r.event_key=n.event_key
 ), filtered as materialized (
  select * from items where not archived and not muted and (category_filter is null or category=category_filter)
   and (not coalesce((p_data->>'unread')::boolean,false) or not is_read)
 ), page as (select * from filtered order by occurred_at desc,event_key limit 50 offset offset_n)
 select jsonb_build_object('items',coalesce((select jsonb_agg(jsonb_build_object('key',event_key,'category',category,'title',title,'body',body,'target',target,'at',occurred_at,'read',is_read) order by occurred_at desc,event_key) from page),'[]'),
  'total',(select count(*) from filtered),'unread',(select count(*) from items where not archived and not muted and not is_read),
  'categories',coalesce((select jsonb_object_agg(category,n) from (select category,count(*) n from items where not archived and not muted and not is_read group by category) counts),'{}'),
  'as_of',now(),'preferences',jsonb_build_object('muted_categories',coalesce(prefs.muted_categories,'{}'),'toast_enabled',coalesce(prefs.toast_enabled,true))) into result;
 return result;
end $$;
notify pgrst,'reload schema';
