begin;
-- Audio is received from Media Streams, never Twilio Recordings.
create table if not exists public.dialer_private_recordings (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references public.profiles(id),
 power_id uuid not null unique references public.dialer_parallel_sessions(id),
 lead_id uuid, phone text not null, client_name text not null,
 provider_sid text not null, call_sid text not null, stream_sid text,
 consent_at timestamptz not null default now(), created_at timestamptz not null default now(),
 heartbeat_at timestamptz not null default now(), stopped_at timestamptz,
 state text not null default 'starting' check(state in ('starting','streaming','processing','ready','partial','failed')),
 issue text, audio_path text, duration_ms integer not null default 0,
 grant_hash text not null, grant_expires_at timestamptz not null default now()+interval '90 seconds',
 provider_recordings_checked boolean not null default false
);
create table if not exists public.dialer_recording_parts (
 recording_id uuid not null references public.dialer_private_recordings(id),
 position integer not null check(position between 0 and 60),
 path text not null, samples integer not null check(samples between 1 and 80000),
 sha256 text not null, primary key(recording_id,position)
);
alter table public.dialer_private_recordings enable row level security;
alter table public.dialer_recording_parts enable row level security;
revoke all on public.dialer_private_recordings,public.dialer_recording_parts from public,anon,authenticated;
grant select,insert,update on public.dialer_private_recordings,public.dialer_recording_parts to service_role;
drop policy if exists dialer_private_recordings_service on public.dialer_private_recordings;
create policy dialer_private_recordings_service on public.dialer_private_recordings for all to service_role using(true) with check(true);
drop policy if exists dialer_recording_parts_service on public.dialer_recording_parts;
create policy dialer_recording_parts_service on public.dialer_recording_parts for all to service_role using(true) with check(true);
create index if not exists dialer_private_recordings_owner_date on public.dialer_private_recordings(user_id,created_at desc);
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('dialer-recordings','dialer-recordings',false,20971520,array['audio/wav'])
on conflict(id) do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;
-- Defense against unrelated future permissive Storage policies.
drop policy if exists dialer_recordings_no_browser on storage.objects;
create policy dialer_recordings_no_browser on storage.objects as restrictive for all to anon,authenticated
using(bucket_id<>'dialer-recordings') with check(bucket_id<>'dialer-recordings');
create or replace function public.dialer_recordings_access(p_actor uuid,p_session uuid,p_id uuid default null)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare result jsonb;
begin
 if not private.dialer_session_active(p_actor,p_session) then raise exception 'Session expired' using errcode='42501';end if;
 if p_id is not null then
  select to_jsonb(r) into result from public.dialer_private_recordings r
  where r.id=p_id and r.user_id in(select private.dialer_workspace_scope(p_actor));
  if result is null then raise exception 'Recording unavailable' using errcode='42501';end if;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
  values(p_actor,'recording_playback_requested','dialer_private_recording',p_id::text,'{"storage":"private_portal"}'::jsonb);
  return result;
 end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]') into result from (
  select r.id,r.created_at,r.state,r.issue,r.duration_ms,r.client_name,r.phone,r.user_id,
   p.full_name as agent_name,r.audio_path is not null as playable,r.provider_recordings_checked
  from public.dialer_private_recordings r join public.profiles p on p.id=r.user_id
  where r.user_id in(select private.dialer_workspace_scope(p_actor)) order by r.created_at desc limit 100
 )x;
 return result;
end $$;
revoke all on function public.dialer_recordings_access(uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.dialer_recordings_access(uuid,uuid,uuid) to service_role;
notify pgrst,'reload schema';
commit;
