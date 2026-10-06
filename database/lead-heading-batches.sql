-- Bounded heading updates preserve values, assignments and agent statuses.
create index if not exists leads_heading_batch_idx on public.leads
 (coalesce(lead_type,''),coalesce(csv_filename,''),coalesce(uploaded_by,'00000000-0000-0000-0000-000000000000'::uuid),id);
create or replace function public.rename_lead_batch_headers_chunk(p_sample_id uuid,p_expected_headers jsonb,p_headers jsonb,p_after uuid default null) returns jsonb language plpgsql security invoker set search_path='' as $$
declare sample public.leads; n integer;last_id uuid;super_access boolean;begin
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
 with picked as materialized (
 select l.id from public.leads l
 where coalesce(l.lead_type,'')=coalesce(sample.lead_type,'') and coalesce(l.csv_filename,'')=coalesce(sample.csv_filename,'') and coalesce(l.uploaded_by,'00000000-0000-0000-0000-000000000000'::uuid)=coalesce(sample.uploaded_by,'00000000-0000-0000-0000-000000000000'::uuid)
 and l.csv_filename is not distinct from sample.csv_filename and l.lead_type is not distinct from sample.lead_type and l.uploaded_by is not distinct from sample.uploaded_by
 and (l.division=sample.division or (super_access and public.admin_can_access_division(l.division))) and l.csv_headers=p_expected_headers and (p_after is null or l.id>p_after) order by l.id limit 100 for update
 ), changed as (update public.leads l set csv_headers=p_headers,updated_at=now() from picked where l.id=picked.id returning l.id)
 select count(*)::integer,(array_agg(id order by id desc))[1] into n,last_id from changed;
 return jsonb_build_object('updated',n,'done',n<100,'nextCursor',last_id);
end $$;
revoke all on function public.rename_lead_batch_headers_chunk(uuid,jsonb,jsonb,uuid) from public,anon;
grant execute on function public.rename_lead_batch_headers_chunk(uuid,jsonb,jsonb,uuid) to authenticated;
