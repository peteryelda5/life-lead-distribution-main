create table public.master_dialer_call_usage (
 grant_id uuid primary key references public.master_dialer_call_grants(id),
 parent_call_sid text not null unique check (parent_call_sid ~ '^CA[0-9a-fA-F]{32}$'),
 child_call_sid text not null unique check (child_call_sid ~ '^CA[0-9a-fA-F]{32}$'),
 call_started_at timestamptz not null,
 duration_seconds integer not null check (duration_seconds between 0 and 7200),
 used_minutes integer generated always as ((duration_seconds+59)/60) stored,
 call_status text not null check (call_status in ('completed','busy','failed','no-answer','canceled')),
 recorded_at timestamptz not null default now()
);
create index master_dialer_call_usage_month on public.master_dialer_call_usage(call_started_at);
alter table public.master_dialer_call_usage enable row level security;
revoke all on public.master_dialer_call_usage from public,anon,authenticated;
grant select,insert on public.master_dialer_call_usage to service_role;
create function public.record_master_dialer_usage(p_parent_sid text,p_child_sid text,p_duration integer,p_status text)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare g public.master_dialer_call_grants%rowtype; u public.master_dialer_call_usage%rowtype; inserted integer;
begin
 if p_parent_sid is null or p_child_sid is null or p_parent_sid !~ '^CA[0-9a-fA-F]{32}$' or p_child_sid !~ '^CA[0-9a-fA-F]{32}$' or p_parent_sid=p_child_sid or p_duration is null or p_duration not between 0 and 7200 or p_status is null or p_status not in ('completed','busy','failed','no-answer','canceled') or (p_status<>'completed' and p_duration<>0) then raise exception 'Invalid call usage'; end if;
 select * into g from public.master_dialer_call_grants where twilio_call_sid=p_parent_sid for update;
 if not found then raise exception 'Call does not belong to this dialer'; end if;
 insert into public.master_dialer_call_usage(grant_id,parent_call_sid,child_call_sid,call_started_at,duration_seconds,call_status) values(g.id,p_parent_sid,p_child_sid,g.created_at,p_duration,p_status) on conflict do nothing;
 get diagnostics inserted=row_count;
 select * into u from public.master_dialer_call_usage where grant_id=g.id;
 if not found or u.parent_call_sid<>p_parent_sid or u.child_call_sid<>p_child_sid or u.duration_seconds<>p_duration or u.call_status<>p_status then raise exception 'Conflicting call usage'; end if;
 return jsonb_build_object('recorded',inserted=1,'usedMinutes',u.used_minutes);
end $$;
revoke all on function public.record_master_dialer_usage(text,text,integer,text) from public,anon,authenticated;
grant execute on function public.record_master_dialer_usage(text,text,integer,text) to service_role;
create function public.master_dialer_month_usage()
returns jsonb language sql security invoker set search_path='' as $$
 with period as (
 select date_trunc('month',now() at time zone 'America/New_York') at time zone 'America/New_York' as starts,
 (date_trunc('month',now() at time zone 'America/New_York')+interval '1 month') at time zone 'America/New_York' as ends
 ), totals as (
 select count(u.grant_id) as calls,coalesce(sum(u.used_minutes),0) as minutes,coalesce(sum(u.duration_seconds),0) as seconds from period p left join public.master_dialer_call_usage u on u.call_started_at>=p.starts and u.call_started_at<p.ends
 )
 select jsonb_build_object('periodStart',p.starts,'periodEnd',p.ends,'timezone','America/New_York','periodType','calendar_month_pilot','usedMinutes',t.minutes,'durationSeconds',t.seconds,'calls',t.calls,'includedMinutes',5000,'remainingMinutes',greatest(5000-t.minutes,0),'overageMinutes',greatest(t.minutes-5000,0),'estimatedOverageCents',greatest(t.minutes-5000,0)*3,'alertPercent',case when t.minutes>=4750 then 95 when t.minutes>=4000 then 80 else null end,'billingEnabled',false) from period p cross join totals t;
 $$;
revoke all on function public.master_dialer_month_usage() from public,anon,authenticated;
grant execute on function public.master_dialer_month_usage() to service_role;
comment on table public.master_dialer_call_usage is 'Master pilot outbound call durations. Idempotent Twilio-signed completion callbacks only. No real subscription overage charges.';
