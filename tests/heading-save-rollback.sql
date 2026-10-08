do $verify$
declare sample public.leads; proposed jsonb; first_result jsonb; repeated jsonb; next_result jsonb; cursor_id uuid; started timestamptz; timing jsonb:='{}';prior_claims text;
begin
 create temporary table heading_verification_result_20261008(result jsonb);
 prior_claims:=current_setting('request.jwt.claims',true);
 begin
  perform set_config('request.jwt.claims','{"sub":"8139e230-055d-4247-8133-684ed817b4fa","aal":"aal2","role":"authenticated"}',true);
  execute 'set local role authenticated';
  select * into sample from public.leads where lead_type='PRO9' and csv_headers is not null order by id limit 1;
  if sample.id is null then raise exception 'Verification batch unavailable';end if;
  create temporary table heading_verification_before as select l.id,to_jsonb(l)-'csv_headers'-'updated_at' as stable from public.leads l where l.lead_type is not distinct from sample.lead_type and l.csv_filename is not distinct from sample.csv_filename and l.uploaded_by is not distinct from sample.uploaded_by order by l.id limit 50 for update;
  select jsonb_agg(to_jsonb('Verification heading '||i::text) order by i) into proposed from generate_series(1,jsonb_array_length(sample.csv_headers)) i;
  begin perform public.rename_lead_batch_headers_chunk(sample.id,sample.csv_headers,jsonb_set(proposed,'{1}',proposed->0),null);raise exception 'Duplicate heading accepted';exception when others then if sqlerrm<>'Use a different name for each column' then raise;end if;end;
  started:=clock_timestamp();
  first_result:=public.rename_lead_batch_headers_chunk(sample.id,sample.csv_headers,proposed,null);
  timing:=timing||jsonb_build_object('first_chunk_ms',round(extract(epoch from clock_timestamp()-started)*1000));
  if (first_result->>'scanned')::integer<>25 or (first_result->>'updated')::integer not between 1 and 25 or (first_result->>'done')::boolean then raise exception 'First bounded window failed';end if;
  cursor_id:=(first_result->>'nextCursor')::uuid;
  started:=clock_timestamp();
  repeated:=public.rename_lead_batch_headers_chunk(sample.id,sample.csv_headers,proposed,null);
  timing:=timing||jsonb_build_object('idempotent_retry_ms',round(extract(epoch from clock_timestamp()-started)*1000));
  if (repeated->>'updated')::integer<>0 or (repeated->>'scanned')::integer<>25 or (repeated->>'done')::boolean or repeated->>'nextCursor'<>first_result->>'nextCursor' then raise exception 'Idempotent zero-update window failed';end if;
  started:=clock_timestamp();
  next_result:=public.rename_lead_batch_headers_chunk(sample.id,sample.csv_headers,proposed,cursor_id);
  timing:=timing||jsonb_build_object('resumed_chunk_ms',round(extract(epoch from clock_timestamp()-started)*1000));
  if (next_result->>'scanned')::integer<>25 or (next_result->>'updated')::integer>25 or (next_result->>'nextCursor')::uuid<=cursor_id then raise exception 'Resume cursor failed';end if;
  if exists(select 1 from heading_verification_before b join public.leads l on l.id=b.id where b.stable is distinct from to_jsonb(l)-'csv_headers'-'updated_at') then raise exception 'Other lead data changed';end if;
  perform set_config('request.jwt.claims','{}',true);
  begin perform public.rename_lead_batch_headers_chunk(sample.id,sample.csv_headers,proposed,null);raise exception 'Unverified session accepted';exception when others then if sqlerrm<>'Verified admin required' then raise;end if;end;
  raise exception using errcode='ZX001',message='Rollback verification changes';
 exception when sqlstate 'ZX001' then null;
 end;
 perform set_config('request.jwt.claims',coalesce(prior_claims,'{}'),true);
 insert into heading_verification_result_20261008 values(timing||jsonb_build_object('passed',true,'production_lead_changes','rolled back','verified','chunk bounds, zero-update cursor advance, resume, duplicate validation, unauthorized denial, statuses and values preserved'));
end $verify$;
select * from heading_verification_result_20261008;