-- Opt-in phone push. Endpoints and encryption keys are private, service-only.
create table private.portal_push_devices (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references public.profiles(id) on delete cascade,
 session_id uuid not null references auth.sessions(id) on delete cascade,
 endpoint text not null unique check(length(endpoint) between 20 and 2048),
 p256dh text not null check(p256dh ~ '^[A-Za-z0-9_-]{87}$'),
 auth_key text not null check(auth_key ~ '^[A-Za-z0-9_-]{22}$'),
 enabled boolean not null default true,
 categories text[] not null default array['leads','requests','calls','deals','chat','announcements','team','billing']::text[]
  check(categories <@ array['leads','requests','calls','deals','chat','announcements','team','billing']::text[]),
 started_at timestamptz not null default now(),
 scanned_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 test_at timestamptz,
 last_status integer
);
create index portal_push_devices_user on private.portal_push_devices(user_id);
create index portal_push_devices_session on private.portal_push_devices(session_id);
create index portal_push_devices_scan on private.portal_push_devices(scanned_at) where enabled;

create table private.portal_push_deliveries (
 id uuid primary key default gen_random_uuid(),
 device_id uuid not null references private.portal_push_devices(id) on delete cascade,
 event_key text not null check(length(event_key) between 1 and 200),
 event_version text not null check(length(event_version) between 1 and 100),
 category text not null,
 occurred_at timestamptz not null,
 state text not null default 'pending' check(state in ('pending','sending','sent','skipped','failed')),
 attempts integer not null default 0,
 lease uuid,
 next_attempt timestamptz not null default now(),
 created_at timestamptz not null default now(),
 last_status integer,
 unique(device_id,event_key,event_version)
);
create index portal_push_deliveries_due on private.portal_push_deliveries(next_attempt,created_at) where state in ('pending','sending');
create index portal_push_deliveries_created on private.portal_push_deliveries(created_at);
alter table private.portal_push_devices enable row level security;
alter table private.portal_push_deliveries enable row level security;
revoke all on private.portal_push_devices,private.portal_push_deliveries from public,anon,authenticated,service_role;

create function private.portal_push_session_valid(p_user uuid,p_session uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.profiles p join auth.sessions s on s.user_id=p.id
  where p.id=p_user and s.id=p_session and p.active and not coalesce(p.archived,false)
  and p.role in ('admin','agent') and (s.not_after is null or s.not_after>now()));
$$;

-- Only the server dispatcher can call this helper. It reuses the inbox's CURRENT
-- agency, chat membership and leaderboard rules; no copied permission logic.
-- Temporary claims are restored even if the source function fails.
create function private.portal_push_items(p_user uuid,p_session uuid)
returns table(event_key text,category text,title text,body text,target jsonb,occurred_at timestamptz,source_read boolean)
language plpgsql security definer set search_path='' as $$
declare old_claims text:=current_setting('request.jwt.claims',true); old_sub text:=current_setting('request.jwt.claim.sub',true);
begin
 if not private.portal_push_session_valid(p_user,p_session) then return;end if;
 perform set_config('request.jwt.claim.sub',p_user::text,true);
 perform set_config('request.jwt.claims',jsonb_build_object('sub',p_user,'aal','aal2','role','authenticated','session_id',p_session)::text,true);
 return query select n.* from private.portal_notification_items() n;
 perform set_config('request.jwt.claims',coalesce(old_claims,''),true);
 perform set_config('request.jwt.claim.sub',coalesce(old_sub,''),true);
exception when others then
 perform set_config('request.jwt.claims',coalesce(old_claims,''),true);
 perform set_config('request.jwt.claim.sub',coalesce(old_sub,''),true);
 raise;
end $$;

