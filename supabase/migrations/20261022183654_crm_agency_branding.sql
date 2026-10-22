-- Branding is separate from client records and is always resolved from current membership.
create table private.agency_branding (
 agency_id text primary key references public.divisions(id),
 logo_path text,updated_at timestamptz not null default clock_timestamp(),
 updated_by uuid not null references public.profiles(id)
);
create index agency_branding_actor on private.agency_branding(updated_by);
alter table private.agency_branding enable row level security;
revoke all on private.agency_branding from public,anon,authenticated;

create function private.agency_branding_manage(p_agency text) returns boolean
language sql stable security definer set search_path='' as $$
 select private.verified_portal_session() and exists(
  select 1 from public.profiles p join public.divisions d on d.id=p_agency and not d.archived
  where p.id=auth.uid() and p.role='admin' and p.active and not coalesce(p.archived,false)
  and (p.is_super_admin or p.division=d.id))
$$;
create function private.agency_branding_upload_path(p_path text) returns boolean
language sql stable security definer set search_path='' as $$
 select private.agency_branding_manage(split_part(p_path,'/',1))
 and split_part(p_path,'/',2)=auth.uid()::text
 and p_path ~ '^[a-z0-9_]+/[0-9a-f-]{36}/[0-9a-f-]{36}\.(png|jpg|webp)$'
$$;
revoke all on function private.agency_branding_manage(text),private.agency_branding_upload_path(text) from public,anon,authenticated;
grant execute on function private.agency_branding_manage(text),private.agency_branding_upload_path(text) to authenticated;

-- Logos are public brand assets, not client documents. Immutable unique paths avoid stale CDN images.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
 values('agency-logos','agency-logos',true,2097152,array['image/png','image/jpeg','image/webp']);
create policy agency_logos_insert on storage.objects for insert to authenticated
 with check(bucket_id='agency-logos' and private.agency_branding_upload_path(name));
create policy agency_logos_admin_read on storage.objects for select to authenticated
 using(bucket_id='agency-logos' and private.agency_branding_manage((storage.foldername(name))[1]));
-- No UPDATE policy: an active logo cannot be overwritten behind the version-checked API.
create function private.agency_branding_unused_upload(p_path text) returns boolean
language sql stable security definer set search_path='' as $$
 select private.agency_branding_upload_path(p_path) and not exists(select 1 from private.agency_branding where logo_path=p_path)
$$;
revoke all on function private.agency_branding_unused_upload(text) from public,anon,authenticated;
grant execute on function private.agency_branding_unused_upload(text) to authenticated;
create policy agency_logos_remove_unused on storage.objects for delete to authenticated
 using(bucket_id='agency-logos' and private.agency_branding_unused_upload(name));

create function private.agency_branding_context() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare own text; result jsonb;
begin
 if not private.verified_portal_session() then raise exception 'Sign in and complete verification to view agency branding' using errcode='42501';end if;
 select division into own from public.profiles where id=auth.uid();
 select jsonb_build_object(
 'agency',(select jsonb_build_object('id',d.id,'name',d.name,'logo_path',b.logo_path,'updated_at',b.updated_at) from public.divisions d left join private.agency_branding b on b.agency_id=d.id where d.id=own and not d.archived),
 'manageable',coalesce((select jsonb_agg(jsonb_build_object('id',d.id,'name',d.name,'logo_path',b.logo_path,'updated_at',b.updated_at) order by d.name) from public.divisions d left join private.agency_branding b on b.agency_id=d.id where private.agency_branding_manage(d.id)),'[]')) into result;
 return result;
end;$$;
create function private.agency_branding_save(p_agency text,p_logo_path text,p_expected_updated_at timestamptz default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare previous private.agency_branding%rowtype; stamp timestamptz; exists_row boolean;
begin
 if not private.agency_branding_manage(p_agency) then raise exception 'Only your agency admin or a Super Master can change this logo' using errcode='42501';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_agency,49414));
 select * into previous from private.agency_branding where agency_id=p_agency for update;exists_row:=found;
 if exists_row and previous.logo_path is not distinct from p_logo_path then return jsonb_build_object('ok',true,'updated_at',previous.updated_at);end if;
 if previous.updated_at is distinct from p_expected_updated_at then raise sqlstate 'PT409' using message='Agency logo changed. Reopen Agency logo settings before saving.';end if;
 if p_logo_path is not null then
  if not private.agency_branding_upload_path(p_logo_path) or split_part(p_logo_path,'/',1)<>p_agency then raise exception 'Upload a new logo for this agency' using errcode='42501';end if;
  if not exists(select 1 from storage.objects o where o.bucket_id='agency-logos' and o.name=p_logo_path
    and o.metadata->>'mimetype'=any(array['image/png','image/jpeg','image/webp']) and (o.metadata->>'size')::bigint between 1 and 2097152) then raise exception 'Logo upload is missing or invalid. Choose PNG, JPG or WebP up to 2 MB';end if;
 end if;
 stamp:=clock_timestamp();
 insert into private.agency_branding(agency_id,logo_path,updated_at,updated_by) values(p_agency,p_logo_path,stamp,auth.uid())
 on conflict(agency_id) do update set logo_path=excluded.logo_path,updated_at=excluded.updated_at,updated_by=excluded.updated_by;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'agency_logo_updated','agency',p_agency,jsonb_build_object('previous_logo',previous.logo_path,'logo',p_logo_path));
 return jsonb_build_object('ok',true,'updated_at',stamp);
end;$$;
create function public.agency_branding_context() returns jsonb language sql security invoker set search_path='' as $$select private.agency_branding_context()$$;
create function public.agency_branding_save(p_agency text,p_logo_path text,p_expected_updated_at timestamptz default null) returns jsonb language sql security invoker set search_path='' as $$select private.agency_branding_save(p_agency,p_logo_path,p_expected_updated_at)$$;
revoke all on function private.agency_branding_context(),public.agency_branding_context(),private.agency_branding_save(text,text,timestamptz),public.agency_branding_save(text,text,timestamptz) from public,anon,authenticated;
grant execute on function private.agency_branding_context(),public.agency_branding_context(),private.agency_branding_save(text,text,timestamptz),public.agency_branding_save(text,text,timestamptz) to authenticated;
notify pgrst,'reload schema';
