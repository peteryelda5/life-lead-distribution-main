-- A policy identifier is returned only under the existing Book of Business scope.
-- Client details remain behind the existing PIN-protected detail RPC.
create or replace function private.chat_deal_policy_link(p_deal uuid)
returns uuid language plpgsql stable security definer set search_path='' set statement_timeout='5s' as $$
declare result uuid;
begin
 if not private.verified_portal_session() then raise exception 'Verified session required' using errcode='42501';end if;
 perform public.require_portal_onboarding();
 select c.id into result from private.book_crm_clients c where c.deal_id=p_deal and private.book_crm_can_access(c.agent_id,c.deal_id) limit 1;
 return result;
end $$;
create or replace function public.chat_deal_view(p_message bigint)
returns jsonb language plpgsql stable set search_path='' set statement_timeout='5s' as $$
declare message public.chat_messages; policy uuid;
begin
 if not private.verified_portal_session() then raise exception 'Verified session required' using errcode='42501';end if;
 perform public.require_portal_onboarding();
 -- SECURITY INVOKER deliberately retains chat_messages SELECT RLS.
 select * into message from public.chat_messages where id=p_message and kind='deal';
 if message.id is null then raise exception 'Deal announcement unavailable' using errcode='42501';end if;
 if coalesce((message.deal->>'withdrawn')::boolean,false) then return jsonb_build_object('withdrawn',true);end if;
 policy:=private.chat_deal_policy_link(message.source_deal_id);
 return jsonb_build_object('agent_name',message.author_name,'agency',message.division,
 'carrier',message.deal->>'carrier','product',message.deal->>'policy_type',
 'monthly_premium',message.deal->'monthly_premium','annual_premium',message.deal->'annual_premium',
 'submitted_at',message.created_at,'policy_id',policy,'withdrawn',false);
end $$;
revoke all on function private.chat_deal_policy_link(uuid),public.chat_deal_view(bigint) from public,anon;
grant execute on function private.chat_deal_policy_link(uuid),public.chat_deal_view(bigint) to authenticated;
