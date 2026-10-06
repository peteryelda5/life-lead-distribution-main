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
  select coalesce(sum(b.annual_premium),0) into total from public.closed_business b join public.profiles p on p.id=b.agent_id left join public.leads l on l.id=b.lead_id where b.created_at >= (startdate::timestamp at time zone 'America/Detroit') and b.created_at < least((enddate::timestamp at time zone 'America/Detroit'),now()) and (case when target_profile.is_super_admin then exists(select 1 from public.divisions d where d.id=coalesce(l.division,p.division) and not d.archived and d.id<>'legacy_life') when scopevalue='agency' then coalesce(l.division,p.division)=target_profile.division else p.id=target_profile.id end);
  total=total+coalesce((select sum(i.ap_adjustment) from private.leaderboard_monthly_import i join public.divisions d on d.id=i.division where i.month=goalmonth and (case when target_profile.is_super_admin then not d.archived and d.id<>'legacy_life' when scopevalue='agency' then i.division=target_profile.division else i.agent_id=target_profile.id or i.entry_key=target_profile.id::text end)),0);
  select target into agencytarget from private.portal_agency_goals where division=target_profile.division and month=goalmonth;
  select coalesce(sum(b.annual_premium),0) into agencytotal from public.closed_business b join public.profiles p on p.id=b.agent_id left join public.leads l on l.id=b.lead_id where b.created_at >= (startdate::timestamp at time zone 'America/Detroit') and b.created_at < least((enddate::timestamp at time zone 'America/Detroit'),now()) and coalesce(l.division,p.division)=target_profile.division;
  agencytotal=agencytotal+coalesce((select sum(ap_adjustment) from private.leaderboard_monthly_import where month=goalmonth and division=target_profile.division),0);
  return jsonb_build_object('agency_target',agencytarget,'agency_production',agencytotal,'user_id',target_profile.id,'name',target_profile.full_name,'month',goalmonth,'target',case when target_profile.is_super_admin then goal.target when scopevalue='agency' then agencytarget else goal.target end,'production',total,'scope',case when target_profile.is_super_admin then 'organization' else scopevalue end,'division',target_profile.division,'set_by',(select full_name from public.profiles where id=goal.set_by));
 end if;
 raise exception 'Unknown action';
end;$function$
