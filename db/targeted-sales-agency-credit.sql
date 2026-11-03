-- Targeted sales-credit correction only. No table, policy, role, lead or client changes.
-- Nathan: all recorded sales. Dylan and Adolfo: November 2026 onward (Detroit time).
CREATE OR REPLACE FUNCTION private.recorded_leaderboard_data(p_division text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare scopes text[]; chosen text[]; result jsonb;
 today_start timestamptz := date_trunc('day',now() at time zone 'America/Detroit') at time zone 'America/Detroit';
 week_start timestamptz := date_trunc('week',now() at time zone 'America/Detroit') at time zone 'America/Detroit';
 month_start timestamptz := date_trunc('month',now() at time zone 'America/Detroit') at time zone 'America/Detroit';
 year_start timestamptz := date_trunc('year',now() at time zone 'America/Detroit') at time zone 'America/Detroit';
begin
 scopes:=private.sales_board_divisions();
 if cardinality(scopes)=0 then raise exception 'Active account and required verification needed' using errcode='42501'; end if;
 if p_division is null or p_division='all' then chosen:=scopes;
 elsif p_division=any(scopes) then chosen:=array[p_division];
 else raise exception 'Division access denied' using errcode='42501'; end if;
 with sales as materialized (
 select cb.id,cb.agent_id,coalesce(p.full_name,'Former agent') agent_name,(case when cb.agent_id='f411ecbb-2477-4cb6-902f-a69db6b6edd6'::uuid then 'division_1bd8c26ef4e9400c866e81425403b721' when cb.agent_id in ('8c14394a-ad5b-48f6-84a2-2cfa6dc23378'::uuid,'7a24126c-5892-4568-80ed-de57215be22d'::uuid) and cb.created_at>=timestamptz '2026-11-01 00:00:00 America/Detroit' then 'vivid_life' else coalesce(l.division,p.division) end) division,cb.carrier,cb.policy_type,cb.monthly_premium,cb.annual_premium,cb.created_at
 from public.closed_business cb join public.profiles p on p.id=cb.agent_id left join public.leads l on l.id=cb.lead_id
 where (case when cb.agent_id='f411ecbb-2477-4cb6-902f-a69db6b6edd6'::uuid then 'division_1bd8c26ef4e9400c866e81425403b721' when cb.agent_id in ('8c14394a-ad5b-48f6-84a2-2cfa6dc23378'::uuid,'7a24126c-5892-4568-80ed-de57215be22d'::uuid) and cb.created_at>=timestamptz '2026-11-01 00:00:00 America/Detroit' then 'vivid_life' else coalesce(l.division,p.division) end)=any(chosen) and cb.created_at>=least(year_start,week_start) and cb.created_at<=now()
 ), ranked as (
 select s.agent_id,max(s.agent_name) agent_name,count(*) deals,coalesce(sum(s.annual_premium),0) ap,coalesce(sum(s.monthly_premium),0) mp
 from sales s where s.created_at>=month_start group by s.agent_id
 ), roster as (
 select r.agent_id,r.agent_name,r.deals,r.ap,r.mp from ranked r
 union all select p.id,p.full_name,0::bigint,0::numeric,0::numeric from public.profiles p where p.role='agent' and p.active and not coalesce(p.archived,false) and p.division=any(chosen) and not exists(select 1 from ranked r where r.agent_id=p.id)
 ), feed as (select id,agent_name,carrier,policy_type,monthly_premium,annual_premium,created_at from sales where created_at>=today_start order by created_at desc,id desc limit 50)
 select jsonb_build_object(
 'scopes',scopes,'division',coalesce(p_division,'all'),'timezone','America/Detroit','as_of',now(),
 'totals', (select jsonb_build_object(
 'today_ap',coalesce(sum(annual_premium) filter(where created_at>=today_start),0),'today_deals',count(*) filter(where created_at>=today_start),
 'week_ap',coalesce(sum(annual_premium) filter(where created_at>=week_start),0),'week_deals',count(*) filter(where created_at>=week_start),
 'month_ap',coalesce(sum(annual_premium) filter(where created_at>=month_start),0),'month_mp',coalesce(sum(monthly_premium) filter(where created_at>=month_start),0),'month_deals',count(*) filter(where created_at>=month_start),
 'year_ap',coalesce(sum(annual_premium) filter(where created_at>=year_start),0),'year_deals',count(*) filter(where created_at>=year_start),
 'active_producers',count(distinct agent_id) filter(where created_at>=month_start)) from sales),
 'rankings',coalesce((select jsonb_agg(to_jsonb(r) order by r.ap desc,r.deals desc,r.agent_name,r.agent_id) from roster r),'[]'::jsonb),
 'today_feed',coalesce((select jsonb_agg(to_jsonb(f) order by f.created_at desc,f.id desc) from feed f),'[]'::jsonb)
 ) into result;
 return result;
end $function$;


CREATE OR REPLACE FUNCTION private.leaderboard_period(p_division text DEFAULT NULL::text, p_period text DEFAULT 'month'::text, p_month date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare scopes text[]:=private.sales_board_divisions(); chosen text[]; localnow timestamp:=now() at time zone 'America/Detroit'; startlocal timestamp; endlocal timestamp; startat timestamptz; endat timestamptz; result jsonb; ranking jsonb; feed jsonb; ap numeric; mp numeric; deals bigint; imported boolean:=false; adj numeric:=0; months jsonb;
begin
 if cardinality(scopes)=0 then raise exception 'Active verified account required' using errcode='42501';end if;
 if p_division is null or p_division='all' then chosen:=scopes;elsif p_division=any(scopes) then chosen:=array[p_division];else raise exception 'Division access denied' using errcode='42501';end if;
 if p_period='today' then startlocal:=date_trunc('day',localnow);endlocal:=startlocal+interval '1 day';
 elsif p_period='week' then startlocal:=date_trunc('week',localnow);endlocal:=startlocal+interval '1 week';
 elsif p_period in ('month','previous') then
  if p_period='previous' and (p_month is null or p_month<>date_trunc('month',p_month)::date or p_month>=date_trunc('month',localnow)::date) then raise exception 'Choose a previous month';end if;
  startlocal:=case when p_period='month' then date_trunc('month',localnow) else p_month::timestamp end;endlocal:=startlocal+interval '1 month';
 else raise exception 'Invalid leaderboard period';end if;
 startat:=startlocal at time zone 'America/Detroit';endat:=least(endlocal at time zone 'America/Detroit',now());
 if p_period in ('month','previous') then select coalesce(sum(ap_adjustment),0),count(*)>0 into adj,imported from private.leaderboard_monthly_import where month=startlocal::date and division=any(chosen);end if;
 with sales as materialized (
 select cb.id,cb.agent_id,p.full_name agent_name,cb.carrier,cb.policy_type,cb.monthly_premium,cb.annual_premium,cb.created_at
 from public.closed_business cb join public.profiles p on p.id=cb.agent_id left join public.leads l on l.id=cb.lead_id where (case when cb.agent_id='f411ecbb-2477-4cb6-902f-a69db6b6edd6'::uuid then 'division_1bd8c26ef4e9400c866e81425403b721' when cb.agent_id in ('8c14394a-ad5b-48f6-84a2-2cfa6dc23378'::uuid,'7a24126c-5892-4568-80ed-de57215be22d'::uuid) and cb.created_at>=timestamptz '2026-11-01 00:00:00 America/Detroit' then 'vivid_life' else coalesce(l.division,p.division) end)=any(chosen) and cb.created_at>=startat and cb.created_at<endat
 ), actual as (select agent_id::text entry_key,max(agent_name) agent_name,sum(annual_premium) ap,sum(monthly_premium) mp,count(*) deals from sales group by agent_id),
 imports as(select entry_key,max(display_name) agent_name,sum(ap_adjustment) adjustment from private.leaderboard_monthly_import where imported and month=startlocal::date and division=any(chosen) group by entry_key),
 ranked as(select coalesce(a.entry_key,i.entry_key) agent_id,coalesce(a.agent_name,i.agent_name) agent_name,coalesce(a.ap,0)+coalesce(i.adjustment,0) ap,case when i.entry_key is null then coalesce(a.mp,0) end mp,case when i.entry_key is null then coalesce(a.deals,0) end deals from actual a full join imports i using(entry_key)),
 roster as(select * from ranked union all select p.id::text,p.full_name,0::numeric,0::numeric,0::bigint from public.profiles p where p.role='agent' and p.active and not coalesce(p.archived,false) and p.division=any(chosen) and not exists(select 1 from ranked r where r.agent_id=p.id::text))
 select (select coalesce(jsonb_agg(to_jsonb(r) order by r.ap desc,r.agent_name),'[]') from roster r),
 (select coalesce(jsonb_agg(to_jsonb(f) order by f.created_at desc,f.id desc),'[]') from(select id,agent_name,carrier,policy_type,monthly_premium,annual_premium,created_at from sales order by created_at desc,id desc limit 50)f),
 coalesce(sum(annual_premium),0)+adj,case when imported then null else coalesce(sum(monthly_premium),0) end,case when imported then null else count(*) end
 into ranking,feed,ap,mp,deals from sales;
 select coalesce(jsonb_agg(m order by m desc),'[]') into months from (select distinct date_trunc('month',cb.created_at at time zone 'America/Detroit')::date m from public.closed_business cb join public.profiles p on p.id=cb.agent_id left join public.leads l on l.id=cb.lead_id where (case when cb.agent_id='f411ecbb-2477-4cb6-902f-a69db6b6edd6'::uuid then 'division_1bd8c26ef4e9400c866e81425403b721' when cb.agent_id in ('8c14394a-ad5b-48f6-84a2-2cfa6dc23378'::uuid,'7a24126c-5892-4568-80ed-de57215be22d'::uuid) and cb.created_at>=timestamptz '2026-11-01 00:00:00 America/Detroit' then 'vivid_life' else coalesce(l.division,p.division) end)=any(chosen)
 union select month from private.leaderboard_monthly_import where division=any(chosen)) x where m<date_trunc('month',localnow)::date;
 result:=private.live_leaderboard_data(p_division);
 return result||jsonb_build_object('scope_names',(select jsonb_object_agg(id,name) from public.divisions where id=any(scopes)),'rankings',ranking,'today_feed',feed,'available_months',months,'period',jsonb_build_object('key',p_period,'start',startlocal::date,'end',endlocal::date,'label',case when p_period='today' then 'Today' when p_period='week' then 'This week' else to_char(startlocal,'FMMonth YYYY') end,'ap',ap,'mp',mp,'deals',deals,'active_producers',(select count(*) from jsonb_array_elements(ranking) r where (r->>'ap')::numeric>0),'imported',imported,'goal',case when startlocal::date=date '2026-09-01' and p_period in('month','previous') and array['owner','vivid_life']::text[]<@chosen then 100000 end));
end $function$;


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
 join public.divisions d on d.id=(case when cb.agent_id='f411ecbb-2477-4cb6-902f-a69db6b6edd6'::uuid then 'division_1bd8c26ef4e9400c866e81425403b721' when cb.agent_id in ('8c14394a-ad5b-48f6-84a2-2cfa6dc23378'::uuid,'7a24126c-5892-4568-80ed-de57215be22d'::uuid) and cb.created_at>=timestamptz '2026-11-01 00:00:00 America/Detroit' then 'vivid_life' else coalesce(l.division,p.division) end)
 where cb.created_at>=since_at and cb.created_at<=now()
  and (case when cb.agent_id='f411ecbb-2477-4cb6-902f-a69db6b6edd6'::uuid then 'division_1bd8c26ef4e9400c866e81425403b721' when cb.agent_id in ('8c14394a-ad5b-48f6-84a2-2cfa6dc23378'::uuid,'7a24126c-5892-4568-80ed-de57215be22d'::uuid) and cb.created_at>=timestamptz '2026-11-01 00:00:00 America/Detroit' then 'vivid_life' else coalesce(l.division,p.division) end)=any(private.sales_board_divisions());
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
end $function$;


CREATE OR REPLACE FUNCTION private.leaderboard_api_read(p_key_hash text, p_period text DEFAULT 'month'::text, p_month date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare credential private.leaderboard_api_keys%rowtype;
 localnow timestamp:=now() at time zone 'America/Detroit';
 startlocal timestamp;endlocal timestamp;startat timestamptz;endat timestamptz;
 ranking jsonb;total_ap numeric;total_deals bigint;has_imports boolean;
begin
 -- Machine credential boundary, enforced again in addition to function grants.
 if current_user not in ('service_role','postgres') then raise insufficient_privilege;end if;
 if p_key_hash is null or p_key_hash !~ '^[0-9a-f]{64}$' then return jsonb_build_object('status',401);end if;
 select * into credential from private.leaderboard_api_keys where key_hash=p_key_hash for update;
 if not found or credential.revoked_at is not null or credential.expires_at<=now() then return jsonb_build_object('status',401);end if;
 if p_period is null or p_period not in ('today','week','month','previous') or (p_period<>'previous' and p_month is not null) then return jsonb_build_object('status',400);end if;
 if p_period='today' then startlocal:=date_trunc('day',localnow);endlocal:=startlocal+interval '1 day';
 elsif p_period='week' then startlocal:=date_trunc('week',localnow);endlocal:=startlocal+interval '1 week';
 else
  if p_period='previous' and (p_month is null or p_month<>date_trunc('month',p_month)::date or p_month>=date_trunc('month',localnow)::date) then return jsonb_build_object('status',400);end if;
  startlocal:=case when p_period='month' then date_trunc('month',localnow) else p_month::timestamp end;endlocal:=startlocal+interval '1 month';
 end if;
 if credential.window_start>now()-interval '1 minute' and credential.window_count>=60 then return jsonb_build_object('status',429);end if;
 update private.leaderboard_api_keys set last_used_at=now(),
  window_start=case when window_start>now()-interval '1 minute' then window_start else now() end,
  window_count=case when window_start>now()-interval '1 minute' then window_count+1 else 1 end where key_hash=p_key_hash;
 startat:=startlocal at time zone 'America/Detroit';endat:=least(endlocal at time zone 'America/Detroit',now());
 select exists(select 1 from private.leaderboard_monthly_import where p_period in('month','previous') and month=startlocal::date and division=any(credential.allowed_divisions)) into has_imports;
 -- Same date boundaries, attribution, imports, roster, and ordering as private.leaderboard_period.
 -- No customer details, policy details, notes, email, phone, or internal IDs leave this function.
 with sales as materialized (
  select cb.agent_id,p.full_name agent_name,cb.annual_premium
  from public.closed_business cb join public.profiles p on p.id=cb.agent_id left join public.leads l on l.id=cb.lead_id
  where (case when cb.agent_id='f411ecbb-2477-4cb6-902f-a69db6b6edd6'::uuid then 'division_1bd8c26ef4e9400c866e81425403b721' when cb.agent_id in ('8c14394a-ad5b-48f6-84a2-2cfa6dc23378'::uuid,'7a24126c-5892-4568-80ed-de57215be22d'::uuid) and cb.created_at>=timestamptz '2026-11-01 00:00:00 America/Detroit' then 'vivid_life' else coalesce(l.division,p.division) end)=any(credential.allowed_divisions) and cb.created_at>=startat and cb.created_at<endat
 ), actual as (
  select agent_id::text entry_key,max(agent_name) agent_name,sum(annual_premium) ap,count(*) deals from sales group by agent_id
 ), imports as (
  select entry_key,max(display_name) agent_name,sum(ap_adjustment) adjustment from private.leaderboard_monthly_import
  where has_imports and month=startlocal::date and division=any(credential.allowed_divisions) group by entry_key
 ), ranked as (
  select coalesce(a.entry_key,i.entry_key) entry_key,coalesce(a.agent_name,i.agent_name) agent_name,
   coalesce(a.ap,0)+coalesce(i.adjustment,0) annual_premium,coalesce(a.ap,0) recorded_annual_premium,coalesce(i.adjustment,0) imported_annual_premium_adjustment,
   case when i.entry_key is null then coalesce(a.deals,0) end deals from actual a full join imports i using(entry_key)
 ), roster as (
  select * from ranked union all
  select p.id::text,p.full_name,0::numeric,0::numeric,0::numeric,0::bigint from public.profiles p
  where p.role='agent' and p.active and not coalesce(p.archived,false) and p.division=any(credential.allowed_divisions)
   and not exists(select 1 from ranked r where r.entry_key=p.id::text)
 )
 select coalesce(jsonb_agg(jsonb_build_object('agent_name',r.agent_name,'annual_premium',r.annual_premium,
  'recorded_annual_premium',r.recorded_annual_premium,'imported_annual_premium_adjustment',r.imported_annual_premium_adjustment,'deals',r.deals)
  order by r.annual_premium desc,r.agent_name),'[]'::jsonb),coalesce(sum(r.annual_premium),0),case when has_imports then null else coalesce(sum(r.deals),0)::bigint end
 into ranking,total_ap,total_deals from roster r;
 return jsonb_build_object('status',200,'data',jsonb_build_object('scope',credential.scope_name,'as_of',now(),
  'period',jsonb_build_object('key',p_period,'start',startlocal::date,'end_exclusive',endlocal::date),
  'totals',jsonb_build_object('annual_premium',total_ap,'deals',total_deals),'rankings',ranking));
end $function$;


CREATE OR REPLACE FUNCTION private.submitted_deals_api_read(p_key_hash text, p_period text DEFAULT 'month'::text, p_month date DEFAULT NULL::date, p_after uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 200)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare credential private.leaderboard_api_keys%rowtype;
 localnow timestamp:=now() at time zone 'America/Detroit';
 startlocal timestamp;endlocal timestamp;startat timestamptz;endat timestamptz;
 rows_json jsonb; next_id uuid;
begin
 -- Machine credential boundary, enforced again in addition to function grants.
 if current_user not in ('service_role','postgres') then raise insufficient_privilege;end if;
 if p_key_hash is null or p_key_hash !~ '^[0-9a-f]{64}$' then return jsonb_build_object('status',401);end if;
 select * into credential from private.leaderboard_api_keys where key_hash=p_key_hash for update;
 if not found or credential.revoked_at is not null or credential.expires_at<=now() then return jsonb_build_object('status',401);end if;
 if p_period is null or p_period not in ('today','week','month','previous') or (p_period<>'previous' and p_month is not null) then return jsonb_build_object('status',400);end if;
 if p_period='today' then startlocal:=date_trunc('day',localnow);endlocal:=startlocal+interval '1 day';
 elsif p_period='week' then startlocal:=date_trunc('week',localnow);endlocal:=startlocal+interval '1 week';
 else
  if p_period='previous' and (p_month is null or p_month<>date_trunc('month',p_month)::date or p_month>=date_trunc('month',localnow)::date) then return jsonb_build_object('status',400);end if;
  startlocal:=case when p_period='month' then date_trunc('month',localnow) else p_month::timestamp end;endlocal:=startlocal+interval '1 month';
 end if;
 if p_limit is null or p_limit<1 or p_limit>500 then return jsonb_build_object('status',400);end if;
 if credential.window_start>now()-interval '1 minute' and credential.window_count>=60 then return jsonb_build_object('status',429);end if;
 update private.leaderboard_api_keys set last_used_at=now(),
  window_start=case when window_start>now()-interval '1 minute' then window_start else now() end,
  window_count=case when window_start>now()-interval '1 minute' then window_count+1 else 1 end where key_hash=p_key_hash;
 startat:=startlocal at time zone 'America/Detroit';endat:=least(endlocal at time zone 'America/Detroit',now());
 -- Submission records only: never join CRM policies, carrier status or pipeline stages.
 -- Scope stays fixed on the server. The external agency label is deliberately constant.
 with page as materialized (
  select cb.id,cb.agent_id,p.full_name,cb.monthly_premium,cb.annual_premium,cb.created_at
  from public.closed_business cb join public.profiles p on p.id=cb.agent_id
  left join public.leads l on l.id=cb.lead_id
  where (case when cb.agent_id='f411ecbb-2477-4cb6-902f-a69db6b6edd6'::uuid then 'division_1bd8c26ef4e9400c866e81425403b721' when cb.agent_id in ('8c14394a-ad5b-48f6-84a2-2cfa6dc23378'::uuid,'7a24126c-5892-4568-80ed-de57215be22d'::uuid) and cb.created_at>=timestamptz '2026-11-01 00:00:00 America/Detroit' then 'vivid_life' else coalesce(l.division,p.division) end)=any(credential.allowed_divisions)
   and cb.created_at>=startat and cb.created_at<endat
   and (p_after is null or cb.id>p_after)
  order by cb.id limit p_limit+1
 ), numbered as (select *,row_number() over(order by id) rn from page)
 select coalesce(jsonb_agg(jsonb_build_object(
  'deal_id',id,'agent_id',agent_id,'agent_name',coalesce(full_name,''),
  'agency','Vivid Life Advisors','monthly_premium',monthly_premium,
  'annual_premium',annual_premium,'submitted_at',created_at) order by id) filter(where rn<=p_limit),'[]'::jsonb),
  case when count(*)>p_limit then (array_agg(id order by id))[p_limit] else null end
 into rows_json,next_id from numbered;
 return jsonb_build_object('status',200,'data',jsonb_build_object('as_of',now(),
  'period',jsonb_build_object('key',p_period,'start',startlocal::date,'end_exclusive',endlocal::date),
  'deals',rows_json,'next_after',next_id));
end $function$;


CREATE OR REPLACE FUNCTION private.portal_collaboration(p_action text, p_data jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare me public.profiles%rowtype;target_profile public.profiles%rowtype;cid uuid;ids uuid[];cidkey text;mode text;mid bigint;lastid bigint;goalmonth date;targetvalue numeric;goal private.portal_monthly_goals%rowtype;scopevalue text;agencytarget numeric;agencytotal numeric;result jsonb;total numeric;startdate date;enddate date;
begin
 if not private.verified_portal_session() then raise exception 'Verified login required';end if;
 select * into me from public.profiles where id=auth.uid();
 if p_action='people' then return coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',full_name,'division',division) order by full_name) from public.profiles where active and not coalesce(archived,false) and division=any(private.shared_chat_divisions()) and id<>me.id),'[]'::jsonb);end if;
 if p_action='create' then
  select array_agg(distinct x) into ids from (select jsonb_array_elements_text(coalesce(p_data->'members','[]'))::uuid x union select me.id) a;
  if cardinality(ids)<2 or cardinality(ids)>50 or exists(select 1 from unnest(ids) x where not exists(select 1 from public.profiles p where p.id=x and p.active and not coalesce(p.archived,false) and p.division=any(private.shared_chat_divisions()))) then raise exception 'Choose 1 to 49 eligible members';end if;
  if p_data->>'kind' not in ('group','direct') or length(trim(p_data->>'name')) not between 1 and 80 then raise exception 'Enter a chat name';end if;
  if p_data->>'kind'='direct' then
   if cardinality(ids)<>2 then raise exception 'Direct messages need one recipient';end if;
   perform pg_advisory_xact_lock(hashtextextended(array_to_string(ids,','),0));
   select id into cid from private.portal_conversations where kind='direct' and members @>ids and members<@ids limit 1;
  end if;
  if cid is null then insert into private.portal_conversations(name,kind,owner_id,members) values(trim(p_data->>'name'),p_data->>'kind',me.id,ids) returning id into cid;end if;
  return jsonb_build_object('id',cid);
 end if;
 if p_action='list' then return jsonb_build_object('chats',coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'name',case when c.kind='direct' then (select full_name from public.profiles where id=any(c.members) and id<>me.id limit 1) else c.name end,'kind',c.kind,'owner_id',c.owner_id,'members',c.members,'mode',coalesce(pr.mode,'all'),'last_id',coalesce(msg.last_id,0),'unread',(select count(*) from private.portal_conversation_messages m where m.conversation_id=c.id and m.id>coalesce(pr.last_read,0) and m.author_id<>me.id),'mention_unread',(select count(*) from private.portal_conversation_messages m where m.conversation_id=c.id and m.id>coalesce(pr.last_read,0) and m.author_id<>me.id and position('@'||me.full_name in m.body)>0)) order by coalesce(msg.last_id,0) desc,c.created_at desc) from private.portal_conversations c left join private.portal_chat_preferences pr on pr.user_id=me.id and pr.chat_key='group:'||c.id left join lateral(select max(id) last_id from private.portal_conversation_messages where conversation_id=c.id) msg on true where private.portal_conversation_access(c.id)),'[]'::jsonb),'channels',coalesce((select jsonb_agg(jsonb_build_object('room',room,'unread',(select count(*) from public.chat_messages m where m.channel=room and m.division=any(private.shared_chat_divisions()) and m.id>coalesce(pr.last_read,0) and m.author_id<>me.id),'mode',coalesce(pr.mode,'all'))) from unnest(array['general','deals','resources']) room left join private.portal_chat_preferences pr on pr.user_id=me.id and pr.chat_key='channel:'||room),'[]'::jsonb));end if;
 if p_action in ('messages','send','members','add_members') then
  cid=(p_data->>'id')::uuid;
  if not private.portal_conversation_access(cid) then raise exception 'Chat access denied';end if;
  if p_action='messages' then return coalesce((select jsonb_agg(to_jsonb(t) order by id) from (select m.id,m.body,m.author_id,p.full_name author_name,m.created_at from private.portal_conversation_messages m join public.profiles p on p.id=m.author_id where m.conversation_id=cid order by m.id desc limit 100) t),'[]'::jsonb);end if;
  if p_action='members' then return coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'name',p.full_name)) from public.profiles p join private.portal_conversations c on p.id=any(c.members) where c.id=cid),'[]'::jsonb);end if;
  if p_action='add_members' then
   if not exists(select 1 from private.portal_conversations where id=cid and owner_id=me.id and kind='group') then raise exception 'Only the group creator can add members';end if;
   select array_agg(distinct x) into ids from (select unnest(members) x from private.portal_conversations where id=cid union select jsonb_array_elements_text(p_data->'members')::uuid) t;
   if cardinality(ids)>50 or exists(select 1 from unnest(ids) x where not exists(select 1 from public.profiles p where p.id=x and active and not coalesce(archived,false) and division=any(private.shared_chat_divisions()))) then raise exception 'Invalid group members';end if;
   update private.portal_conversations set members=ids where id=cid;return '{}'::jsonb;
  end if;
  perform pg_advisory_xact_lock(hashtextextended(me.id::text,1));
  select id into mid from private.portal_conversation_messages where author_id=me.id and request_id=(p_data->>'request_id')::uuid and conversation_id=cid;
  if mid is not null then return jsonb_build_object('id',mid);end if;
  if (select count(*) from private.portal_conversation_messages where author_id=me.id and created_at>now()-interval '1 minute')>=30 then raise exception 'Please wait before sending more messages';end if;
  insert into private.portal_conversation_messages(conversation_id,author_id,body,request_id) values(cid,me.id,trim(p_data->>'body'),(p_data->>'request_id')::uuid) returning id into mid;return jsonb_build_object('id',mid);
 end if;
 if p_action in ('read','preference') then
  cidkey=p_data->>'key';
  if cidkey like 'group:%' then if not private.portal_conversation_access(substring(cidkey from 7)::uuid) then raise exception 'Chat access denied';end if;select max(id) into lastid from private.portal_conversation_messages where conversation_id=substring(cidkey from 7)::uuid;
  elsif cidkey in ('channel:general','channel:deals','channel:resources') then select max(id) into lastid from public.chat_messages where channel=substring(cidkey from 9) and division=any(private.shared_chat_divisions());else raise exception 'Invalid chat';end if;
  if p_action='read' then insert into private.portal_chat_preferences(user_id,chat_key,last_read) values(me.id,cidkey,least(coalesce((p_data->>'last_id')::bigint,0),coalesce(lastid,0))) on conflict(user_id,chat_key) do update set last_read=greatest(private.portal_chat_preferences.last_read,excluded.last_read);
  else mode=p_data->>'mode';if mode not in ('all','mentions','muted') then raise exception 'Invalid notification preference';end if;insert into private.portal_chat_preferences(user_id,chat_key,mode) values(me.id,cidkey,mode) on conflict(user_id,chat_key) do update set mode=excluded.mode;end if;return '{}'::jsonb;
 end if;
 if p_action in ('goal','set_goal') then
  select * into target_profile from public.profiles where id=coalesce((p_data->>'user_id')::uuid,me.id) and active and not coalesce(archived,false);
  if not found or not(target_profile.id=me.id or (me.role='admin' and target_profile.division=any(private.my_admin_divisions()))) then raise exception 'Goal access denied';end if;
  goalmonth=date_trunc('month',coalesce((p_data->>'month')::date,(now() at time zone 'America/Detroit')::date))::date;
  if p_action='set_goal' then
   if me.role<>'admin' then raise exception 'Only admins can set goals';end if;
   targetvalue=(p_data->>'target')::numeric;scopevalue=case when target_profile.role='admin' then 'agency' else 'personal' end;
   if coalesce((p_data->>'apply_all')::boolean,false) then
    if not me.is_super_admin then raise exception 'Only Master can set all-agency targets';end if;
    insert into private.portal_agency_goals(division,month,target,set_by) select id,goalmonth,targetvalue,me.id from public.divisions where not archived and id<>'legacy_life' on conflict(division,month) do update set target=excluded.target,set_by=excluded.set_by;
   elsif scopevalue='agency' then insert into private.portal_agency_goals(division,month,target,set_by) values(target_profile.division,goalmonth,targetvalue,me.id) on conflict(division,month) do update set target=excluded.target,set_by=excluded.set_by;end if;
   insert into private.portal_monthly_goals(user_id,month,target,scope,set_by) values(target_profile.id,goalmonth,targetvalue,scopevalue,me.id) on conflict(user_id,month) do update set target=excluded.target,scope=excluded.scope,set_by=excluded.set_by,updated_at=now();
  end if;
  select * into goal from private.portal_monthly_goals where user_id=target_profile.id and month=goalmonth;
  scopevalue=coalesce(goal.scope,case when target_profile.role='admin' then 'agency' else 'personal' end);
  startdate=goalmonth;enddate=(goalmonth+interval '1 month')::date;
  select coalesce(sum(b.annual_premium),0) into total from public.closed_business b join public.profiles p on p.id=b.agent_id left join public.leads l on l.id=b.lead_id where b.created_at >= (startdate::timestamp at time zone 'America/Detroit') and b.created_at < least((enddate::timestamp at time zone 'America/Detroit'),now()) and (case when target_profile.is_super_admin then exists(select 1 from public.divisions d where d.id=(case when b.agent_id='f411ecbb-2477-4cb6-902f-a69db6b6edd6'::uuid then 'division_1bd8c26ef4e9400c866e81425403b721' when b.agent_id in ('8c14394a-ad5b-48f6-84a2-2cfa6dc23378'::uuid,'7a24126c-5892-4568-80ed-de57215be22d'::uuid) and b.created_at>=timestamptz '2026-11-01 00:00:00 America/Detroit' then 'vivid_life' else coalesce(l.division,p.division) end) and not d.archived and d.id<>'legacy_life') when scopevalue='agency' then (case when b.agent_id='f411ecbb-2477-4cb6-902f-a69db6b6edd6'::uuid then 'division_1bd8c26ef4e9400c866e81425403b721' when b.agent_id in ('8c14394a-ad5b-48f6-84a2-2cfa6dc23378'::uuid,'7a24126c-5892-4568-80ed-de57215be22d'::uuid) and b.created_at>=timestamptz '2026-11-01 00:00:00 America/Detroit' then 'vivid_life' else coalesce(l.division,p.division) end)=target_profile.division else p.id=target_profile.id end);
  total=total+coalesce((select sum(i.ap_adjustment) from private.leaderboard_monthly_import i join public.divisions d on d.id=i.division where i.month=goalmonth and (case when target_profile.is_super_admin then not d.archived and d.id<>'legacy_life' when scopevalue='agency' then i.division=target_profile.division else i.agent_id=target_profile.id or i.entry_key=target_profile.id::text end)),0);
  select target into agencytarget from private.portal_agency_goals where division=target_profile.division and month=goalmonth;
  select coalesce(sum(b.annual_premium),0) into agencytotal from public.closed_business b join public.profiles p on p.id=b.agent_id left join public.leads l on l.id=b.lead_id where b.created_at >= (startdate::timestamp at time zone 'America/Detroit') and b.created_at < least((enddate::timestamp at time zone 'America/Detroit'),now()) and (case when b.agent_id='f411ecbb-2477-4cb6-902f-a69db6b6edd6'::uuid then 'division_1bd8c26ef4e9400c866e81425403b721' when b.agent_id in ('8c14394a-ad5b-48f6-84a2-2cfa6dc23378'::uuid,'7a24126c-5892-4568-80ed-de57215be22d'::uuid) and b.created_at>=timestamptz '2026-11-01 00:00:00 America/Detroit' then 'vivid_life' else coalesce(l.division,p.division) end)=target_profile.division;
  agencytotal=agencytotal+coalesce((select sum(ap_adjustment) from private.leaderboard_monthly_import where month=goalmonth and division=target_profile.division),0);
  return jsonb_build_object('agency_target',agencytarget,'agency_production',agencytotal,'user_id',target_profile.id,'name',target_profile.full_name,'month',goalmonth,'target',case when target_profile.is_super_admin then goal.target when scopevalue='agency' then agencytarget else goal.target end,'production',total,'scope',case when target_profile.is_super_admin then 'organization' else scopevalue end,'division',target_profile.division,'set_by',(select full_name from public.profiles where id=goal.set_by));
 end if;
 raise exception 'Unknown action';
