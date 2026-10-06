alter table public.dialer_calls add column call_kind text not null default 'lead' check(call_kind in ('lead','manual'));
create function public.dialer_create_manual_call(p_user uuid,p_session uuid,p_live boolean,p_phone text,p_call uuid,p_slot integer) returns jsonb language plpgsql security invoker set search_path='' as $$
declare a public.dialer_accounts%rowtype;number text;destination text;used integer;reserve integer;remaining integer;limit_seconds integer;begin
 select * into a from public.dialer_accounts where user_id=p_user and livemode=p_live for update;
 if not found or not private.dialer_session_active(p_user,p_session) or not public.dialer_entitled(p_user,p_live) or (not p_live and p_user<>'8139e230-055d-4247-8133-684ed817b4fa'::uuid) then raise exception 'An active live subscription is required for agent calling';end if;
 if exists(select 1 from public.dialer_calls where user_id=p_user and livemode=p_live and not finished and ((parent_sid is null and expires_at>now()) or (parent_sid is not null and created_at>now()-interval '40 minutes'))) then raise exception 'Finish the current call or refresh its usage before dialing again';end if;
 select phone into number from public.dialer_numbers where user_id=p_user and livemode=p_live and slot=p_slot and state='active';if number is null then raise exception 'Activate your selected caller ID first';end if;
 destination:=p_phone;if destination is null or destination !~ '^\+1[2-9][0-9]{2}[2-9][0-9]{6}$' then raise exception 'Enter a valid US phone number';end if;if destination=number then raise exception 'You cannot call your caller ID';end if;
 select coalesce(sum(used_minutes),0),coalesce(sum(case when not finished and parent_sid is not null then (max_seconds+59)/60 else 0 end),0) into used,reserve from public.dialer_calls where user_id=p_user and livemode=p_live and period_start=a.period_start;
 remaining:=5000+a.overage_limit_cents/3-used-reserve;if remaining<=0 then raise exception 'Your extra-minute spending limit has been reached';end if;limit_seconds:=least(1800,remaining*60);
 insert into public.dialer_calls(id,user_id,livemode,period_start,lead_id,session_id,phone,caller_id,max_seconds,call_kind) values(p_call,p_user,p_live,a.period_start,null,p_session,destination,number,limit_seconds,'manual');
 return jsonb_build_object('to',destination,'callerId',number,'maxSeconds',limit_seconds);
end $$;
create or replace function public.dialer_consume_call(p_call uuid,p_parent text) returns jsonb language plpgsql security invoker set search_path='' as $$
declare c public.dialer_calls%rowtype;begin
 if p_parent is null or p_parent !~ '^CA[0-9a-fA-F]{32}$' then raise exception 'Invalid call reference';end if;
 select * into c from public.dialer_calls where id=p_call for update;
 if not found or c.finished or c.expires_at<=now() or (c.parent_sid is not null and c.parent_sid<>p_parent) or not private.dialer_session_active(c.user_id,c.session_id) or not public.dialer_entitled(c.user_id,c.livemode) or (c.call_kind='lead' and (c.lead_id is null or public.dialer_lead_phone(c.user_id,c.lead_id) is distinct from c.phone)) or (c.call_kind='manual' and c.phone !~ '^\+1[2-9][0-9]{2}[2-9][0-9]{6}$') or not exists(select 1 from public.dialer_numbers where user_id=c.user_id and livemode=c.livemode and phone=c.caller_id and state='active') then raise exception 'Call authorization expired or lead assignment changed';end if;
 update public.dialer_calls set parent_sid=p_parent where id=p_call;return jsonb_build_object('userId',c.user_id,'to',c.phone,'callerId',c.caller_id,'maxSeconds',c.max_seconds);
end $$;

revoke all on function public.dialer_create_manual_call(uuid,uuid,boolean,text,uuid,integer) from public,anon,authenticated;grant execute on function public.dialer_create_manual_call(uuid,uuid,boolean,text,uuid,integer) to service_role;
