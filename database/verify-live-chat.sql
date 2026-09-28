-- All fixture messages and sales roll back, including trigger effects.
do $$
declare p record; l record; v_scopes text[]; v_div text; v_bad text; v_id bigint; v_retry bigint; v_req uuid; v_sale uuid; v_sale2 uuid; v_count bigint; v_before bigint; v_agent uuid; v_ok boolean; v_payload jsonb;
begin
 select count(*) into v_before from public.chat_messages;
 begin
  for p in select id,role,division from public.profiles where active and not coalesce(archived,false) and role in ('admin','agent') loop
   perform set_config('request.jwt.claims',jsonb_build_object('sub',p.id,'role','authenticated','aal','aal2')::text,true);
   v_scopes:=private.leaderboard_divisions();
   set local role authenticated;
   if public.chat_scopes() is distinct from v_scopes then raise exception 'Scope mismatch'; end if;
   if exists(select 1 from public.chat_messages where not division=any(v_scopes)) then raise exception 'RLS scope leak'; end if;
   foreach v_div in array v_scopes loop
    v_req:=gen_random_uuid();
    v_id:=public.chat_send(v_div,'general','Verification only',v_req);
    v_retry:=public.chat_send(v_div,'general','Verification only',v_req);
    if v_id<>v_retry then raise exception 'Retry created duplicate'; end if;
    if not exists(select 1 from public.chat_messages where id=v_id and author_id=p.id) then raise exception 'Message missing or author incorrect'; end if;
    perform public.chat_find_leads(v_div,'');
   end loop;
   select x into v_bad from unnest(array['owner','vivid_life','legacy_life']) x where not x=any(v_scopes) limit 1;
   if v_bad is not null then
    v_ok:=false;begin perform public.chat_send(v_bad,'general','Not allowed',gen_random_uuid());exception when others then v_ok:=true;end;
    if not v_ok then raise exception 'Cross-division send allowed'; end if;
    v_ok:=false;begin perform public.chat_find_leads(v_bad,'');exception when others then v_ok:=true;end;
    if not v_ok then raise exception 'Cross-division search allowed'; end if;
   end if;
   v_ok:=false;begin insert into public.chat_messages(division,channel,author_id,author_name,body) values(p.division,'general',p.id,'Spoof','Denied');exception when insufficient_privilege then v_ok:=true;end;
   if not v_ok then raise exception 'Direct author spoof allowed'; end if;
   reset role;
   if p.role='agent' then
    perform set_config('request.jwt.claims',jsonb_build_object('sub',p.id,'role','authenticated','aal','aal1')::text,true);
    if cardinality(private.leaderboard_divisions())<>0 then raise exception 'MFA bypass'; end if;
   end if;
  end loop;
  -- Exercise the real write path with one existing open lead per populated division.
  for l in select distinct on (a.division) a.id,a.division,a.assigned_to from public.leads a join public.profiles pp on pp.id=a.assigned_to where a.status='assigned' and pp.active and not coalesce(pp.archived,false) and pp.role='agent' and pp.division=a.division order by a.division,a.created_at desc loop
   select id into v_agent from public.profiles where active and role='agent' and not coalesce(archived,false) and id<>l.assigned_to limit 1;
   if v_agent is not null then
    perform set_config('request.jwt.claims',jsonb_build_object('sub',v_agent,'role','authenticated','aal','aal2')::text,true);
    v_ok:=false;begin perform public.chat_close_deal(l.id,'Fixture Carrier','Term',100,current_date,null,null);exception when others then v_ok:=true;end;
    if not v_ok then raise exception 'Foreign agent closed lead'; end if;
   end if;
   perform set_config('request.jwt.claims',jsonb_build_object('sub',l.assigned_to,'role','authenticated','aal','aal2')::text,true);
   set local role authenticated;
   v_sale:=public.chat_close_deal(l.id,'Fixture Carrier','Term',100,(now() at time zone 'America/Detroit')::date,'PRIVATE POLICY','PRIVATE NOTES');
   v_sale2:=public.chat_close_deal(l.id,'Fixture Carrier','Term',100,(now() at time zone 'America/Detroit')::date,'PRIVATE POLICY','PRIVATE NOTES');
   if v_sale<>v_sale2 then raise exception 'Duplicate sale'; end if;
   select deal into v_payload from public.chat_messages where source_deal_id=v_sale and division=l.division;
   if v_payload is null or (v_payload->>'annual_premium')::numeric<>1200 or v_payload::text like '%PRIVATE%' then raise exception 'Missing, incorrect or private announcement'; end if;
   if (select count(*) from public.closed_business where lead_id=l.id)<>1 then raise exception 'Wrong sale count'; end if;
   reset role;
  end loop;
  raise exception using errcode='ZX001',message='Rollback verification data';
 exception when sqlstate 'ZX001' then null;
 end;
 reset role;
 select count(*) into v_count from public.chat_messages;
 if v_count<>v_before then raise exception 'Fixture messages persisted'; end if;
 if has_function_privilege('anon','public.chat_send(text,text,text,uuid)','execute') or has_table_privilege('anon','public.chat_messages','select') then raise exception 'Anonymous access'; end if;
end $$;