create function private.portal_push_manage(p_user uuid,p_session uuid,p_action text,p_data jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare d private.portal_push_devices; cats text[]; sub jsonb:=p_data->'subscription'; job uuid; n record; endpoint_value text;
begin
 if not private.portal_push_session_valid(p_user,p_session) then raise exception 'Sign in again to manage phone notifications' using errcode='42501';end if;
 if p_action='open' then
  select x.* into n from private.portal_push_deliveries q join private.portal_push_devices device on device.id=q.device_id
   cross join lateral private.portal_push_items(p_user,p_session) x
   where q.id=(p_data->>'id')::uuid and device.user_id=p_user and x.event_key=q.event_key limit 1;
  if not found then return jsonb_build_object('item',null);end if;
  return jsonb_build_object('item',jsonb_build_object('key',n.event_key,'category',n.category,'title',n.title,'body',n.body,'target',n.target,'at',n.occurred_at,'read',n.source_read));
 end if;
 if p_action in ('subscribe','sync') then
  endpoint_value:=case when p_action='subscribe' then sub->>'endpoint' else p_data->>'endpoint' end;
  if endpoint_value is null or length(endpoint_value)>2048 or endpoint_value !~ '^https://([a-z0-9-]+\.)*push\.apple\.com/[^[:space:]#]+$|^https://fcm\.googleapis\.com/[^[:space:]#]+$|^https://updates\.push\.services\.mozilla\.com/[^[:space:]#]+$' then raise exception 'Unsupported notification endpoint';end if;
  perform pg_advisory_xact_lock(hashtextextended(p_user::text,8291));
  select * into d from private.portal_push_devices where endpoint=endpoint_value for update;
  if found and d.user_id<>p_user then raise exception 'Reset phone notifications on this device before switching accounts' using errcode='42501';end if;
  if p_action='sync' then
   if d.id is null then return jsonb_build_object('device',null);end if;
   update private.portal_push_devices set session_id=p_session,updated_at=now() where id=d.id returning * into d;
  else
   if d.id is null and (select count(*) from private.portal_push_devices where user_id=p_user)>=10 then raise exception 'Phone notification device limit reached';end if;
   if coalesce(sub->'keys'->>'p256dh','') !~ '^[A-Za-z0-9_-]{87}$' or coalesce(sub->'keys'->>'auth','') !~ '^[A-Za-z0-9_-]{22}$' then raise exception 'Invalid notification keys';end if;
   insert into private.portal_push_devices(user_id,session_id,endpoint,p256dh,auth_key)
    values(p_user,p_session,endpoint_value,sub->'keys'->>'p256dh',sub->'keys'->>'auth')
   on conflict(endpoint) do update set session_id=excluded.session_id,p256dh=excluded.p256dh,auth_key=excluded.auth_key,
    enabled=true,started_at=case when private.portal_push_devices.enabled then private.portal_push_devices.started_at else now() end,updated_at=now(),last_status=null
   returning * into d;
  end if;
 else
  select * into d from private.portal_push_devices where id=(p_data->>'id')::uuid and user_id=p_user for update;
  if d.id is null then raise exception 'Phone notification device not found' using errcode='42501';end if;
  if p_action='disable' then
   delete from private.portal_push_devices where id=d.id;
   return jsonb_build_object('device',null);
  elsif p_action='preferences' then
   if jsonb_typeof(p_data->'categories') is distinct from 'array' or jsonb_array_length(p_data->'categories')>8 then raise exception 'Invalid phone notification choices';end if;
   select coalesce(array_agg(distinct value),'{}') into cats from jsonb_array_elements_text(p_data->'categories');
   if not cats<@array['leads','requests','calls','deals','chat','announcements','team','billing']::text[] then raise exception 'Invalid phone notification choices';end if;
   update private.portal_push_devices set categories=cats,updated_at=now() where id=d.id returning * into d;
   update private.portal_push_deliveries set state='skipped' where device_id=d.id and state='pending' and category<>all(cats) and category<>'test';
  elsif p_action='test' then
   if not d.enabled then raise exception 'Enable phone notifications first';end if;
   if d.test_at>now()-interval '30 seconds' then raise exception 'Wait 30 seconds before sending another test';end if;
   update private.portal_push_devices set test_at=now() where id=d.id;
   insert into private.portal_push_deliveries(device_id,event_key,event_version,category,occurred_at)
    values(d.id,'test:'||gen_random_uuid(),'1','test',now()) returning id into job;
   return jsonb_build_object('job',job);
  else raise exception 'Unknown phone notification action';end if;
 end if;
 return jsonb_build_object('device',jsonb_build_object('id',d.id,'enabled',d.enabled,'categories',d.categories,'last_status',d.last_status));
end $$;

create function private.portal_push_batch(p_test uuid default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare d private.portal_push_devices; q private.portal_push_deliveries; n record; jobs jsonb:='[]'; lease_id uuid; valid_item boolean;
begin
 if p_test is null and pg_try_advisory_xact_lock(829117,1) then
  delete from private.portal_push_deliveries where created_at<now()-interval '7 days';
  update private.portal_push_deliveries set state='failed' where state in ('pending','sending') and (created_at<now()-interval '1 hour' or (attempts>=5 and next_attempt<=now()));
  for d in select * from private.portal_push_devices where enabled order by scanned_at limit 100 loop
   if not private.portal_push_session_valid(d.user_id,d.session_id) then
    update private.portal_push_devices set enabled=false where id=d.id;continue;
   end if;
   insert into private.portal_push_deliveries(device_id,event_key,event_version,category,occurred_at)
    select d.id,x.event_key,case when x.category='chat' then coalesce(x.target->>'message_id',x.occurred_at::text) else x.occurred_at::text end,x.category,x.occurred_at
    from private.portal_push_items(d.user_id,d.session_id) x
    left join private.portal_notification_receipts receipt on receipt.user_id=d.user_id and receipt.event_key=x.event_key
    left join private.portal_notification_preferences pref on pref.user_id=d.user_id
    where x.occurred_at>d.started_at and x.occurred_at>=now()-interval '1 hour' and x.occurred_at<=now()
     and x.category=any(d.categories) and not(x.category=any(coalesce(pref.muted_categories,'{}')))
     and not x.source_read and not coalesce(receipt.read_at>=x.occurred_at,false) and not coalesce(receipt.archived_at>=x.occurred_at,false)
     and (x.category<>'chat' or not exists(select 1 from private.portal_push_deliveries prior
      where prior.device_id=d.id and prior.event_key=x.event_key and prior.event_version ~ '^[0-9]+$'
      and x.target->>'message_id' ~ '^[0-9]+$' and prior.event_version::numeric>(x.target->>'message_id')::numeric))
    on conflict(device_id,event_key,event_version) do nothing;
   update private.portal_push_devices set scanned_at=now() where id=d.id;
  end loop;
 end if;
 for q in select * from private.portal_push_deliveries where state in ('pending','sending') and next_attempt<=now()
   and attempts<5 and created_at>=now()-interval '1 hour' and (p_test is null or id=p_test)
   order by created_at,id limit 30 for update skip locked loop
  select * into d from private.portal_push_devices where id=q.device_id;
  if not d.enabled or not private.portal_push_session_valid(d.user_id,d.session_id) then
   update private.portal_push_deliveries set state='skipped' where id=q.id;continue;
  end if;
  if q.category='test' then
   select 'Phone notifications are ready'::text title,'Vivid Life Portal can now send alerts to this device.'::text body into n;valid_item:=true;
  else
   select x.* into n from private.portal_push_items(d.user_id,d.session_id) x
    left join private.portal_notification_receipts receipt on receipt.user_id=d.user_id and receipt.event_key=x.event_key
    left join private.portal_notification_preferences pref on pref.user_id=d.user_id
    where x.event_key=q.event_key and x.category=any(d.categories)
     and (case when x.category='chat' then coalesce(x.target->>'message_id',x.occurred_at::text) else x.occurred_at::text end)=q.event_version
     and not(x.category=any(coalesce(pref.muted_categories,'{}'))) and not x.source_read
     and not coalesce(receipt.read_at>=x.occurred_at,false) and not coalesce(receipt.archived_at>=x.occurred_at,false);
   valid_item:=found;
  end if;
  if not valid_item then update private.portal_push_deliveries set state='skipped' where id=q.id;continue;end if;
  lease_id:=gen_random_uuid();
  update private.portal_push_deliveries set state='sending',attempts=attempts+1,lease=lease_id,next_attempt=now()+interval '2 minutes' where id=q.id;
  jobs:=jobs||jsonb_build_array(jsonb_build_object('id',q.id,'lease',lease_id,'category',q.category,
   'subscription',jsonb_build_object('endpoint',d.endpoint,'keys',jsonb_build_object('p256dh',d.p256dh,'auth',d.auth_key)),
   'title',case q.category when 'deals' then left(n.title,120) when 'chat' then 'New chat message' when 'leads' then 'New leads available' when 'requests' then 'Lead request update' when 'calls' then 'Callback or voicemail update' when 'announcements' then 'New announcement' when 'team' then 'Team update' when 'billing' then 'Calling plan update' else n.title end,
   'body',case when q.category in ('deals','test') then left(n.body,180) else 'Open Vivid Life Portal to view your update.' end));
 end loop;
 return jobs;
end $$;

create function private.portal_push_finish(p_id uuid,p_lease uuid,p_status integer)
returns boolean language plpgsql security definer set search_path='' as $$
declare q private.portal_push_deliveries;
begin
 select * into q from private.portal_push_deliveries where id=p_id and lease=p_lease and state='sending' for update;
 if not found then return false;end if;
 update private.portal_push_deliveries set state=case when p_status between 200 and 299 then 'sent' when p_status in (404,410,400,413,422) or attempts>=5 then 'failed' else 'pending' end,
  last_status=p_status,next_attempt=now()+make_interval(secs=>least(900,30*power(2,q.attempts)::integer)),lease=null where id=q.id;
 update private.portal_push_devices set last_status=p_status,enabled=case when p_status in (404,410) then false else enabled end where id=q.device_id;
 return true;
end $$;

-- Public API wrappers are invoker functions; only trusted server code may call
-- them. The server derives p_user/p_session from a verified AAL2 access token.
create function public.portal_push_manage(p_user uuid,p_session uuid,p_action text,p_data jsonb default '{}') returns jsonb language sql security invoker set search_path='' as $$select private.portal_push_manage(p_user,p_session,p_action,p_data)$$;
create function public.portal_push_batch(p_test uuid default null) returns jsonb language sql security invoker set search_path='' as $$select private.portal_push_batch(p_test)$$;
create function public.portal_push_finish(p_id uuid,p_lease uuid,p_status integer) returns boolean language sql security invoker set search_path='' as $$select private.portal_push_finish(p_id,p_lease,p_status)$$;
revoke all on function private.portal_push_session_valid(uuid,uuid),private.portal_push_items(uuid,uuid),private.portal_push_manage(uuid,uuid,text,jsonb),private.portal_push_batch(uuid),private.portal_push_finish(uuid,uuid,integer),public.portal_push_manage(uuid,uuid,text,jsonb),public.portal_push_batch(uuid),public.portal_push_finish(uuid,uuid,integer) from public,anon,authenticated;
grant usage on schema private to service_role;
grant execute on function private.portal_push_manage(uuid,uuid,text,jsonb),private.portal_push_batch(uuid),private.portal_push_finish(uuid,uuid,integer),public.portal_push_manage(uuid,uuid,text,jsonb),public.portal_push_batch(uuid),public.portal_push_finish(uuid,uuid,integer) to service_role;
notify pgrst,'reload schema';