end;$function$;


CREATE OR REPLACE FUNCTION private.chat_deal_announcement()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_div text; v_name text;
begin
 if tg_op='DELETE' then
  update public.chat_messages set deal=jsonb_build_object('withdrawn',true),body='This deal was removed from Closed Business.' where source_deal_id=old.id;
  return old;
 end if;
 select (case when new.agent_id='f411ecbb-2477-4cb6-902f-a69db6b6edd6'::uuid then 'division_1bd8c26ef4e9400c866e81425403b721' when new.agent_id in ('8c14394a-ad5b-48f6-84a2-2cfa6dc23378'::uuid,'7a24126c-5892-4568-80ed-de57215be22d'::uuid) and new.created_at>=timestamptz '2026-11-01 00:00:00 America/Detroit' then 'vivid_life' else coalesce(l.division,p.division) end),p.full_name into v_div,v_name from public.profiles p left join public.leads l on l.id=new.lead_id where p.id=new.agent_id;
 if v_div is null then return new; end if;
 insert into public.chat_messages(division,channel,author_id,author_name,kind,source_deal_id,deal)
 values(v_div,'deals',new.agent_id,coalesce(v_name,'Team member'),'deal',new.id,
 jsonb_build_object('carrier',new.carrier,'policy_type',new.policy_type,'monthly_premium',new.monthly_premium,'annual_premium',new.annual_premium))
 on conflict(source_deal_id) do update set division=excluded.division,author_id=excluded.author_id,author_name=excluded.author_name,deal=excluded.deal,body='';
 return new;
end $function$;

