begin;
create table public.underwriting_guides (
 id uuid primary key default gen_random_uuid(),
 slug text unique not null,
 carrier text not null check (length(carrier) between 1 and 120),
 title text not null check (length(title) between 1 and 180),
 version_label text not null check (length(version_label) between 1 and 100),
 coverage_types text[] not null check (coverage_types <@ array['final-expense','term','iul']::text[] and cardinality(coverage_types)>0),
 kind text not null default 'underwriting' check (kind in ('underwriting','product','rates')),
 notes text not null default '' check (length(notes)<=2000),
 source_url text check (source_url is null or source_url ~ '^https://'),
 file_name text not null,
 page_count integer not null check (page_count between 1 and 400),
 file_chunks integer not null default 0 check (file_chunks between 0 and 80),
 file_sha256 text,
 page_scopes jsonb not null default '[]'::jsonb,
 rules jsonb not null default '{}'::jsonb,
 active boolean not null default false,
 created_by uuid references public.profiles(id) default auth.uid(),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
create table public.underwriting_guide_pages (
 guide_id uuid not null references public.underwriting_guides(id) on delete cascade,
 page_number integer not null check(page_number between 1 and 400),
 body text not null check(length(body)<=100000),
 search_vector tsvector generated always as (to_tsvector('english',body)) stored,
 primary key(guide_id,page_number)
);
create index underwriting_page_search on public.underwriting_guide_pages using gin(search_vector);
create table public.underwriting_guide_file_chunks (
 guide_id uuid not null references public.underwriting_guides(id) on delete cascade,
 chunk_number integer not null check(chunk_number between 0 and 79),
 data_base64 text not null check(length(data_base64) between 1 and 393216 and data_base64 ~ '^[A-Za-z0-9+/]*={0,2}$'),
 primary key(guide_id,chunk_number)
);
alter table public.underwriting_guides enable row level security;
alter table public.underwriting_guide_pages enable row level security;
alter table public.underwriting_guide_file_chunks enable row level security;
revoke all on public.underwriting_guides,public.underwriting_guide_pages,public.underwriting_guide_file_chunks from anon,public;
grant select,insert,update,delete on public.underwriting_guides,public.underwriting_guide_pages,public.underwriting_guide_file_chunks to authenticated;
create policy uw_guides_verified on public.underwriting_guides as restrictive for all to authenticated using((select private.verified_portal_session())) with check((select private.verified_portal_session()));
create policy uw_guides_read on public.underwriting_guides for select to authenticated using(active or (select public.is_super_admin()));
create policy uw_guides_manage on public.underwriting_guides for all to authenticated using((select public.is_super_admin())) with check((select public.is_super_admin()));
create policy uw_pages_verified on public.underwriting_guide_pages as restrictive for all to authenticated using((select private.verified_portal_session())) with check((select private.verified_portal_session()));
create policy uw_pages_read on public.underwriting_guide_pages for select to authenticated using(exists(select 1 from public.underwriting_guides g where g.id=guide_id));
create policy uw_pages_manage on public.underwriting_guide_pages for all to authenticated using((select public.is_super_admin())) with check((select public.is_super_admin()));
create policy uw_files_verified on public.underwriting_guide_file_chunks as restrictive for all to authenticated using((select private.verified_portal_session())) with check((select private.verified_portal_session()));
create policy uw_files_read on public.underwriting_guide_file_chunks for select to authenticated using(exists(select 1 from public.underwriting_guides g where g.id=guide_id));
create policy uw_files_manage on public.underwriting_guide_file_chunks for all to authenticated using((select public.is_super_admin())) with check((select public.is_super_admin()));
create function public.search_underwriting_guides(query_text text, coverage_type text)
returns table(guide_id uuid,page_number integer,body text,score real)
language sql stable security invoker set search_path = '' as $$
 with matches as (
 select p.guide_id,p.page_number,p.body,ts_rank_cd(p.search_vector,websearch_to_tsquery('english',left(query_text,500))) as score,
 row_number() over(partition by p.guide_id order by ts_rank_cd(p.search_vector,websearch_to_tsquery('english',left(query_text,500))) desc,p.page_number) as rn
 from public.underwriting_guide_pages p join public.underwriting_guides g on g.id=p.guide_id
 where g.active and g.kind<>'rates' and coverage_type=any(g.coverage_types)
 and p.search_vector @@ websearch_to_tsquery('english',left(query_text,500))
 and (g.page_scopes='[]'::jsonb or exists(select 1 from jsonb_array_elements(g.page_scopes) s where p.page_number between (s->>'from')::int and (s->>'to')::int and s->'coverage' ? coverage_type))
 ) select guide_id,page_number,body,score from matches where rn<=3 order by score desc,guide_id,page_number limit 60;
$$;
revoke all on function public.search_underwriting_guides(text,text) from public,anon;
grant execute on function public.search_underwriting_guides(text,text) to authenticated;
commit;

create function public.publish_underwriting_guide(new_guide_id uuid, replace_guide_id uuid default null)
returns uuid language plpgsql security invoker set search_path='' as $$
declare g public.underwriting_guides; p integer; c integer; lo integer; hi integer; encoded text; pdf bytea;
begin
 if not (select private.verified_portal_session()) or not (select public.is_super_admin()) then raise exception 'Only the verified Master can publish guides.' using errcode='42501'; end if;
 select * into g from public.underwriting_guides where id=new_guide_id for update;
 if not found then raise exception 'Guide was not found.'; end if;
 select count(*) into p from public.underwriting_guide_pages where guide_id=g.id;
 select count(*),min(chunk_number),max(chunk_number),string_agg(data_base64,'' order by chunk_number) into c,lo,hi,encoded from public.underwriting_guide_file_chunks where guide_id=g.id;
 if p<>g.page_count or c<>g.file_chunks or c=0 or lo<>0 or hi<>c-1 then raise exception 'Guide upload is incomplete.'; end if;
 if (select min(page_number)<>1 or max(page_number)<>g.page_count from public.underwriting_guide_pages where guide_id=g.id) then raise exception 'Guide pages are incomplete.'; end if;
 pdf:=decode(encoded,'base64');
 if octet_length(pdf)>20971520 or substring(pdf from 1 for 5)<>decode('255044462d','hex') or encode(sha256(pdf),'hex') is distinct from g.file_sha256 then raise exception 'Guide PDF failed integrity verification.'; end if;
 if replace_guide_id is not null then
  if replace_guide_id=new_guide_id or not exists(select 1 from public.underwriting_guides where id=replace_guide_id and carrier=g.carrier) then raise exception 'Choose a different guide from the same carrier to replace.'; end if;
  update public.underwriting_guides set active=false,updated_at=now() where id=replace_guide_id;
 end if;
 update public.underwriting_guides set active=true,updated_at=now() where id=new_guide_id;
 return new_guide_id;
end;
$$;
revoke all on function public.publish_underwriting_guide(uuid,uuid) from public,anon;
grant execute on function public.publish_underwriting_guide(uuid,uuid) to authenticated;
