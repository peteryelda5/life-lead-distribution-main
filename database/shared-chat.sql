create or replace function private.shared_chat_divisions() returns text[] language sql stable security definer set search_path='' as $$select private.sales_board_divisions()$$;
revoke all on function private.shared_chat_divisions() from public,anon;
grant execute on function private.shared_chat_divisions() to authenticated;
alter policy chat_read_scoped on public.chat_messages using (division=any(private.shared_chat_divisions()));
CREATE OR REPLACE FUNCTION private.chat_members(p_division text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if cardinality(private.shared_chat_divisions())=0 or (p_division is distinct from 'all' and not coalesce(p_division=any(private.shared_chat_divisions()),false)) then raise exception 'Division access denied' using errcode='42501';end if;
 return (select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.full_name) order by p.full_name),'[]') from public.profiles p where p.active and not coalesce(p.archived,false) and p.division=any(private.shared_chat_divisions()));
end $function$
;
CREATE OR REPLACE FUNCTION private.chat_react(p_message_id bigint, p_emoji text, p_active boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare m public.chat_messages%rowtype;
begin
 select * into m from public.chat_messages where id=p_message_id;
 if not found or not coalesce(m.division=any(private.shared_chat_divisions()),false) or m.kind<>'deal' then raise exception 'Deal access denied' using errcode='42501';end if;
 if p_emoji not in ('🎉','🔥','👏','💪') or p_emoji is null then raise exception 'Unsupported reaction';end if;
 if p_active then insert into private.chat_reactions values(p_message_id,auth.uid(),p_emoji) on conflict do nothing;
 else delete from private.chat_reactions where message_id=p_message_id and user_id=auth.uid() and emoji=p_emoji;end if;
 -- Notify existing RLS-filtered message subscriptions without exposing member reaction records.
 update public.chat_messages set body=body where id=p_message_id;
end $function$
;
CREATE OR REPLACE FUNCTION public.chat_scopes()
 RETURNS text[]
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$select private.shared_chat_divisions()$function$
;
CREATE OR REPLACE FUNCTION private.chat_send(p_division text, p_channel text, p_body text, p_request_id uuid)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_id bigint; v_name text;
begin
 if auth.uid() is null or not coalesce(p_division=any(private.shared_chat_divisions()),false) then raise exception 'Chat access denied'; end if;
 if p_channel not in ('general','deals','resources') or p_channel is null then raise exception 'Choose a chat channel'; end if;
 if p_request_id is null or p_body is null or char_length(btrim(p_body)) not between 1 and 4000 then raise exception 'Message must contain 1–4000 characters'; end if;
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text,738));
 select id into v_id from public.chat_messages where author_id=auth.uid() and request_id=p_request_id;
 if found then return v_id; end if;
 if (select count(*) from public.chat_messages where author_id=auth.uid() and kind='message' and created_at>now()-interval '1 minute')>=30 then raise exception 'Please wait a moment before sending more messages'; end if;
 select full_name into v_name from public.profiles where id=auth.uid();
 insert into public.chat_messages(division,channel,author_id,author_name,body,request_id)
 values(p_division,p_channel,auth.uid(),coalesce(v_name,'Team member'),btrim(p_body),p_request_id) returning id into v_id;
 return v_id;
end $function$
;
CREATE OR REPLACE FUNCTION private.chat_send_social(p_division text, p_channel text, p_body text, p_request_id uuid, p_reply_to bigint DEFAULT NULL::bigint, p_mentions uuid[] DEFAULT '{}'::uuid[])
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare mid bigint; members jsonb;
begin
 members:=private.chat_members(p_division);
 if cardinality(p_mentions)>20 or exists(select 1 from unnest(p_mentions) u where not exists(select 1 from jsonb_array_elements(members) r where r->>'id'=u::text)) then raise exception 'Choose mentions from this workspace';end if;
 if p_reply_to is not null and not exists(select 1 from public.chat_messages where id=p_reply_to and division=any(private.shared_chat_divisions()) and channel=p_channel) then raise exception 'Reply must be in the same channel';end if;
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text,738));
 select id into mid from public.chat_messages where author_id=auth.uid() and request_id=p_request_id;
 if found then return mid;end if;
 mid:=private.chat_send(p_division,p_channel,p_body,p_request_id);
 update public.chat_messages set reply_to=p_reply_to,mention_ids=coalesce(p_mentions,'{}') where id=mid;
 return mid;
