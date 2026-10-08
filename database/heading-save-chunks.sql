CREATE OR REPLACE FUNCTION public.rename_lead_batch_headers_chunk(p_sample_id uuid, p_expected_headers jsonb, p_headers jsonb, p_after uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare sample public.leads; n integer;last_id uuid;super_access boolean;scanned integer;allowed_divisions text[];begin
 if not private.verified_portal_session() or not public.is_admin() then raise exception 'Verified admin required';end if;
 select * into sample from public.leads where id=p_sample_id for update;
 if sample.id is null or not public.admin_can_access_division(sample.division) then raise exception 'Batch access denied';end if;
 if sample.csv_headers is distinct from p_expected_headers and sample.csv_headers is distinct from p_headers then raise exception 'Headings changed. Refresh and try again.';end if;
 if p_headers is null or p_expected_headers is null or jsonb_typeof(p_headers)<>'array' or jsonb_typeof(p_expected_headers)<>'array' then raise exception 'Headings must be arrays';end if;
 if jsonb_array_length(p_headers)<>jsonb_array_length(sample.csv_headers) or jsonb_array_length(p_expected_headers)<>jsonb_array_length(sample.csv_headers) then raise exception 'Keep the same number of columns';end if;
 if exists(select 1 from jsonb_array_elements(p_headers) v where jsonb_typeof(v)<>'string' or length(trim(v#>>'{}')) not between 1 and 120) then raise exception 'Each heading must contain 1 to 120 characters';end if;
 if (select count(distinct lower(trim(v))) from jsonb_array_elements_text(p_headers) v)<>jsonb_array_length(p_headers) then raise exception 'Use a different name for each column';end if;
 if p_headers=p_expected_headers then return jsonb_build_object('updated',0,'done',true,'nextCursor',null);end if;

 super_access:=public.is_super_admin();
 allowed_divisions:=private.my_admin_divisions();
 -- Bound the batch window BEFORE checking headings. Already-renamed rows must
 -- advance the cursor too, rather than forcing every retry to scan them again.
 with window_rows as materialized (
 select l.id from public.leads l
 where coalesce(l.lead_type,'')=coalesce(sample.lead_type,'')
 and coalesce(l.csv_filename,'')=coalesce(sample.csv_filename,'')
 and coalesce(l.uploaded_by,'00000000-0000-0000-0000-000000000000'::uuid)=coalesce(sample.uploaded_by,'00000000-0000-0000-0000-000000000000'::uuid)
 and l.csv_filename is not distinct from sample.csv_filename
 and l.lead_type is not distinct from sample.lead_type
 and l.uploaded_by is not distinct from sample.uploaded_by
 and (l.division=sample.division or (super_access and l.division=any(allowed_divisions)))
 and l.id>=coalesce(p_after,'00000000-0000-0000-0000-000000000000'::uuid)
 and (p_after is null or l.id>p_after)
 order by l.id limit 25
 ), picked as materialized (
 select l.id from public.leads l join window_rows w on w.id=l.id
 where l.csv_headers=p_expected_headers order by l.id for update of l
 ), changed as (
 update public.leads l set csv_headers=p_headers,updated_at=now()
 from picked where l.id=picked.id and l.csv_headers=p_expected_headers returning l.id
 )
 select (select count(*)::integer from changed),count(*)::integer,
 (array_agg(w.id order by w.id desc))[1]
 into n,scanned,last_id from window_rows w;
 return jsonb_build_object('updated',n,'scanned',scanned,'done',scanned<25,'nextCursor',last_id);
end $function$;
