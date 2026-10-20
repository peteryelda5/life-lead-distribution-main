-- Live conversation text is available only through the MFA-authenticated server API.
create table public.dialer_conversations (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references public.profiles(id), livemode boolean not null,
 kind text not null check(kind in ('power','call','incoming')), source_id uuid not null,
 lead_id uuid references public.leads(id) on delete set null, phone text not null,
 provider_sid text not null check(provider_sid ~ '^AC[0-9a-fA-F]{32}$'), call_sid text not null check(call_sid ~ '^CA[0-9a-fA-F]{32}$'),
 inbound_speaker text not null check(inbound_speaker in ('agent','client')),
 service_sid text not null check(service_sid ~ '^GA[0-9a-fA-F]{32}$'), operator_sid text not null check(operator_sid ~ '^LY[0-9a-fA-F]{32}$'),
 transcription_sid text unique check(transcription_sid ~ '^GT[0-9a-fA-F]{32}$'),
 state text not null default 'starting' check(state in ('starting','live','stopped','error')),
 consent_at timestamptz not null default now(), created_at timestamptz not null default now(), stopped_at timestamptz,
 expires_at timestamptz not null default now()+interval '30 days', error_code text,
 summary text check(length(summary)<=16000), summary_checked_at timestamptz, provider_checked_at timestamptz,
 unique(provider_sid,call_sid), unique(user_id,livemode,kind,source_id)
);
create index dialer_conversations_owner on public.dialer_conversations(user_id,livemode,created_at desc);
create table public.dialer_conversation_lines (
 conversation_id uuid not null references public.dialer_conversations(id) on delete cascade,
 sequence integer not null check(sequence between 0 and 100000), speaker text not null check(speaker in ('agent','client')),
 spoken_at timestamptz not null, content text not null check(length(content) between 1 and 8000),
 primary key(conversation_id,sequence)
);
alter table public.dialer_conversations enable row level security;
alter table public.dialer_conversation_lines enable row level security;
revoke all on public.dialer_conversations,public.dialer_conversation_lines from public,anon,authenticated;
grant select,insert,update,delete on public.dialer_conversations,public.dialer_conversation_lines to service_role;
create policy conversation_service on public.dialer_conversations for all to service_role using(true) with check(true);
create policy conversation_lines_service on public.dialer_conversation_lines for all to service_role using(true) with check(true);

-- Serialize starts so retries / two browser tabs cannot create duplicate paid streams.
create function public.dialer_conversation_claim(p_data jsonb) returns jsonb language plpgsql security invoker set search_path='' as $$
declare c public.dialer_conversations%rowtype;
begin
 insert into public.dialer_conversations(user_id,livemode,kind,source_id,lead_id,phone,provider_sid,call_sid,inbound_speaker,service_sid,operator_sid)
 values((p_data->>'user_id')::uuid,(p_data->>'livemode')::boolean,p_data->>'kind',(p_data->>'source_id')::uuid,(p_data->>'lead_id')::uuid,p_data->>'phone',p_data->>'provider_sid',p_data->>'call_sid',p_data->>'inbound_speaker',p_data->>'service_sid',p_data->>'operator_sid')
 on conflict do nothing returning * into c;
 if c.id is not null then return jsonb_build_object('created',true,'conversation',to_jsonb(c));end if;
 select * into c from public.dialer_conversations where user_id=(p_data->>'user_id')::uuid and livemode=(p_data->>'livemode')::boolean and kind=p_data->>'kind' and source_id=(p_data->>'source_id')::uuid;
 if c.id is null then raise exception 'Call already has a transcript';end if;
 return jsonb_build_object('created',false,'conversation',to_jsonb(c));
end $$;

-- Signed Twilio events can be duplicated or arrive out of order.
create function public.dialer_conversation_event(p_id uuid,p_account text,p_call text,p_transcription text,p_event text,p_sequence integer,p_track text,p_content text,p_time timestamptz,p_error text)
returns void language plpgsql security invoker set search_path='' as $$
declare c public.dialer_conversations%rowtype;
begin
 select * into c from public.dialer_conversations where id=p_id for update;
 if c.id is null or c.provider_sid<>p_account or c.call_sid<>p_call or p_transcription !~ '^GT[0-9a-fA-F]{32}$' or (c.transcription_sid is not null and c.transcription_sid<>p_transcription) then raise exception 'Transcript ownership mismatch';end if;
 if c.expires_at<=now() then return;end if;
 update public.dialer_conversations set transcription_sid=p_transcription where id=p_id;
 if p_event='transcription-content' then
  if p_track not in ('inbound_track','outbound_track') or p_content is null or p_time is null then raise exception 'Invalid transcript line';end if;
  insert into public.dialer_conversation_lines(conversation_id,sequence,speaker,spoken_at,content)
  values(p_id,p_sequence,case when p_track='inbound_track' then c.inbound_speaker when c.inbound_speaker='agent' then 'client' else 'agent' end,p_time,p_content)
  on conflict do nothing;
  update public.dialer_conversations set state='live',error_code=null where id=p_id and state='starting';
 elsif p_event='transcription-started' then
  update public.dialer_conversations set state='live',error_code=null where id=p_id and state='starting';
 elsif p_event='transcription-stopped' then
  update public.dialer_conversations set state='stopped',stopped_at=coalesce(stopped_at,now()) where id=p_id;
 elsif p_event='transcription-error' then
  update public.dialer_conversations set state='error',error_code=left(p_error,40),stopped_at=coalesce(stopped_at,now()) where id=p_id and state<>'stopped';
 else raise exception 'Invalid transcript event';end if;
end $$;
revoke all on function public.dialer_conversation_claim(jsonb),public.dialer_conversation_event(uuid,text,text,text,text,integer,text,text,timestamptz,text) from public,anon,authenticated;
grant execute on function public.dialer_conversation_claim(jsonb),public.dialer_conversation_event(uuid,text,text,text,text,integer,text,text,timestamptz,text) to service_role;
