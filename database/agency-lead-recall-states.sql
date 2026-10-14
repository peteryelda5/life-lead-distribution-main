-- State selection extends the existing verified Master preview and exact-ID recall.
create or replace function private.agency_recall_options(p_source text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 perform private.assert_agency_recall_access(p_source);
 return (with inventory as (
  select coalesce(l.lead_type,'') lead_type,upper(btrim(coalesce(l.state,''))) state,
   count(*) n,count(*) filter(where l.assigned_to is null) pool,
   count(*) filter(where l.assigned_to is not null) assigned
  from public.leads l where l.division=p_source and l.status in ('assigned','unassigned')
  and not exists(select 1 from public.closed_business b where b.lead_id=l.id)
  group by coalesce(l.lead_type,''),upper(btrim(coalesce(l.state,'')))
 ), folders as (
  select lead_type,sum(n) n,jsonb_agg(jsonb_build_object('state',state,'count',n,'pool',pool,'assigned',assigned) order by state) states
  from inventory group by lead_type
 ) select coalesce(jsonb_agg(jsonb_build_object('type',lead_type,'count',n,'states',states) order by lead_type),'[]'::jsonb) from folders);
end $$;

create or replace function private.agency_recall_preview_states(p_source text,p_type text,p_scope text,p_count integer,p_states text[])
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare available bigint; rows jsonb; states text[];
begin
 perform private.assert_agency_recall_access(p_source);
 if p_scope is null or p_scope not in ('all','pool','assigned') then raise exception 'Choose which leads to include.'; end if;
 if p_count is null or p_count<1 or p_count>1000 then raise exception 'Choose 1–1,000 leads per recall.'; end if;
 if cardinality(p_states)>100 or array_position(p_states,null) is not null then raise exception 'Invalid state selection.';end if;
 -- NULL means all; an empty array deliberately matches no states.
 if p_states is not null then
  select coalesce(array_agg(distinct upper(btrim(s))),array[]::text[]) into states from unnest(p_states) s;
 end if;
 select count(*) into available from public.leads l
 where l.division=p_source and l.status in ('assigned','unassigned')
 and (p_type is null or coalesce(l.lead_type,'')=p_type)
 and (p_scope='all' or (p_scope='pool' and l.assigned_to is null) or (p_scope='assigned' and l.assigned_to is not null))
 and (states is null or upper(btrim(coalesce(l.state,'')))=any(states))
 and not exists(select 1 from public.closed_business b where b.lead_id=l.id);
 select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at,t.id),'[]'::jsonb) into rows from (
  select l.id,l.updated_at,l.created_at,l.first_name,l.last_name,l.phone,l.lead_type,l.assigned_to,
   upper(btrim(coalesce(l.state,''))) state,
   case when l.assigned_to is null then 'Agency lead pool' else coalesce(nullif(p.full_name,''),'Assigned user') end as assignee
  from public.leads l left join public.profiles p on p.id=l.assigned_to
  where l.division=p_source and l.status in ('assigned','unassigned')
  and (p_type is null or coalesce(l.lead_type,'')=p_type)
  and (p_scope='all' or (p_scope='pool' and l.assigned_to is null) or (p_scope='assigned' and l.assigned_to is not null))
  and (states is null or upper(btrim(coalesce(l.state,'')))=any(states))
  and not exists(select 1 from public.closed_business b where b.lead_id=l.id)
  order by l.created_at,l.id limit p_count
 ) t;
 return jsonb_build_object('available',available,'leads',rows);
end $$;

create or replace function public.agency_recall_preview_states(p_source text,p_type text,p_scope text,p_count integer,p_states text[])
returns jsonb language sql security invoker set search_path='' as $$select private.agency_recall_preview_states(p_source,p_type,p_scope,p_count,p_states)$$;
revoke all on function private.agency_recall_preview_states(text,text,text,integer,text[]),public.agency_recall_preview_states(text,text,text,integer,text[]) from public,anon;
grant execute on function private.agency_recall_preview_states(text,text,text,integer,text[]),public.agency_recall_preview_states(text,text,text,integer,text[]) to authenticated;
