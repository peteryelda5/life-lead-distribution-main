DO $$
declare r record; d jsonb; allowed text[]; denied text; expected numeric; before_rev bigint; test_sale uuid; started timestamptz;
begin
 for r in select id,role,division,is_super_admin from public.profiles where active and not coalesce(archived,false) and role in ('admin','agent') loop
  perform set_config('request.jwt.claim.sub',r.id::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',r.id,'role','authenticated','aal','aal2')::text,true);
  allowed:=case when r.role='admin' then private.my_admin_divisions() else array[r.division] end;
  started:=clock_timestamp();d:=public.live_leaderboard(null);
  if clock_timestamp()-started>interval '2 seconds' then raise exception 'Leaderboard too slow'; end if;
  select coalesce(sum(cb.annual_premium),0) into expected from public.closed_business cb join public.profiles p on p.id=cb.agent_id left join public.leads l on l.id=cb.lead_id where coalesce(l.division,p.division)=any(allowed) and cb.created_at >= (date_trunc('month',now() at time zone 'America/Detroit') at time zone 'America/Detroit') and cb.created_at<=now();
  if (d->'totals'->>'month_ap')::numeric<>expected then raise exception 'AP mismatch'; end if;
  if exists(select 1 from jsonb_array_elements(d->'today_feed') e where e ?| array['lead_id','policy_number','email','phone','notes','csv_values']) then raise exception 'Private fields in feed'; end if;
  select x into denied from unnest(array['owner','vivid_life','legacy_life']) x where not x=any(allowed) limit 1;
  if denied is not null then begin perform public.live_leaderboard(denied); raise exception 'Unauthorized division allowed'; exception when insufficient_privilege then null; end; end if;
  -- Verify notification RLS as the actual authenticated database role.
  execute 'set local role authenticated';
  if exists(select 1 from public.leaderboard_updates where not division=any(allowed)) then raise exception 'Cross-division signal access'; end if;
  perform public.live_leaderboard(null);
  execute 'reset role';
  if r.role='agent' then
   perform set_config('request.jwt.claims',jsonb_build_object('sub',r.id,'role','authenticated','aal','aal1')::text,true);
   begin perform public.live_leaderboard(null); raise exception 'MFA bypass'; exception when insufficient_privilege then null; end;
  end if;
 end loop;
 perform set_config('request.jwt.claim.sub','',true);perform set_config('request.jwt.claims','{}',true);
 begin perform public.live_leaderboard(null);raise exception 'Anonymous allowed';exception when insufficient_privilege then null;end;
 begin
  select sum(revision) into before_rev from public.leaderboard_updates;
  select id into test_sale from public.closed_business limit 1;
  if test_sale is null then raise exception 'Missing verification sale'; end if;
  update public.closed_business set carrier=carrier where id=test_sale;
  if (select sum(revision) from public.leaderboard_updates)<=before_rev then raise exception 'Live update signal failed'; end if;
  raise exception using errcode='P0002',message='Rollback test update';
 exception when no_data_found then null;end;
end $$;
