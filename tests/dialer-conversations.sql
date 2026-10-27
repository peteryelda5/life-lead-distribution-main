begin;
-- Transactional regression; all fixture rows roll back, even on a passing run.
do $$
declare actor uuid; c jsonb; again jsonb; cid uuid; source uuid:=gen_random_uuid(); d jsonb;
begin
 select id into actor from public.profiles where active and role='admin' limit 1;
 if actor is null then raise exception 'An existing admin is required for the read-only owner fixture';end if;
 begin
  d:=jsonb_build_object('user_id',actor,'livemode',false,'kind','call','source_id',source,'lead_id',null,'phone','+12025550191','provider_sid','AC'||repeat('1',32),'call_sid','CA'||replace(source::text,'-',''),'inbound_speaker','client','service_sid','GA'||repeat('2',32),'operator_sid','LY'||repeat('3',32));
  c:=public.dialer_conversation_claim(d);cid:=(c->'conversation'->>'id')::uuid;
  if not (c->>'created')::boolean then raise exception 'First claim failed';end if;
  again:=public.dialer_conversation_claim(d);
  if (again->>'created')::boolean or (again->'conversation'->>'id')::uuid<>cid then raise exception 'Duplicate paid stream allowed';end if;
  perform public.dialer_conversation_event(cid,'AC'||repeat('1',32),'CA'||replace(source::text,'-',''),'GT'||replace(source::text,'-',''),'transcription-content',2,'inbound_track','Client test',now(),null);
  perform public.dialer_conversation_event(cid,'AC'||repeat('1',32),'CA'||replace(source::text,'-',''),'GT'||replace(source::text,'-',''),'transcription-content',3,'outbound_track','Agent test',now(),null);
  perform public.dialer_conversation_event(cid,'AC'||repeat('1',32),'CA'||replace(source::text,'-',''),'GT'||replace(source::text,'-',''),'transcription-content',2,'inbound_track','Duplicate changed payload',now(),null);
  if (select count(*) from public.dialer_conversation_lines where conversation_id=cid)<>2 or not exists(select 1 from public.dialer_conversation_lines where conversation_id=cid and sequence=2 and speaker='client' and content='Client test') or not exists(select 1 from public.dialer_conversation_lines where conversation_id=cid and sequence=3 and speaker='agent') then raise exception 'Speaker mapping or duplicate delivery failed';end if;
  perform public.dialer_conversation_event(cid,'AC'||repeat('1',32),'CA'||replace(source::text,'-',''),'GT'||replace(source::text,'-',''),'transcription-stopped',4,null,null,null,null);
  perform public.dialer_conversation_event(cid,'AC'||repeat('1',32),'CA'||replace(source::text,'-',''),'GT'||replace(source::text,'-',''),'transcription-started',1,null,null,null,null);
  if (select state from public.dialer_conversations where id=cid)<>'stopped' then raise exception 'Late start resurrected stopped transcription';end if;
  begin
   perform public.dialer_conversation_event(cid,'AC'||repeat('9',32),'CA'||replace(source::text,'-',''),'GT'||replace(source::text,'-',''),'transcription-stopped',5,null,null,null,null);
   raise exception 'Wrong account accepted' using errcode='PT999';
  exception when sqlstate 'P0001' then null;end;
  if has_table_privilege('authenticated','public.dialer_conversations','SELECT') or has_table_privilege('anon','public.dialer_conversation_lines','SELECT') or has_function_privilege('authenticated','public.dialer_conversation_claim(jsonb)','EXECUTE') then raise exception 'Browser role has transcript access';end if;
  if exists(select 1 from pg_class where oid in ('public.dialer_conversations'::regclass,'public.dialer_conversation_lines'::regclass) and not relrowsecurity) then raise exception 'RLS disabled';end if;
  update public.dialer_conversations set expires_at=now()-interval '1 second' where id=cid;
  perform public.dialer_conversation_event(cid,'AC'||repeat('1',32),'CA'||replace(source::text,'-',''),'GT'||replace(source::text,'-',''),'transcription-content',6,'inbound_track','Expired',now(),null);
  if (select count(*) from public.dialer_conversation_lines where conversation_id=cid)<>2 then raise exception 'Expired transcript accepted text';end if;
  raise exception 'rollback successful fixtures' using errcode='PT001';
 exception when sqlstate 'PT001' then null;end;
end $$;

rollback;
