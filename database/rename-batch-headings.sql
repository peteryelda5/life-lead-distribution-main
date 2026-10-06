CREATE OR REPLACE FUNCTION public.rename_lead_batch_headers(p_sample_id uuid, p_expected_headers jsonb, p_headers jsonb)
RETURNS integer LANGUAGE plpgsql SET search_path TO '' AS $function$
declare sample public.leads; n integer;
begin
 if not private.verified_portal_session() or not public.is_admin() then raise exception 'Verified admin required'; end if;
 select * into sample from public.leads where id=p_sample_id for update;
 if sample.id is null or not public.admin_can_access_division(sample.division) then raise exception 'Batch access denied'; end if;
 if sample.csv_headers is distinct from p_expected_headers then raise exception 'Headings changed. Refresh and try again.'; end if;
 if p_headers is null or jsonb_typeof(p_headers)<>'array' or jsonb_array_length(p_headers)<>jsonb_array_length(sample.csv_headers) then raise exception 'Keep the same number of columns'; end if;
 if exists(select 1 from jsonb_array_elements(p_headers) v where jsonb_typeof(v)<>'string' or length(trim(v#>>'{}')) not between 1 and 120) then raise exception 'Each heading must contain 1 to 120 characters'; end if;
 if (select count(distinct lower(trim(v))) from jsonb_array_elements_text(p_headers) v)<>jsonb_array_length(p_headers) then raise exception 'Use a different name for each column'; end if;
 update public.leads l set csv_headers=p_headers,updated_at=now()
 where (l.division=sample.division or (public.is_super_admin() and public.admin_can_access_division(l.division)))
 and l.csv_filename is not distinct from sample.csv_filename and l.lead_type is not distinct from sample.lead_type
 and l.uploaded_by is not distinct from sample.uploaded_by and l.csv_headers=p_expected_headers;
 get diagnostics n=row_count;
 return n;
end $function$;