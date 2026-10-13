create table public.dialer_incoming_presence (
 user_id uuid not null references public.profiles(id), livemode boolean not null,
 session_id uuid not null, browser_id uuid not null, identity text not null,
 ready_until timestamptz not null default now(), busy boolean not null default true,
 primary key(user_id,livemode,browser_id)
);
create table public.dialer_callbacks (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references public.profiles(id),
 livemode boolean not null, provider_sid text not null check(provider_sid ~ '^AC[0-9a-fA-F]{32}$'),
 parent_sid text not null unique check(parent_sid ~ '^CA[0-9a-fA-F]{32}$'),
 caller_phone text not null, dialed_phone text not null, ring_identity text,
 status text not null default 'missed' check(status in ('ringing','answered','missed','voicemail')),
 created_at timestamptz not null default now(), answered_at timestamptz, completed_at timestamptz,
 duration_seconds integer not null default 0 check(duration_seconds between 0 and 7200),
 recording_sid text check(recording_sid ~ '^RE[0-9a-fA-F]{32}$'),
 recording_seconds integer check(recording_seconds between 0 and 125), recording_path text,
 recording_pending boolean not null default false, provider_copy_removed boolean not null default false, seen_at timestamptz
);
create index dialer_callbacks_owner_created on public.dialer_callbacks(user_id,livemode,created_at desc,id desc);
create index dialer_callbacks_unread on public.dialer_callbacks(user_id) where seen_at is null and status in ('missed','voicemail');
alter table public.dialer_callbacks enable row level security;
alter table public.dialer_incoming_presence enable row level security;
revoke all on public.dialer_callbacks,public.dialer_incoming_presence from public,anon,authenticated;
grant select,insert,update,delete on public.dialer_callbacks,public.dialer_incoming_presence to service_role;
create policy callbacks_service on public.dialer_callbacks for all to service_role using(true) with check(true);
create policy presence_service on public.dialer_incoming_presence for all to service_role using(true) with check(true);
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
 values('dialer-voicemails','dialer-voicemails',false,3145728,array['audio/mpeg']) on conflict(id) do nothing;

create function public.dialer_callback_presence(p_user uuid,p_live boolean,p_session uuid,p_browser uuid,p_ready boolean,p_busy boolean)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare who text:='vivid_in_'||replace(p_user::text,'-','')||'_'||replace(p_browser::text,'-','');
begin
 if not private.dialer_session_active(p_user,p_session) then raise exception 'Session is no longer active';end if;
 if p_ready and not public.dialer_entitled(p_user,p_live) then raise exception 'Calling access is unavailable';end if;
 delete from public.dialer_incoming_presence where user_id=p_user and ready_until<now()-interval '1 day';
 insert into public.dialer_incoming_presence(user_id,livemode,session_id,browser_id,identity,ready_until,busy)
 values(p_user,p_live,p_session,p_browser,who,case when p_ready then now()+interval '65 seconds' else now() end,p_busy)
 on conflict(user_id,livemode,browser_id) do update set session_id=excluded.session_id,identity=excluded.identity,ready_until=excluded.ready_until,busy=excluded.busy;
 return jsonb_build_object('identity',who);
end $$;

create function public.dialer_callback_start(p_user uuid,p_live boolean,p_account text,p_parent text,p_from text,p_to text)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare c public.dialer_callbacks%rowtype; endpoint text;
begin
 if not exists(select 1 from public.profiles where id=p_user and active and not archived and role in ('agent','admin'))
 or not (exists(select 1 from public.dialer_numbers where user_id=p_user and livemode=p_live and state='active' and phone=p_to)
 or (p_live and exists(select 1 from public.master_dialer_numbers where user_id=p_user and state='active' and phone_number=p_to))) then
 raise exception 'Number is unavailable';end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('dialer-incoming:'||p_user::text,0));
 select * into c from public.dialer_callbacks where parent_sid=p_parent;
 if found then
  if c.user_id<>p_user or c.provider_sid<>p_account or c.dialed_phone<>p_to then raise exception 'Call ownership mismatch';end if;
  return jsonb_build_object('id',c.id,'identity',case when c.status='ringing' and c.created_at>now()-interval '40 seconds' then c.ring_identity end);
 end if;
 if not exists(select 1 from public.dialer_callbacks where user_id=p_user and completed_at is null
   and ((status='ringing' and created_at>now()-interval '45 seconds') or (status='answered' and created_at>now()-interval '35 minutes')))
 and not exists(select 1 from public.dialer_calls where user_id=p_user and not finished
   and ((parent_sid is not null and created_at>now()-interval '35 minutes') or expires_at>now())) then
  select p.identity into endpoint from public.dialer_incoming_presence p
   where p.user_id=p_user and p.livemode=p_live and p.ready_until>now() and not p.busy
    and private.dialer_session_active(p.user_id,p.session_id)
   order by p.ready_until desc limit 1;
 end if;
 insert into public.dialer_callbacks(user_id,livemode,provider_sid,parent_sid,caller_phone,dialed_phone,ring_identity,status)
 values(p_user,p_live,p_account,p_parent,left(p_from,64),p_to,endpoint,case when endpoint is null then 'missed' else 'ringing' end) returning * into c;
 return jsonb_build_object('id',c.id,'identity',endpoint);
