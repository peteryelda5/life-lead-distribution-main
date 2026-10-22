-- Rollback-only RPC + real authenticated-role Storage RLS checks.
begin;
do $$
declare a uuid; b uuid; owner uuid; agency text:='test_brand_'||replace(gen_random_uuid()::text,'-',''); other text:=agency||'_other'; sid uuid:=gen_random_uuid();
begin
 select id into a from public.profiles where active and not coalesce(archived,false) and role='agent' limit 1;
 select id into b from public.profiles where active and not coalesce(archived,false) and role='agent' and id<>a limit 1;
 select id into owner from public.profiles where active and is_super_admin limit 1;
 if a is null or b is null or owner is null then raise exception 'Test needs active roles';end if;
 insert into public.divisions(id,name) values(agency,'__BRANDING_TEST__'),(other,'__BRANDING_OTHER__');
 update public.profiles set role='admin',division=agency where id=a;
 update public.profiles set division=agency where id=b;
 perform set_config('test.brand_admin',a::text,true);perform set_config('test.brand_agent',b::text,true);perform set_config('test.brand_owner',owner::text,true);perform set_config('test.brand_agency',agency,true);perform set_config('test.brand_other',other,true);perform set_config('test.brand_sid',sid::text,true);
 perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'aal','aal2','session_id',sid)::text,true);
end;$$;
set local role authenticated;
do $$
declare a text:=current_setting('test.brand_admin'); agency text:=current_setting('test.brand_agency'); other text:=current_setting('test.brand_other');
 path text:=agency||'/'||a||'/'||gen_random_uuid()::text||'.png'; path2 text:=agency||'/'||a||'/'||gen_random_uuid()::text||'.png'; r jsonb; ver timestamptz; denied boolean; n int;
begin
 r:=public.agency_branding_context();if r->'agency'->>'id'<>agency or jsonb_array_length(r->'manageable')<>1 then raise exception 'Admin scope incorrect';end if;
 insert into storage.objects(bucket_id,name,metadata) values('agency-logos',path,'{"mimetype":"image/png","size":200}');
 r:=public.agency_branding_save(agency,path);ver:=(r->>'updated_at')::timestamptz;
 perform public.agency_branding_save(agency,path,null); -- a lost response retry is harmless
 r:=public.agency_branding_context();if r->'agency'->>'logo_path'<>path then raise exception 'Logo not saved';end if;
 perform set_config('test.brand_path',path,true);perform set_config('test.brand_version',ver::text,true);
 update storage.objects set metadata='{"mimetype":"image/png","size":999}' where bucket_id='agency-logos' and name=path;get diagnostics n=row_count;if n<>0 then raise exception 'Active logo overwritten';end if;
 if private.agency_branding_unused_upload(path) then raise exception 'Active logo removal permitted';end if;
 insert into storage.objects(bucket_id,name,metadata) values('agency-logos',path2,'{"mimetype":"image/png","size":200}');
 denied:=false;begin perform public.agency_branding_save(agency,path2,null);exception when sqlstate 'PT409' then denied:=true;end;if not denied then raise exception 'Stale branding accepted';end if;
 denied:=false;begin perform public.agency_branding_save(other,path,null);exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'Cross agency save accepted';end if;
 denied:=false;begin insert into storage.objects(bucket_id,name,metadata) values('agency-logos',other||'/'||a||'/'||gen_random_uuid()::text||'.png','{"mimetype":"image/png","size":200}');exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'Cross agency upload accepted';end if;
 denied:=false;begin insert into storage.objects(bucket_id,name,metadata) values('agency-logos',agency||'/'||current_setting('test.brand_agent')||'/'||gen_random_uuid()::text||'.png','{"mimetype":"image/png","size":200}');exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'Other actor upload accepted';end if;
 denied:=false;begin perform public.agency_branding_save(agency,agency||'/'||a||'/'||gen_random_uuid()::text||'.png',ver);exception when raise_exception then denied:=true;end;if not denied then raise exception 'Missing uploaded logo accepted';end if;
 perform public.agency_branding_save(agency,null,ver);r:=public.agency_branding_context();if r->'agency'->>'logo_path' is not null then raise exception 'Reset failed';end if;
 if not private.agency_branding_unused_upload(path) then raise exception 'Unused owned upload cleanup denied';end if;
 -- Replacement must be an uploaded image with valid size and MIME metadata.
 ver:=(r->'agency'->>'updated_at')::timestamptz;perform public.agency_branding_save(agency,path2,ver);perform set_config('test.brand_path',path2,true);
end;$$;
reset role;
do $$begin perform set_config('request.jwt.claims',jsonb_build_object('sub',current_setting('test.brand_agent'),'aal','aal2','session_id',current_setting('test.brand_sid'))::text,true);end;$$;
set local role authenticated;
do $$declare r jsonb;denied boolean;begin
 r:=public.agency_branding_context();if jsonb_array_length(r->'manageable')<>0 or r->'agency'->>'logo_path'<>current_setting('test.brand_path') then raise exception 'Agent did not inherit agency branding';end if;
 denied:=false;begin perform public.agency_branding_save(current_setting('test.brand_agency'),null,null);exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'Agent edited logo';end if;
 denied:=false;begin insert into storage.objects(bucket_id,name,metadata) values('agency-logos',current_setting('test.brand_agency')||'/'||current_setting('test.brand_agent')||'/'||gen_random_uuid()::text||'.png','{"mimetype":"image/png","size":200}');exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'Agent uploaded logo';end if;
end;$$;
reset role;
update public.profiles set division=current_setting('test.brand_other') where id=current_setting('test.brand_agent')::uuid;
set local role authenticated;
do $$begin if public.agency_branding_context()->'agency'->>'id'<>current_setting('test.brand_other') or public.agency_branding_context()->'agency'->>'logo_path' is not null then raise exception 'Transferred agent retained old branding';end if;end;$$;
reset role;
do $$begin perform set_config('request.jwt.claims',jsonb_build_object('sub',current_setting('test.brand_owner'),'aal','aal2','session_id',current_setting('test.brand_sid'))::text,true);end;$$;
set local role authenticated;
do $$declare r jsonb;begin r:=public.agency_branding_context();if jsonb_array_length(r->'manageable')<2 then raise exception 'Super Master cannot manage agencies';end if;perform public.agency_branding_save(current_setting('test.brand_other'),null,null);end;$$;
reset role;
do $$declare denied boolean;begin
 perform set_config('request.jwt.claims',jsonb_build_object('sub',current_setting('test.brand_admin'),'aal','aal1','session_id',current_setting('test.brand_sid'))::text,true);
 denied:=false;begin perform public.agency_branding_context();exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'MFA bypass';end if;
 if has_table_privilege('authenticated','private.agency_branding','select') or has_function_privilege('anon','public.agency_branding_context()','execute') or has_function_privilege('anon','public.agency_branding_save(text,text,timestamptz)','execute') then raise exception 'Direct or anonymous access leaked';end if;
end;$$;
select 'PASS: scoped admin upload/save/reset, immutable active logo, stale updates, agent inheritance, transfer refresh, Super Master scope, real authenticated Storage policies and MFA; rolled back' result;
rollback;
