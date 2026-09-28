-- Division-scoped chat collaboration. Public wrappers retain authenticated-only access.
alter table public.chat_messages add column if not exists reply_to bigint references public.chat_messages(id) on delete set null;
alter table public.chat_messages add column if not exists mention_ids uuid[] not null default '{}';
create table if not exists private.chat_reads(user_id uuid not null references public.profiles(id) on delete cascade,division text not null,channel text not null,last_id bigint not null default 0,primary key(user_id,division,channel));
create table if not exists private.chat_reactions(message_id bigint not null references public.chat_messages(id) on delete cascade,user_id uuid not null references public.profiles(id) on delete cascade,emoji text not null,primary key(message_id,user_id,emoji));
create table if not exists private.chat_pins(division text not null,channel text not null,script_id uuid not null references public.sales_scripts(id) on delete cascade,created_by uuid not null,primary key(division,channel,script_id));
alter table private.chat_reads enable row level security;
alter table private.chat_reactions enable row level security;
alter table private.chat_pins enable row level security;
revoke all on private.chat_reads,private.chat_reactions,private.chat_pins from public,anon,authenticated;

create or replace function private.chat_members(p_division text) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not coalesce(p_division=any(private.leaderboard_divisions()),false) then raise exception 'Division access denied' using errcode='42501';end if;
 return (select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.full_name) order by p.full_name),'[]') from public.profiles p where p.active and not coalesce(p.archived,false) and (p.division=p_division or (p.role='admin' and (p.is_super_admin or exists(select 1 from private.admin_division_access a where a.user_id=p.id and a.division=p_division)))));
end $$;
create or replace function private.chat_send_social(p_division text,p_channel text,p_body text,p_request_id uuid,p_reply_to bigint default null,p_mentions uuid[] default '{}') returns bigint language plpgsql security definer set search_path='' as $$
declare mid bigint; members jsonb;
begin
 members:=private.chat_members(p_division);
 if cardinality(p_mentions)>20 or exists(select 1 from unnest(p_mentions) u where not exists(select 1 from jsonb_array_elements(members) r where r->>'id'=u::text)) then raise exception 'Choose mentions from this workspace';end if;
 if p_reply_to is not null and not exists(select 1 from public.chat_messages where id=p_reply_to and division=p_division and channel=p_channel) then raise exception 'Reply must be in the same channel';end if;
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text,738));
 select id into mid from public.chat_messages where author_id=auth.uid() and request_id=p_request_id;
 if found then return mid;end if;
 mid:=private.chat_send(p_division,p_channel,p_body,p_request_id);
 update public.chat_messages set reply_to=p_reply_to,mention_ids=coalesce(p_mentions,'{}') where id=mid;
 return mid;
end $$;
create or replace function private.chat_social_state(p_division text,p_channel text,p_ids bigint[] default '{}') returns jsonb language plpgsql stable security definer set search_path='' as $$
declare members jsonb;
begin
 members:=private.chat_members(p_division);
 if cardinality(p_ids)>1000 then raise exception 'Too many messages';end if;
 return jsonb_build_object('members',members,
 'replies',(select coalesce(jsonb_agg(jsonb_build_object('id',m.id,'author_name',m.author_name,'body',case when m.kind='deal' then 'Closed deal' else left(m.body,200) end)),'[]') from public.chat_messages m where m.division=p_division and m.channel=p_channel and m.id in(select c.reply_to from public.chat_messages c where c.id=any(p_ids) and c.division=p_division and c.channel=p_channel)),
 'reactions',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from(select r.message_id,r.emoji,count(*) count,bool_or(r.user_id=auth.uid()) mine from private.chat_reactions r join public.chat_messages m on m.id=r.message_id where m.division=p_division and m.channel=p_channel and m.id=any(p_ids) group by r.message_id,r.emoji)x),
 'pins',(select coalesce(jsonb_agg(jsonb_build_object('id',s.id,'title',s.title) order by s.title),'[]') from private.chat_pins p join public.sales_scripts s on s.id=p.script_id where p.division=p_division and p.channel=p_channel and s.division=p_division));
end $$;
create or replace function private.chat_react(p_message_id bigint,p_emoji text,p_active boolean) returns void language plpgsql security definer set search_path='' as $$
declare m public.chat_messages%rowtype;
begin
 select * into m from public.chat_messages where id=p_message_id;
 if not found or not coalesce(m.division=any(private.leaderboard_divisions()),false) or m.kind<>'deal' then raise exception 'Deal access denied' using errcode='42501';end if;
 if p_emoji not in ('🎉','🔥','👏','💪') or p_emoji is null then raise exception 'Unsupported reaction';end if;
 if p_active then insert into private.chat_reactions values(p_message_id,auth.uid(),p_emoji) on conflict do nothing;
 else delete from private.chat_reactions where message_id=p_message_id and user_id=auth.uid() and emoji=p_emoji;end if;
 -- Notify existing RLS-filtered message subscriptions without exposing member reaction records.
 update public.chat_messages set body=body where id=p_message_id;
end $$;
create or replace function private.chat_pin(p_division text,p_channel text,p_script_id uuid,p_active boolean) returns void language plpgsql security definer set search_path='' as $$
begin
 if not coalesce(p_division=any(private.my_admin_divisions()),false) then raise exception 'Only workspace admins can pin scripts' using errcode='42501';end if;
 if p_channel is null or p_channel not in ('general','deals') then raise exception 'Invalid channel';end if;
 if not exists(select 1 from public.sales_scripts where id=p_script_id and division=p_division) then raise exception 'Choose a script from this division';end if;
 if p_active then insert into private.chat_pins values(p_division,p_channel,p_script_id,auth.uid()) on conflict do nothing;
 else delete from private.chat_pins where division=p_division and channel=p_channel and script_id=p_script_id;end if;
