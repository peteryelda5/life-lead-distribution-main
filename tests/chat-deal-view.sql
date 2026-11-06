begin;
do $test$
declare actor record; m record; d jsonb; expected uuid; checks integer:=0; linked integer:=0; summaries integer:=0;
begin
 for actor in select distinct on (p.id) p.id,s.id sid from public.profiles p join auth.sessions s on s.user_id=p.id where p.active and not p.archived and (s.not_after is null or s.not_after>now()) order by p.id,s.created_at desc loop
  perform set_config('request.jwt.claims',jsonb_build_object('sub',actor.id,'session_id',actor.sid,'role','authenticated','aal','aal2')::text,true);
  execute 'set local role authenticated';
  begin perform public.require_portal_onboarding();exception when sqlstate 'PT403' then execute 'reset role';continue;end;
  for m in select id,source_deal_id from public.chat_messages where kind='deal' and not coalesce((deal->>'withdrawn')::boolean,false) order by id desc limit 30 loop
   d:=public.chat_deal_view(m.id);
   if d - array['agent_name','agency','carrier','product','monthly_premium','annual_premium','submitted_at','policy_id','withdrawn'] <> '{}'::jsonb then raise exception 'Unexpected summary field';end if;
   execute 'reset role';
   select c.id into expected from private.book_crm_clients c where c.deal_id=m.source_deal_id and private.book_crm_can_access(c.agent_id,c.deal_id) limit 1;
   if d->>'policy_id' is distinct from expected::text then raise exception 'Policy scope mismatch';end if;
   if expected is null then summaries:=summaries+1;else linked:=linked+1;end if;
   execute 'set local role authenticated';
   checks:=checks+1;
  end loop;
  begin perform public.chat_deal_view(-1);raise exception 'Missing message accepted';exception when insufficient_privilege then null;end;
  execute 'reset role';
 end loop;
 if checks=0 or summaries=0 or linked=0 then raise exception 'Insufficient positive and negative scope coverage: %, %, %',checks,summaries,linked;end if;
 perform set_config('request.jwt.claims','{}',true);
 execute 'set local role authenticated';
 begin perform public.chat_deal_view(-1);raise exception 'Unverified accepted';exception when insufficient_privilege then null;end;
 execute 'reset role';
 if has_function_privilege('anon','public.chat_deal_view(bigint)','execute') then raise exception 'Anonymous grant';end if;
end $test$;
rollback;
select 'PASS: authorized links, unauthorized summary-only, response allowlist, missing message and unverified denial' result;
