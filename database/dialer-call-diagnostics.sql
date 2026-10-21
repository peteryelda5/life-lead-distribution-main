-- Provider diagnostics are operational records, never exposed to portal clients.
-- No call audio, transcripts, credentials, customer numbers, or IP addresses.
create table public.dialer_call_diagnostics (
 call_id uuid primary key references public.dialer_calls(id) on delete cascade,
 checked_at timestamptz not null default now(),
 state text not null check(state in ('complete','partial','unavailable')),
 details jsonb not null check(jsonb_typeof(details)='object' and octet_length(details::text)<=32768)
);
alter table public.dialer_call_diagnostics enable row level security;
revoke all on public.dialer_call_diagnostics from public,anon,authenticated;
grant select,insert,update,delete on public.dialer_call_diagnostics to service_role;
create index dialer_call_diagnostics_checked_at on public.dialer_call_diagnostics(checked_at);
