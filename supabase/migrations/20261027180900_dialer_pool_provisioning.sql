alter table public.dialer_caller_pools add column provision_authorized boolean not null default false;
alter table public.dialer_pool_numbers alter column phone drop not null;
alter table public.dialer_pool_numbers add column requested_area text check(requested_area ~ '^[2-9][0-9]{2}$');
alter table public.dialer_pool_numbers add column provision_error text;
alter table public.dialer_pool_numbers add column attempted_at timestamptz;
-- Missing/paused caller IDs never enter the outgoing selection.
alter table public.dialer_pool_numbers add constraint active_pool_number_requires_sid check(state not in ('active','paused') or (phone is not null and provider_number_sid ~ '^PN[0-9a-fA-F]{32}$'));