end $function$
;
CREATE OR REPLACE FUNCTION private.chat_social_state(p_division text, p_channel text, p_ids bigint[] DEFAULT '{}'::bigint[])
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare members jsonb; scopes text[];
begin
 members:=private.chat_members(p_division);
 scopes:=case when p_division='all' then private.shared_chat_divisions() else array[p_division] end;
 if cardinality(p_ids)>1000 then raise exception 'Too many messages';end if;
 return jsonb_build_object('members',members,
 'replies',(select coalesce(jsonb_agg(jsonb_build_object('id',m.id,'author_name',m.author_name,'body',case when m.kind='deal' then 'Closed deal' else left(m.body,200) end)),'[]') from public.chat_messages m where m.division=any(private.shared_chat_divisions()) and m.channel=p_channel and m.id in(select c.reply_to from public.chat_messages c where c.id=any(p_ids) and c.division=any(scopes) and c.channel=p_channel)),
 'reactions',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from(select r.message_id,r.emoji,count(*) count,bool_or(r.user_id=auth.uid()) mine from private.chat_reactions r join public.chat_messages m on m.id=r.message_id where m.division=any(private.shared_chat_divisions()) and m.channel=p_channel and m.id=any(p_ids) group by r.message_id,r.emoji)x),
 'pins',(select coalesce(jsonb_agg(jsonb_build_object('id',s.id,'title',s.title) order by s.title),'[]') from private.chat_pins p join public.sales_scripts s on s.id=p.script_id where p.division=any(scopes) and p.division=any(private.leaderboard_divisions()) and p.channel=p_channel and s.division=p.division));
end $function$
;
CREATE OR REPLACE FUNCTION private.chat_unread()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select coalesce(jsonb_agg(to_jsonb(x)),'[]') from (
 select d.division,c.channel,count(m.id) unread,count(m.id) filter(where auth.uid()=any(m.mention_ids)) mentions
 from unnest(private.shared_chat_divisions()) d(division) cross join (values('general'),('deals'),('resources'))c(channel)
 left join private.chat_reads r on r.user_id=auth.uid() and r.division=d.division and r.channel=c.channel
 left join public.chat_messages m on m.division=d.division and m.channel=c.channel and m.id>coalesce(r.last_id,0) and m.author_id<>auth.uid()
 group by d.division,c.channel)x;
$function$
;
create or replace function private.chat_mark_read(p_division text,p_channel text,p_last_id bigint) returns void language plpgsql security definer set search_path='' as $$
declare scopes text[];
begin
 scopes:=private.shared_chat_divisions();
 if cardinality(scopes)=0 or (p_division is distinct from 'all' and not coalesce(p_division=any(scopes),false)) then raise exception 'Chat access denied' using errcode='42501';end if;
 insert into private.chat_reads(user_id,division,channel,last_id)
 select auth.uid(),division,channel,max(id) from public.chat_messages
 where division=any(scopes) and (p_division='all' or division=p_division) and channel=p_channel and id<=p_last_id group by division,channel
 on conflict(user_id,division,channel) do update set last_id=greatest(private.chat_reads.last_id,excluded.last_id);
end $$;

alter table public.chat_messages drop constraint chat_messages_channel_check;
alter table public.chat_messages add constraint chat_messages_channel_check check(channel in ('general','deals','resources'));
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('chat-resources','chat-resources',false,20971520,array['application/pdf','application/msword','application/vnd.openxmlformats-officedocument.wordprocessingml.document','application/vnd.ms-excel','application/vnd.openxmlformats-officedocument.spreadsheetml.sheet','application/vnd.ms-powerpoint','application/vnd.openxmlformats-officedocument.presentationml.presentation','text/plain','text/csv','image/png','image/jpeg']);
create policy chat_resources_read on storage.objects for select to authenticated using(bucket_id='chat-resources' and (storage.foldername(name))[1]=any(private.shared_chat_divisions()));
create policy chat_resources_upload on storage.objects for insert to authenticated with check(bucket_id='chat-resources' and (storage.foldername(name))[1]=any(private.my_admin_divisions()) and (storage.foldername(name))[1]=any(private.shared_chat_divisions()) and (storage.foldername(name))[2]=(select auth.uid())::text);
create or replace function private.chat_pin(p_division text,p_channel text,p_script_id uuid,p_active boolean) returns void language plpgsql security definer set search_path='' as $$
begin
 if not coalesce(p_division=any(private.my_admin_divisions()),false) then raise exception 'Only workspace admins can pin scripts' using errcode='42501';end if;
 if p_channel is null or p_channel not in ('general','deals','resources') then raise exception 'Invalid channel';end if;
 if not exists(select 1 from public.sales_scripts where id=p_script_id and division=p_division) then raise exception 'Choose a script from this division';end if;
 if p_active then insert into private.chat_pins values(p_division,p_channel,p_script_id,auth.uid()) on conflict do nothing;
 else delete from private.chat_pins where division=p_division and channel=p_channel and script_id=p_script_id;end if;
end $$;