end $$;
create or replace function private.chat_unread() returns jsonb language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(to_jsonb(x)),'[]') from (
 select d.division,c.channel,count(m.id) unread,count(m.id) filter(where auth.uid()=any(m.mention_ids)) mentions
 from unnest(private.leaderboard_divisions()) d(division) cross join (values('general'),('deals'))c(channel)
 left join private.chat_reads r on r.user_id=auth.uid() and r.division=d.division and r.channel=c.channel
 left join public.chat_messages m on m.division=d.division and m.channel=c.channel and m.id>coalesce(r.last_id,0) and m.author_id<>auth.uid()
 group by d.division,c.channel)x;
$$;
create or replace function private.chat_mark_read(p_division text,p_channel text,p_last_id bigint) returns void language plpgsql security definer set search_path='' as $$
declare lastid bigint;
begin
 if not coalesce(p_division=any(private.leaderboard_divisions()),false) then raise exception 'Division access denied' using errcode='42501';end if;
 select max(id) into lastid from public.chat_messages where division=p_division and channel=p_channel and id<=p_last_id;
 if lastid is null then return;end if;
 insert into private.chat_reads values(auth.uid(),p_division,p_channel,lastid) on conflict(user_id,division,channel) do update set last_id=greatest(private.chat_reads.last_id,excluded.last_id);
end $$;
-- Invoker wrappers expose only explicitly granted RPCs; helpers have empty search paths.
create or replace function public.chat_members(p_division text) returns jsonb language sql security invoker set search_path='' as $$ select private.chat_members(p_division); $$;
revoke all on function public.chat_members(text) from public,anon;
grant execute on function public.chat_members(text) to authenticated;
revoke all on function private.chat_members(text) from public,anon;
grant execute on function private.chat_members(text) to authenticated;
create or replace function public.chat_send_social(p_division text,p_channel text,p_body text,p_request_id uuid,p_reply_to bigint default null,p_mentions uuid[] default '{}') returns bigint language sql security invoker set search_path='' as $$ select private.chat_send_social(p_division,p_channel,p_body,p_request_id,p_reply_to,p_mentions); $$;
revoke all on function public.chat_send_social(text,text,text,uuid,bigint,uuid[]) from public,anon;
grant execute on function public.chat_send_social(text,text,text,uuid,bigint,uuid[]) to authenticated;
revoke all on function private.chat_send_social(text,text,text,uuid,bigint,uuid[]) from public,anon;
grant execute on function private.chat_send_social(text,text,text,uuid,bigint,uuid[]) to authenticated;
create or replace function public.chat_social_state(p_division text,p_channel text,p_ids bigint[] default '{}') returns jsonb language sql security invoker set search_path='' as $$ select private.chat_social_state(p_division,p_channel,p_ids); $$;
revoke all on function public.chat_social_state(text,text,bigint[]) from public,anon;
grant execute on function public.chat_social_state(text,text,bigint[]) to authenticated;
revoke all on function private.chat_social_state(text,text,bigint[]) from public,anon;
grant execute on function private.chat_social_state(text,text,bigint[]) to authenticated;
create or replace function public.chat_react(p_message_id bigint,p_emoji text,p_active boolean) returns void language sql security invoker set search_path='' as $$ select private.chat_react(p_message_id,p_emoji,p_active); $$;
revoke all on function public.chat_react(bigint,text,boolean) from public,anon;
grant execute on function public.chat_react(bigint,text,boolean) to authenticated;
revoke all on function private.chat_react(bigint,text,boolean) from public,anon;
grant execute on function private.chat_react(bigint,text,boolean) to authenticated;
create or replace function public.chat_pin(p_division text,p_channel text,p_script_id uuid,p_active boolean) returns void language sql security invoker set search_path='' as $$ select private.chat_pin(p_division,p_channel,p_script_id,p_active); $$;
revoke all on function public.chat_pin(text,text,uuid,boolean) from public,anon;
grant execute on function public.chat_pin(text,text,uuid,boolean) to authenticated;
revoke all on function private.chat_pin(text,text,uuid,boolean) from public,anon;
grant execute on function private.chat_pin(text,text,uuid,boolean) to authenticated;
create or replace function public.chat_unread() returns jsonb language sql security invoker set search_path='' as $$ select private.chat_unread(); $$;
revoke all on function public.chat_unread() from public,anon;
grant execute on function public.chat_unread() to authenticated;
revoke all on function private.chat_unread() from public,anon;
grant execute on function private.chat_unread() to authenticated;
create or replace function public.chat_mark_read(p_division text,p_channel text,p_last_id bigint) returns void language sql security invoker set search_path='' as $$ select private.chat_mark_read(p_division,p_channel,p_last_id); $$;
revoke all on function public.chat_mark_read(text,text,bigint) from public,anon;
grant execute on function public.chat_mark_read(text,text,bigint) to authenticated;
revoke all on function private.chat_mark_read(text,text,bigint) from public,anon;
grant execute on function private.chat_mark_read(text,text,bigint) to authenticated;
notify pgrst,'reload schema';
