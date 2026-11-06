begin;
do $test$
declare actor record; payload jsonb; item jsonb; expected text; checked integer:=0;
begin
 for actor in select distinct on (p.id) p.id,s.id sid from public.profiles p join auth.sessions s on s.user_id=p.id where p.active and not p.archived and (s.not_after is null or s.not_after>now()) order by p.id,s.created_at desc loop
  perform set_config('request.jwt.claims',jsonb_build_object('sub',actor.id,'session_id',actor.sid,'role','authenticated','aal','aal2')::text,true);
  execute 'set local role authenticated';
  begin payload:=public.chat_agency_logos();exception when sqlstate 'PT403' then execute 'reset role';continue;end;
  execute 'reset role';
  if jsonb_array_length(payload)<>(select count(*) from public.divisions where id=any(private.shared_chat_divisions())) then raise exception 'Scope count mismatch';end if;
  for item in select value from jsonb_array_elements(payload) loop
   if not ((item->>'id')=any(private.shared_chat_divisions())) then raise exception 'Foreign agency';end if;
   if item-array['id','name','logo_path']<>'{}'::jsonb then raise exception 'Non-brand data exposed';end if;
   select logo_path into expected from private.agency_branding where agency_id=item->>'id';
   if item->>'logo_path' is distinct from expected then raise exception 'Incorrect logo';end if;
  end loop;
  checked:=checked+1;
 end loop;
 if checked=0 then raise exception 'No test sessions';end if;
 perform set_config('request.jwt.claims','{}',true);execute 'set local role authenticated';
 begin perform public.chat_agency_logos();raise exception 'Unverified access admitted';exception when insufficient_privilege then null;end;
 execute 'reset role';
 if has_function_privilege('anon','public.chat_agency_logos()','execute') then raise exception 'Anonymous access';end if;
end $test$;
rollback;
select 'PASS: matching logos, chat agency scope, brand-only fields, unverified and anonymous denial' result;
