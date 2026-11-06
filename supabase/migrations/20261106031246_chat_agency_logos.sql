-- Public brand assets only, scoped to the same agency set as Live Chat.
create or replace function private.chat_agency_logos()
returns jsonb language plpgsql stable security definer set search_path='' set statement_timeout='5s' as $$
declare result jsonb;
begin
 if not private.verified_portal_session() then raise exception 'Verified session required' using errcode='42501';end if;
 perform public.require_portal_onboarding();
 select coalesce(jsonb_agg(jsonb_build_object('id',d.id,'name',d.name,'logo_path',b.logo_path) order by d.id),'[]'::jsonb)
 into result from public.divisions d left join private.agency_branding b on b.agency_id=d.id
 where d.id=any(private.shared_chat_divisions());
 return result;
end $$;
create or replace function public.chat_agency_logos() returns jsonb language sql stable security invoker set search_path='' set statement_timeout='5s' as $$select private.chat_agency_logos()$$;
revoke all on function private.chat_agency_logos(),public.chat_agency_logos() from public,anon;
grant execute on function private.chat_agency_logos(),public.chat_agency_logos() to authenticated;
