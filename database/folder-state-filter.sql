-- Folder and state filters use the caller's JWT and existing lead RLS policies.
create or replace function public.my_assigned_leads_filtered(
 p_search text default '', p_lead_type text default null, p_folder boolean default false,
 p_page integer default 1, p_limit integer default 500, p_states text[] default '{}'::text[]
) returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare result jsonb; terms text[]; who uuid:=auth.uid();
 page_size integer:=least(500,greatest(1,coalesce(p_limit,500)));
begin
 if not private.verified_portal_session() or not private.can_work_assigned_leads() then
  raise exception 'Complete two-step verification with an active portal account';
 end if;
 if length(coalesce(p_search,''))>120 then raise exception 'Search is limited to 120 characters'; end if;
 if cardinality(p_states)>100 or exists(select 1 from unnest(p_states) s where s is null or length(s)>100) then
  raise exception 'Invalid state selection';
 end if;
 terms:=regexp_split_to_array(trim(coalesce(p_search,'')),'[[:space:]]+');
 with scoped as materialized (
  select l.*,coalesce(nullif(upper(btrim(l.state)),''),'') as filter_state
  from public.leads l where l.assigned_to=who and l.status='assigned'
  and (not coalesce(p_folder,false) or l.lead_type is not distinct from p_lead_type)
 ), matched as materialized (
  select l.* from scoped l
  where (coalesce(cardinality(p_states),0)=0 or l.filter_state=any(p_states))
  and not exists(select 1 from unnest(terms) t(term) where t.term<>'' and
   strpos(lower(concat_ws(' ',l.first_name,l.last_name,l.phone,l.email,l.state,l.source,l.lead_type,l.agent_status,l.call_notes,l.csv_values::text)),lower(t.term))=0)
 ), paged as (
  select * from matched order by assigned_at desc,id desc
  limit page_size offset (greatest(1,coalesce(p_page,1))-1)::bigint*page_size
 ), state_counts as (
  select filter_state as state,count(*) as lead_count from scoped group by filter_state
 )
 select jsonb_build_object(
  'data',coalesce((select jsonb_agg(to_jsonb(paged)-'filter_state' order by assigned_at desc,id desc) from paged),'[]'::jsonb),
  'count',(select count(*) from matched),
  'states',coalesce((select jsonb_agg(to_jsonb(state_counts) order by state='' asc,state) from state_counts),'[]'::jsonb)
 ) into result;
 return result;
end $$;
revoke all on function public.my_assigned_leads_filtered(text,text,boolean,integer,integer,text[]) from public,anon;
grant execute on function public.my_assigned_leads_filtered(text,text,boolean,integer,integer,text[]) to authenticated;
