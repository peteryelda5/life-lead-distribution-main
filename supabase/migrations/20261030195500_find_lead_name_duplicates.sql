-- Use the same agency authorization and row visibility as the lead pool.
create or replace function public.find_lead_name_duplicates(p_division text,p_page integer default 0)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare result jsonb;
begin
 if not coalesce(public.admin_can_access_division(p_division),false) then
   raise exception 'You cannot review leads for this agency' using errcode='42501';
 end if;
 with base as materialized (
 select id,phone,lead_type,status,assigned_to,nullif(trim(first_name),'') fn,nullif(trim(last_name),'') ln,
 case when nullif(trim(first_name),'') is null or nullif(trim(last_name),'') is null then csv_headers end hdr,
 case when nullif(trim(first_name),'') is null or nullif(trim(last_name),'') is null then csv_values end vals
 from public.leads where division=p_division
 ), header_maps as materialized (
 select h.hdr,
 min(i::int-1) filter(where k in ('firstname','clientfirstname','insuredfirstname','fname','givenname','first')) fi,
 min(i::int-1) filter(where k in ('lastname','clientlastname','insuredlastname','lname','surname','last')) li,
 min(i::int-1) filter(where k in ('fullname','clientname','name','insuredname','contactname','applicantname','leadname')) ni
 from (select distinct hdr from base where jsonb_typeof(hdr)='array') h
 cross join lateral jsonb_array_elements_text(h.hdr) with ordinality a(col,i)
 cross join lateral (select regexp_replace(lower(col),'[^a-z0-9]','','g') k) keys
 group by h.hdr
 ), parsed as materialized (
 select b.id,b.phone,b.lead_type,b.status,b.assigned_to, coalesce(
 coalesce(b.fn,nullif(trim(b.vals->>m.fi),''))||' '||coalesce(b.ln,nullif(trim(b.vals->>m.li),'')),
 nullif(trim(b.vals->>m.ni),'')) display_name from base b left join header_maps m on m.hdr=b.hdr
 ), named as materialized (
 select parsed.*,lower(trim(regexp_replace(display_name,'[[:space:]]+',' ','g'))) name_key from parsed
 ), groups as materialized (
 select name_key,min(display_name) label,count(*) n from named
 where name_key like '% %' and name_key not in ('unknown unknown','no name','not provided','unnamed lead')
 group by name_key having count(*)>1
 ), page as (
 select * from groups order by n desc,name_key limit 15 offset (greatest(coalesce(p_page,0),0)::bigint*15)
 ), matches as (
 select n.*,case when digits ~ '^1[0-9]{10}$' then substr(digits,2) when digits ~ '^[0-9]{10}$' then digits end phone_key
 from named n join page using(name_key) cross join lateral (select regexp_replace(n.phone,'[^0-9]','','g') digits) ph
 ), marked as (
 select m.*,phone_key is not null and count(*) over(partition by name_key,phone_key)>1 same_phone from matches m
 ), grouped as (
 select g.name_key,g.label,g.n,jsonb_agg(jsonb_build_object('folder',coalesce(nullif(trim(m.lead_type),''),'Unlabeled'),
 'phone',m.phone,'same_phone',m.same_phone,'status',m.status,'agent',p.full_name) order by m.lead_type,m.id) records
 from page g join marked m using(name_key) left join public.profiles p on p.id=m.assigned_to group by g.name_key,g.label,g.n
 )
 select jsonb_build_object('total',(select count(*) from groups),'groups',coalesce(jsonb_agg(jsonb_build_object('name',label,'count',n,'records',records) order by n desc,name_key),'[]'::jsonb)) into result from grouped;
 return result;
end $$;
revoke all on function public.find_lead_name_duplicates(text,integer) from public,anon;
grant execute on function public.find_lead_name_duplicates(text,integer) to authenticated;
