create table private.portal_conversations(id uuid primary key default gen_random_uuid(),name text not null check(length(name) between 1 and 80),kind text not null check(kind in ('group','direct')),owner_id uuid not null references public.profiles(id),members uuid[] not null,created_at timestamptz not null default now());
create table private.portal_conversation_messages(id bigint generated always as identity primary key,conversation_id uuid not null references private.portal_conversations(id),author_id uuid not null references public.profiles(id),body text not null check(length(body) between 1 and 4000),request_id uuid not null,created_at timestamptz not null default now(),unique(author_id,request_id));
create index portal_conversation_message_room on private.portal_conversation_messages(conversation_id,id desc);
create table private.portal_chat_preferences(user_id uuid not null references public.profiles(id),chat_key text not null,last_read bigint not null default 0,mode text not null default 'all' check(mode in ('all','mentions','muted')),primary key(user_id,chat_key));
create table private.portal_monthly_goals(user_id uuid not null references public.profiles(id),month date not null check(extract(day from month)=1),target numeric not null check(target>0 and target<=100000000),scope text not null check(scope in ('personal','agency')),set_by uuid not null references public.profiles(id),updated_at timestamptz not null default now(),primary key(user_id,month));
alter table private.portal_conversations enable row level security;
alter table private.portal_conversation_messages enable row level security;
alter table private.portal_chat_preferences enable row level security;
alter table private.portal_monthly_goals enable row level security;
revoke all on private.portal_conversations,private.portal_conversation_messages,private.portal_chat_preferences,private.portal_monthly_goals from public,anon,authenticated;
create function private.portal_conversation_access(p_id uuid) returns boolean language sql stable security definer set search_path='' as $$ select private.verified_portal_session() and exists(select 1 from private.portal_conversations c where c.id=p_id and auth.uid()=any(c.members) and not exists(select 1 from public.profiles p where p.id=any(c.members) and (not p.active or coalesce(p.archived,false) or not(p.division=any(private.shared_chat_divisions()))))); $$;
create function private.portal_collaboration(p_action text,p_data jsonb default '{}'::jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare me public.profiles%rowtype;target_profile public.profiles%rowtype;cid uuid;ids uuid[];cidkey text;mode text;mid bigint;lastid bigint;goalmonth date;targetvalue numeric;goal private.portal_monthly_goals%rowtype;scopevalue text;result jsonb;total numeric;startdate date;enddate date;
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
   insert into private.portal_monthly_goals(user_id,month,target,scope,set_by) values(target_profile.id,goalmonth,targetvalue,scopevalue,me.id) on conflict(user_id,month) do update set target=excluded.target,scope=excluded.scope,set_by=excluded.set_by,updated_at=now();
  end if;
  select * into goal from private.portal_monthly_goals where user_id=target_profile.id and month=goalmonth;
  scopevalue=coalesce(goal.scope,case when target_profile.role='admin' then 'agency' else 'personal' end);
  startdate=goalmonth;enddate=(goalmonth+interval '1 month')::date;
  select coalesce(sum(b.annual_premium),0) into total from public.closed_business b join public.profiles p on p.id=b.agent_id where b.application_date>=startdate and b.application_date<enddate and (case when scopevalue='agency' then p.division=target_profile.division else p.id=target_profile.id end);
  return jsonb_build_object('user_id',target_profile.id,'name',target_profile.full_name,'month',goalmonth,'target',goal.target,'production',total,'scope',scopevalue,'division',target_profile.division,'set_by',(select full_name from public.profiles where id=goal.set_by));
 end if;
 raise exception 'Unknown action';
end;$$;
create function public.portal_collaboration(p_action text,p_data jsonb default '{}'::jsonb) returns jsonb language sql security invoker set search_path='' as $$select private.portal_collaboration(p_action,p_data);$$;
revoke all on function private.portal_collaboration(text,jsonb),public.portal_collaboration(text,jsonb),private.portal_conversation_access(uuid) from public,anon;
grant execute on function private.portal_collaboration(text,jsonb),public.portal_collaboration(text,jsonb),private.portal_conversation_access(uuid) to authenticated;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values ('private-chat-media','private-chat-media',false,10485760,array['image/png','image/jpeg','image/webp','image/gif']);
create policy private_conversation_media_read on storage.objects for select to authenticated using(bucket_id='private-chat-media' and case when (storage.foldername(name))[1] ~ '^[0-9a-f-]{36}$' then private.portal_conversation_access(((storage.foldername(name))[1])::uuid) else false end);
create policy private_conversation_media_upload on storage.objects for insert to authenticated with check(bucket_id='private-chat-media' and case when (storage.foldername(name))[1] ~ '^[0-9a-f-]{36}$' then private.portal_conversation_access(((storage.foldername(name))[1])::uuid) else false end and (storage.foldername(name))[2]=(select auth.uid())::text);
