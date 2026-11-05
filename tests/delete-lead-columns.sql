-- Production-compatible verification; all changes are rolled back and no records are returned.
begin;
create temp table column_test_actor on commit drop as
select p.id,s.id sid from public.profiles p join auth.sessions s on s.user_id=p.id
where p.is_super_admin and p.active and not p.archived and (s.not_after is null or s.not_after>now()) limit 1;
grant select on column_test_actor to authenticated;
set local role authenticated;
do $test$
declare actor record; sample public.leads; result jsonb; retry jsonb; denied boolean:=false;
begin
 select * into strict actor from column_test_actor;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',actor.id,'session_id',actor.sid,'role','authenticated','aal','aal2')::text,true);
 select * into strict sample from public.leads where jsonb_array_length(csv_headers)>=3 and public.admin_can_access_division(division) order by id limit 1;
 create temp table column_before on commit drop as select l.* from public.leads l
 where l.csv_filename is not distinct from sample.csv_filename and l.lead_type is not distinct from sample.lead_type and l.uploaded_by is not distinct from sample.uploaded_by
 and (l.division=sample.division or l.division=any(private.my_admin_divisions()))
 order by id limit 25;
 begin perform public.delete_lead_batch_columns_chunk(sample.id,sample.csv_headers,array[-1]);raise exception 'Invalid index accepted';
 exception when others then if sqlerrm<>'Select valid columns to delete' then raise;end if;end;
 begin perform public.delete_lead_batch_columns_chunk(sample.id,sample.csv_headers,array(select generate_series(0,jsonb_array_length(sample.csv_headers)-1)));raise exception 'All columns accepted';
 exception when others then if sqlerrm<>'Keep at least one uploaded column' then raise;end if;end;
 result:=public.delete_lead_batch_columns_chunk(sample.id,sample.csv_headers,array[0,2]);
 if (result->>'updated')::int<1 or (result->>'scanned')::int>25 then raise exception 'Chunk bounds failed';end if;
 if exists(select 1 from column_before b join public.leads l using(id)
  where (to_jsonb(l)-'csv_headers'-'csv_values'-'updated_at') is distinct from (to_jsonb(b)-'csv_headers'-'csv_values'-'updated_at')
  or (b.csv_headers=sample.csv_headers and (
   l.csv_headers is distinct from (select jsonb_agg(v order by ord) from jsonb_array_elements(b.csv_headers) with ordinality x(v,ord) where ord not in (1,3))
   or l.csv_values is distinct from (select jsonb_agg(coalesce(b.csv_values->(i-1),'null'::jsonb) order by i) from generate_series(1,jsonb_array_length(b.csv_headers)) i where i not in (1,3)))))
 then raise exception 'Values misaligned or other lead fields changed';end if;
 retry:=public.delete_lead_batch_columns_chunk(sample.id,sample.csv_headers,array[0,2]);
 if (retry->>'updated')::int<>0 or retry->>'nextCursor' is distinct from result->>'nextCursor' then raise exception 'Retry deleted extra columns';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',actor.id,'session_id',gen_random_uuid(),'aal','aal1')::text,true);
 begin perform public.delete_lead_batch_columns_chunk(sample.id,sample.csv_headers,array[0]);exception when others then if sqlerrm='Verified admin required' then denied:=true;else raise;end if;end;
 if not denied then raise exception 'Unverified access accepted';end if;
 if has_function_privilege('anon','public.delete_lead_batch_columns_chunk(uuid,jsonb,integer[],uuid)','execute') then raise exception 'Anonymous execute granted';end if;
end $test$;
rollback;
select 'PASS: bounded deletion, header/value alignment, other fields preserved, idempotent retry, invalid/all-column rejection, unverified and anonymous denial; all changes rolled back' result;
