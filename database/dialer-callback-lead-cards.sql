-- Match the same supported phone field used by the outgoing dialer, without
-- throwing when an unrelated imported lead has an invalid phone.
create function private.dialer_callback_phone(p_phone text,p_headers jsonb,p_values jsonb)
returns text language plpgsql immutable security invoker set search_path='' as $$
declare raw text:=nullif(trim(p_phone),''); digits text; hits integer:=0; i integer;
begin
 if raw is null and jsonb_typeof(p_headers)='array' and jsonb_typeof(p_values)='array' then
  for i in 0..jsonb_array_length(p_headers)-1 loop
   if lower(regexp_replace(p_headers->>i,'[^a-zA-Z0-9]','','g')) in ('phone','phonenumber','mobile','mobilephone','cell','cellphone','telephone') then
    hits:=hits+1;raw:=p_values->>i;
   end if;
  end loop;
  if hits<>1 then return null;end if;
 end if;
 if raw is null or raw !~ '^[+0-9().[:space:]-]+$' then return null;end if;
 digits:=regexp_replace(raw,'[^0-9]','','g');
 if length(digits)=11 and left(digits,1)='1' then digits:=substring(digits,2);end if;
 if digits !~ '^[2-9][0-9]{2}[2-9][0-9]{6}$' then return null;end if;
 return '+1'||digits;
end $$;
revoke all on function private.dialer_callback_phone(text,jsonb,jsonb) from public,anon,authenticated;
grant execute on function private.dialer_callback_phone(text,jsonb,jsonb) to service_role;

create or replace function public.dialer_callback_list(p_user uuid,p_live boolean,p_offset integer default 0,p_id uuid default null)
returns jsonb language sql stable security invoker set search_path='' as $$
 select jsonb_build_object('unread',(select count(*) from public.dialer_callbacks where user_id=p_user and livemode=p_live and seen_at is null and (status in ('missed','voicemail') or (status='ringing' and created_at<now()-interval '45 seconds'))),
 'calls',coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc,x.id desc) from (
  select c.id,c.caller_phone,c.dialed_phone,
   case when c.status='ringing' and c.created_at<now()-interval '45 seconds' then 'missed' else c.status end status,
   c.created_at,c.duration_seconds,c.recording_seconds,c.recording_pending,c.seen_at,c.recording_path is not null has_voicemail,
   coalesce((select jsonb_agg(to_jsonb(l)) from (
     select l.id,l.first_name,l.last_name,coalesce(nullif(trim(l.phone),''),private.dialer_callback_phone(l.phone,l.csv_headers,l.csv_values)) phone,l.email,l.state,l.lead_type,l.agent_status,l.call_notes,l.csv_headers,l.csv_values
     from public.leads l where l.assigned_to=p_user and l.status='assigned'
      and c.caller_phone ~ '^[+]1[0-9]{10}$'
      and private.dialer_callback_phone(l.phone,l.csv_headers,l.csv_values)=c.caller_phone
     order by l.id limit 20) l),'[]'::jsonb) matches
  from public.dialer_callbacks c where c.user_id=p_user and c.livemode=p_live and (p_id is null or c.id=p_id)
  order by c.created_at desc,c.id desc limit 50 offset greatest(0,least(coalesce(p_offset,0),100000))
 ) x),'[]'::jsonb));
$$;

revoke all on function public.dialer_callback_list(uuid,boolean,integer,uuid) from public,anon,authenticated;
grant execute on function public.dialer_callback_list(uuid,boolean,integer,uuid) to service_role;
