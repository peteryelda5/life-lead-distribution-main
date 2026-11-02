-- Synthetic identities and content only; run inside a transaction that rolls back.
do $test$
declare
 admin_id uuid:=gen_random_uuid(); agent_id uuid:=gen_random_uuid(); writer_id uuid:=gen_random_uuid();
 master_id uuid:=gen_random_uuid(); private_id uuid:=gen_random_uuid(); foreign_id uuid:=gen_random_uuid();
 agency text:='sheet_fixture_'||replace(gen_random_uuid()::text,'-','');
 actor uuid; affected int; denied boolean;
begin
 perform set_config('request.jwt.claims','{}',true);
 insert into auth.users(id,email) values(admin_id,admin_id||'@example.invalid'),(agent_id,agent_id||'@example.invalid'),(writer_id,writer_id||'@example.invalid');
 insert into public.profiles(id,full_name,role,active,division) values(writer_id,'Synthetic master editor','admin',true,'vivid_life');
 insert into public.divisions(id,name,created_by) values(agency,'Synthetic sheet agency',writer_id);
 insert into public.profiles(id,full_name,role,active,division) values(admin_id,'Synthetic agency admin','admin',true,agency),(agent_id,'Synthetic agency agent','agent',true,agency);
 insert into auth.sessions(id,user_id,aal,created_at) values(admin_id,admin_id,'aal2',now()),(agent_id,agent_id,'aal2',now()),(writer_id,writer_id,'aal2',now());
 insert into private.portal_onboarding_waivers(user_id,reason,granted_by) values(agent_id,'Rollback-only sheet test',writer_id);
 insert into public.sales_scripts(id,division,title,lead_type,body,created_by) values
 (master_id,'vivid_life','Synthetic shared sheet','Sales Process / Objection Sheet','Shared fixture',writer_id),
 (private_id,'vivid_life','Synthetic private script','Opening','Private fixture',writer_id),
 (foreign_id,agency,'Synthetic agency sheet','Sales Process / Objection Sheet','Agency-only fixture',admin_id);
 foreach actor in array array[admin_id,agent_id] loop
  perform set_config('request.jwt.claims',jsonb_build_object('sub',actor,'session_id',actor,'role','authenticated','aal','aal2')::text,true);
  set local role authenticated;
  if not exists(select 1 from public.sales_scripts where id=master_id and body='Shared fixture') then raise exception 'Other agency cannot read master sheet';end if;
  if exists(select 1 from public.sales_scripts where id=private_id) then raise exception 'Sharing leaked ordinary Vivid scripts';end if;
  update public.sales_scripts set body='Forbidden' where id=master_id;get diagnostics affected=row_count;
  if affected<>0 then raise exception 'Other agency edited master sheet';end if;
  delete from public.sales_scripts where id=master_id;get diagnostics affected=row_count;
  if affected<>0 then raise exception 'Other agency deleted master sheet';end if;
  denied:=false;begin insert into public.sales_scripts(division,title,lead_type,body) values('vivid_life','Unauthorized','Sales Process / Objection Sheet','Forbidden');exception when insufficient_privilege then denied:=true;end;
  if not denied then raise exception 'Other agency created master sheet';end if;
  reset role;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',actor,'session_id',actor,'role','authenticated','aal','aal1')::text,true);
  set local role authenticated;
  if exists(select 1 from public.sales_scripts where id=master_id) then raise exception 'Unverified session read master sheet';end if;
  reset role;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',actor,'session_id',actor,'role','authenticated','aal','aal2')::text,true);
  update public.profiles set active=false where id=actor;
  set local role authenticated;
  if exists(select 1 from public.sales_scripts where id=master_id) then raise exception 'Disabled account read master sheet';end if;
  reset role;
  update public.profiles set active=true where id=actor;
 end loop;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',writer_id,'session_id',writer_id,'role','authenticated','aal','aal2')::text,true);
 set local role authenticated;
 update public.sales_scripts set body='Updated shared fixture' where id=master_id;get diagnostics affected=row_count;
 if affected<>1 then raise exception 'Vivid admin cannot edit master sheet';end if;
 if exists(select 1 from public.sales_scripts where id=foreign_id) then raise exception 'Foreign agency sheet leaked';end if;
 reset role;
 if has_table_privilege('anon','public.sales_scripts','select') then raise exception 'Anonymous table access';end if;
end $test$;
select 'PASS: cross-agency read, Vivid editor, other scripts isolated, foreign writes denied, MFA and disabled-account restrictions preserved' as result;
