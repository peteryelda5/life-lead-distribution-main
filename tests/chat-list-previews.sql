begin;
do $test$
declare actor record; payload jsonb; item jsonb; last_row record; expected integer; checked integer:=0;
begin
 for actor in select distinct on (p.id) p.id,s.id sid from public.profiles p join auth.sessions s on s.user_id=p.id where p.active and not p.archived and (s.not_after is null or s.not_after>now()) order by p.id,s.created_at desc loop
  perform set_config('request.jwt.claims',jsonb_build_object('sub',actor.id,'session_id',actor.sid,'role','authenticated','aal','aal2')::text,true);
  execute 'set local role authenticated';
  begin payload:=public.portal_collaboration('list','{}');exception when sqlstate 'PT403' then execute 'reset role';continue;end;
  execute 'reset role';
  select count(*) into expected from private.portal_conversations c where private.portal_conversation_access(c.id);
  if jsonb_array_length(payload->'chats')<>expected then raise exception 'Conversation visibility changed';end if;
  for item in select value from jsonb_array_elements(payload->'chats') loop
   if not private.portal_conversation_access((item->>'id')::uuid) then raise exception 'Foreign conversation preview exposed';end if;
   select id,body,created_at,author_id into last_row from private.portal_conversation_messages where conversation_id=(item->>'id')::uuid order by id desc limit 1;
   if item->>'last_body' is distinct from left(last_row.body,240) or item->>'last_author_id' is distinct from last_row.author_id::text or (item->>'last_at')::timestamptz is distinct from last_row.created_at then raise exception 'Preview mismatch';end if;
  end loop;
  checked:=checked+1;
 end loop;
 if checked=0 then raise exception 'No verified test sessions';end if;
 perform set_config('request.jwt.claims','{}',true);
 execute 'set local role authenticated';
 begin perform public.portal_collaboration('list','{}');raise exception 'Unverified list admitted';exception when others then if sqlerrm<>'Verified login required' then raise;end if;end;
 execute 'reset role';
end $test$;
rollback;
select 'PASS: scoped conversation list unchanged; latest previews match authorized messages; unverified access denied; no message writes' result;