end $$;

create function public.dialer_callback_event(p_account text,p_parent text,p_event text,p_seconds integer default 0)
returns void language plpgsql security invoker set search_path='' as $$
begin
 if p_event not in ('answered','completed','missed','recording') or p_seconds not between 0 and 7200 then raise exception 'Invalid call event';end if;
 update public.dialer_callbacks set
  status=case when status='voicemail' then status when p_event in ('answered','completed') then 'answered'
    when answered_at is not null then 'answered' else 'missed' end,
  answered_at=case when p_event in ('answered','completed') then coalesce(answered_at,now()) else answered_at end,
  completed_at=case when p_event in ('completed','missed') then coalesce(completed_at,now()) else completed_at end,
  duration_seconds=greatest(duration_seconds,p_seconds),
  recording_pending=case when p_event='recording' and recording_path is null then true else recording_pending end
 where parent_sid=p_parent and provider_sid=p_account;
 if not found then raise exception 'Unknown callback';end if;
end $$;

create function public.dialer_callback_list(p_user uuid,p_live boolean,p_offset integer default 0,p_id uuid default null)
returns jsonb language sql stable security invoker set search_path='' as $$
 select jsonb_build_object('unread',(select count(*) from public.dialer_callbacks where user_id=p_user and livemode=p_live and seen_at is null and (status in ('missed','voicemail') or (status='ringing' and created_at<now()-interval '45 seconds'))),
 'calls',coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc,x.id desc) from (
  select c.id,c.caller_phone,c.dialed_phone,
   case when c.status='ringing' and c.created_at<now()-interval '45 seconds' then 'missed' else c.status end status,
   c.created_at,c.duration_seconds,c.recording_seconds,c.recording_pending,c.seen_at,c.recording_path is not null has_voicemail,
   coalesce((select jsonb_agg(to_jsonb(l)) from (
     select l.id,l.first_name,l.last_name,l.phone,l.email,l.state,l.lead_type,l.agent_status,l.call_notes,l.csv_headers,l.csv_values
     from public.leads l where l.assigned_to=p_user and l.status='assigned'
      and c.caller_phone ~ '^\+1[0-9]{10}$'
      and right(regexp_replace(coalesce(l.phone,''),'[^0-9]','','g'),10)=right(c.caller_phone,10)
     order by l.id limit 20) l),'[]'::jsonb) matches
  from public.dialer_callbacks c where c.user_id=p_user and c.livemode=p_live and (p_id is null or c.id=p_id)
  order by c.created_at desc,c.id desc limit 50 offset greatest(0,least(coalesce(p_offset,0),100000))
 ) x),'[]'::jsonb));
$$;

create function private.my_dialer_callback_unread() returns bigint language plpgsql stable security definer set search_path='' as $$
begin
 if not private.verified_portal_session() then raise exception 'Two-step verification required' using errcode='42501';end if;
 return (select count(*) from public.dialer_callbacks where user_id=auth.uid() and livemode and seen_at is null
  and (status in ('missed','voicemail') or (status='ringing' and created_at<now()-interval '45 seconds')));
end $$;
create function public.my_dialer_callback_unread() returns bigint language sql stable security invoker set search_path='' as $$ select private.my_dialer_callback_unread(); $$;
revoke all on function private.my_dialer_callback_unread(),public.my_dialer_callback_unread() from public,anon;
grant execute on function private.my_dialer_callback_unread(),public.my_dialer_callback_unread() to authenticated;
do $$ declare f record;begin
 for f in select oid::regprocedure fn from pg_proc where pronamespace='public'::regnamespace and proname in
 ('dialer_callback_presence','dialer_callback_start','dialer_callback_event','dialer_callback_list') loop
  execute 'revoke all on function '||f.fn||' from public,anon,authenticated';
  execute 'grant execute on function '||f.fn||' to service_role';
 end loop;
end $$;
