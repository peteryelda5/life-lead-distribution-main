create table public.dialer_number_preferences (
 user_id uuid primary key references public.profiles(id),
 phone_number text not null check (phone_number ~ '^\+1[2-9][0-9]{2}[2-9][0-9]{6}$'),
 area_code text not null check (area_code ~ '^[2-9][0-9]{2}$'),
 stripe_test_session_id text not null check (stripe_test_session_id ~ '^cs_test_[A-Za-z0-9]{10,240}$'),
 updated_at timestamptz not null default now(),
 constraint master_number_preference_pilot check (user_id='8139e230-055d-4247-8133-684ed817b4fa'::uuid),
 constraint matching_area_code check (substring(phone_number from 3 for 3)=area_code)
);
alter table public.dialer_number_preferences enable row level security;
revoke all on public.dialer_number_preferences from public,anon,authenticated;
grant select,insert,update on public.dialer_number_preferences to service_role;
comment on table public.dialer_number_preferences is 'Master sandbox preference only. Does not reserve, purchase or activate any phone number. Server-only access.';
