-- Live chat message versions and author/Master deletion.
-- No existing messages are changed by this migration.
create or replace function private.portal_chat_delete(p_message_id bigint,p_conversation_id uuid default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare me public.profiles; message public.chat_messages; private_message private.portal_conversation_messages;
begin
 if not private.verified_portal_session() then raise exception 'Verified login required' using errcode='42501';end if;
 select * into me from public.profiles where id=auth.uid();
 if p_message_id is null or p_message_id<=0 then raise exception 'Choose a message';end if;
 if p_conversation_id is null then
  select * into message from public.chat_messages where id=p_message_id for update;
  if not found then return jsonb_build_object('deleted',false);end if;
  if not coalesce(message.division=any(private.shared_chat_divisions()),false)
   or not coalesce(message.author_id=me.id or (me.role='admin' and me.is_super_admin),false) then
   raise exception 'You can only delete your own messages' using errcode='42501';
  end if;
  if message.kind='deal' then raise exception 'Use the closed-deal controls for deal announcements';end if;
  delete from public.chat_messages where id=message.id;
 else
  if not private.portal_conversation_access(p_conversation_id) then raise exception 'Chat access denied' using errcode='42501';end if;
  select * into private_message from private.portal_conversation_messages where id=p_message_id and conversation_id=p_conversation_id for update;
  if not found then return jsonb_build_object('deleted',false);end if;
  if not coalesce(private_message.author_id=me.id or (me.role='admin' and me.is_super_admin),false) then
   raise exception 'You can only delete your own messages' using errcode='42501';
  end if;
  delete from private.portal_conversation_messages where id=private_message.id;
 end if;
 return jsonb_build_object('deleted',true);
end $$;
create or replace function public.portal_chat_delete(p_message_id bigint,p_conversation_id uuid default null)
returns jsonb language sql security invoker set search_path='' as $$select private.portal_chat_delete(p_message_id,p_conversation_id)$$;
revoke all on function private.portal_chat_delete(bigint,uuid),public.portal_chat_delete(bigint,uuid) from public,anon;
grant execute on function private.portal_chat_delete(bigint,uuid),public.portal_chat_delete(bigint,uuid) to authenticated;

-- Extend the existing scoped feed in place, retaining every other category and guard.
do $patch$
declare source text;
begin
 source:=pg_get_functiondef('private.portal_notification_items()'::regprocedure);
 if position($old$jsonb_build_object('tab','live-chat','conversation',c.id),m.created_at$old$ in source)>0
 and position($old$jsonb_build_object('tab','live-chat','room',room),m.created_at$old$ in source)>0 then
  source:=replace(source,$old$jsonb_build_object('tab','live-chat','conversation',c.id),m.created_at$old$,$new$jsonb_build_object('tab','live-chat','conversation',c.id,'message_id',m.id::text),m.created_at$new$);
  source:=replace(source,$old$jsonb_build_object('tab','live-chat','room',room),m.created_at$old$,$new$jsonb_build_object('tab','live-chat','room',room,'message_id',m.id::text),m.created_at$new$);
  execute source;
 elsif position($new$jsonb_build_object('tab','live-chat','conversation',c.id,'message_id',m.id::text),m.created_at$new$ in source)=0
 or position($new$jsonb_build_object('tab','live-chat','room',room,'message_id',m.id::text),m.created_at$new$ in source)=0 then
  raise exception 'Notification feed changed; inspect before applying chat versions';
 end if;
end $patch$;
