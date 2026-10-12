-- Read-only integration checks; run with a database admin connection.
-- Exercises caller JWT/RLS for both an agent and a team leader; changes roll back.
begin;
do $$
declare account record; folder text; picked text[]; r jsonb; r2 jsonb; total bigint; expected bigint; term text; tested integer:=0;
begin
 for account in
  select distinct on (p.is_team_leader) p.id,p.is_team_leader
  from public.profiles p join public.leads l on l.assigned_to=p.id and l.status='assigned'
  where p.role='agent' and p.active and not coalesce(p.archived,false)
  group by p.id order by p.is_team_leader,count(*) desc
 loop
  perform set_config('request.jwt.claims',jsonb_build_object('sub',account.id,'role','authenticated','aal','aal2')::text,true);
  execute 'set local role authenticated';
  select lead_type into folder from public.leads where assigned_to=account.id and status='assigned' group by lead_type order by count(*) desc limit 1;
  select array_agg(state) into picked from (select distinct coalesce(nullif(upper(btrim(state)),''),'') state from public.leads where assigned_to=account.id and status='assigned' and lead_type is not distinct from folder order by 1 limit 2) s;
  select count(*) into expected from public.leads where assigned_to=account.id and status='assigned' and lead_type is not distinct from folder and coalesce(nullif(upper(btrim(state)),''),'')=any(picked);
  r:=public.my_assigned_leads_filtered('',folder,true,1,7,picked);
  if (r->>'count')::bigint<>expected or jsonb_array_length(r->'data')<>least(7,expected) then raise exception 'Filtered count/page failed'; end if;
  if exists(select 1 from jsonb_array_elements(r->'data') x where (x->>'assigned_to')::uuid<>account.id or x->>'status'<>'assigned' or (x->>'lead_type') is distinct from folder or not(coalesce(nullif(upper(btrim(x->>'state')),''),'')=any(picked))) then raise exception 'Folder, state, or ownership boundary failed'; end if;
  r2:=public.my_assigned_leads_filtered('',folder,true,2,7,picked);
  if jsonb_array_length(r2->'data')<>least(7,greatest(0,expected-7)) or exists(select 1 from jsonb_array_elements(r->'data') x join jsonb_array_elements(r2->'data') y on x->>'id'=y->>'id') then raise exception 'Pagination failed'; end if;
  select count(*) into total from public.leads where assigned_to=account.id and status='assigned' and lead_type is not distinct from folder;
  if (select sum((x->>'lead_count')::bigint) from jsonb_array_elements(r->'states') x)<>total then raise exception 'State options must cover whole folder'; end if;
  r:=public.my_assigned_leads_filtered('',folder,true,1,500,'{}');
  if (r->>'count')::bigint<>total then raise exception 'All states failed'; end if;
  r:=public.my_assigned_leads_filtered('',folder,true,1,500,array['__no_such_state__']);
  if (r->>'count')::bigint<>0 or jsonb_array_length(r->'data')<>0 then raise exception 'Empty state match failed'; end if;
  select count(*) into expected from public.leads where assigned_to=account.id and status='assigned' and lead_type is null;
  r:=public.my_assigned_leads_filtered('',null,true,1,500,'{}');
  if (r->>'count')::bigint<>expected then raise exception 'Unlabeled folder failed'; end if;
  select count(*) into expected from public.leads where assigned_to=account.id and status='assigned';
  r:=public.my_assigned_leads_filtered('',null,false,1,500,'{}');
  if (r->>'count')::bigint<>expected then raise exception 'All folders failed'; end if;
  term:=coalesce(r->'data'->0->>'first_name','');
  r:=public.my_assigned_leads_filtered(term,null,false,1,500,'{}');
  if exists(select 1 from jsonb_array_elements(r->'data') x where strpos(lower(concat_ws(' ',x->>'first_name',x->>'last_name',x->>'phone',x->>'email',x->>'state',x->>'source',x->>'lead_type',x->>'agent_status',x->>'call_notes',(x->'csv_values')::text)),lower(term))=0) then raise exception 'Search with states failed'; end if;
  execute 'reset role';tested:=tested+1;
 end loop;
 if tested<2 then raise exception 'Both agent and team leader fixtures required'; end if;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',account.id,'role','authenticated','aal','aal1')::text,true);
 execute 'set local role authenticated';
 begin
  perform public.my_assigned_leads_filtered();
  raise exception 'Test failed: unverified session accepted';
 exception when others then
  if sqlerrm not like 'Complete two-step verification%' then raise; end if;
 end;
 execute 'reset role';
 if has_function_privilege('anon','public.my_assigned_leads_filtered(text,text,boolean,integer,integer,text[])','execute') then raise exception 'Anonymous access enabled'; end if;
end $$;
rollback;
select 'PASS: agent and leader RLS, folder/state scope, multi-state pages, counts, all states, empty results, unlabeled folders, search, MFA and anonymous denial' as result;
