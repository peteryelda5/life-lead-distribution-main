do $$
declare m uuid; a uuid; aid uuid:=gen_random_uuid(); lid uuid; n integer; denied boolean;
begin
 select id into m from public.profiles where is_super_admin and active;
 select id into a from public.profiles where role='admin' and division='legacy_life' and active and not coalesce(archived,false) limit 1;
 begin
  perform set_config('request.jwt.claims','{}',true);
  insert into auth.users(id,email) values(aid,'send-test-'||aid::text||'@example.invalid');
  insert into public.profiles(id,email,full_name,role,active,division) values(aid,'send-test-'||aid::text||'@example.invalid','Send Test','agent',true,'legacy_life') on conflict(id) do update set role='agent',active=true,division='legacy_life';
  perform set_config('request.jwt.claims',jsonb_build_object('sub',m,'role','authenticated','aal','aal2')::text,true);
  set local role authenticated;
  insert into public.leads(first_name,last_name,division) values('Test','Send','owner') returning id into lid;
  n:=public.send_leads_to_division(array[lid],'owner','legacy_life');
  if n<>1 or not exists(select 1 from public.leads where id=lid and division='legacy_life' and status='unassigned' and assigned_to is null) then raise exception 'Send failed';end if;
  denied:=false;begin perform public.assign_leads_bulk(array[lid],aid);exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'Master agent assignment allowed';end if;
  denied:=false;begin update public.leads set assigned_to=aid,status='assigned' where id=lid;exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'Direct assignment allowed';end if;
  denied:=false;begin perform public.send_leads_to_division(array[lid],'legacy_life','owner');exception when others then denied:=true;end;if not denied then raise exception 'Legacy export allowed';end if;
  reset role;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'role','authenticated','aal','aal2')::text,true);
  set local role authenticated;
  denied:=false;begin perform public.send_leads_to_division(array[lid],'legacy_life','vivid_life');exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'Scoped admin transfer allowed';end if;
  n:=public.assign_leads_bulk(array[lid],aid);if n<>1 then raise exception 'Admin assignment broken';end if;
  reset role;
  raise exception using errcode='ZX001',message='Rollback fixtures';
 exception when sqlstate 'ZX001' then null;
 end;
 reset role;
 if exists(select 1 from public.leads where id=lid) or exists(select 1 from auth.users where id=aid) then raise exception 'Fixtures persisted';end if;
 if has_function_privilege('anon','public.send_leads_to_division(uuid[],text,text)','execute') then raise exception 'Anon access';end if;
end $$;
