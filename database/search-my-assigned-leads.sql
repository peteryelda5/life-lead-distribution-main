create or replace function public.search_my_assigned_leads(p_search text,p_lead_type text default null,p_folder boolean default false,p_page integer default 1,p_limit integer default 500)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare result jsonb; terms text[]; who uuid:=auth.uid(); page_size integer:=least(500,greatest(1,coalesce(p_limit,500)));
begin
 if not private.verified_portal_session() then raise exception 'Complete two-step verification'; end if;
 if length(coalesce(p_search,''))>120 then raise exception 'Search is limited to 120 characters'; end if;
 terms:=regexp_split_to_array(trim(coalesce(p_search,'')),'\s+');
 with matched as materialized (
 select l.* from public.leads l
 where l.assigned_to=who and l.status='assigned'
 and (not coalesce(p_folder,false) or l.lead_type is not distinct from p_lead_type)
 and not exists(select 1 from unnest(terms) t(term) where t.term<>'' and strpos(lower(concat_ws(' ',l.first_name,l.last_name,l.phone,l.email,l.state,l.source,l.lead_type,l.agent_status,l.call_notes,l.csv_values::text)),lower(t.term))=0)
 ), paged as (
 select * from matched order by assigned_at desc,id desc limit page_size offset (greatest(1,coalesce(p_page,1))-1)::bigint*page_size
 )
 select jsonb_build_object('data',coalesce((select jsonb_agg(to_jsonb(paged) order by assigned_at desc,id desc) from paged),'[]'::jsonb),'count',(select count(*) from matched)) into result;
 return result;
end $$;
revoke all on function public.search_my_assigned_leads(text,text,boolean,integer,integer) from public,anon;
grant execute on function public.search_my_assigned_leads(text,text,boolean,integer,integer) to authenticated;
