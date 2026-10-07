
create table public.dialer_at_cost (
 user_id uuid primary key references public.profiles(id),
 required_role text not null check(required_role in ('admin','agent')),
 enabled boolean not null default true,
 provider_sid text unique, provider_app text, provider_key text, provider_secret_cipher text,
 provisioning boolean not null default false,
 payment_session text,
 created_at timestamptz not null default now(),
 billed_through date not null default date_trunc('month',now() at time zone 'UTC')::date,
 cost_usd numeric, cost_checked_at timestamptz
);
create table public.dialer_at_cost_invoices (
 user_id uuid not null references public.dialer_at_cost(user_id), through_date date not null,
 from_date date not null, amount_cents integer not null check(amount_cents>=50),
 invoice_id text, state text not null default 'pending',
 primary key(user_id,through_date)
);
alter table public.dialer_at_cost enable row level security;
alter table public.dialer_at_cost_invoices enable row level security;
revoke all on public.dialer_at_cost,public.dialer_at_cost_invoices from public,anon,authenticated;
grant select,insert,update on public.dialer_at_cost,public.dialer_at_cost_invoices to service_role;
insert into public.dialer_at_cost(user_id,required_role) values
 ('6b2007a4-8bd8-4b4c-b65c-6d4a28dce4b3','admin'),
 ('7b5e5b17-766f-4e49-9cf5-2e57f33575eb','agent'),
 ('4733ed70-f774-4209-a8b5-fd233d0bb638','admin');
create function public.dialer_sync_at_cost(p_user uuid,p_live boolean,p_ready boolean) returns jsonb language plpgsql security invoker set search_path='' as $$
declare a public.dialer_accounts%rowtype;start_at timestamptz;end_at timestamptz;begin
 if not p_live or not exists(select 1 from public.dialer_at_cost b join public.profiles p on p.id=b.user_id where b.user_id=p_user and b.enabled and p.active and not p.archived and p.role::text=b.required_role) then raise exception 'Actual-cost account unavailable';end if;
 select * into a from public.dialer_accounts where user_id=p_user and livemode=p_live for update;
 if not found or a.subscription_id is not null then raise exception 'Review billing account before actual-cost access';end if;
 start_at:=date_trunc('month',now() at time zone 'UTC') at time zone 'UTC';end_at:=start_at+interval '1 month';
 update public.dialer_accounts set subscription_status=case when p_ready then 'at_cost' else 'at_cost_pending' end,paid_invoice=false,period_start=start_at,period_end=end_at,verified_at=now(),cancel_at_period_end=false where user_id=p_user and livemode=p_live returning * into a;
 insert into public.dialer_periods(user_id,livemode,starts_at,ends_at,subscription_id,customer_id) values(p_user,p_live,start_at,end_at,'at_cost_'||p_user::text,a.customer_id) on conflict(user_id,livemode,starts_at) do nothing;
 return to_jsonb(a);
end $$;
revoke all on function public.dialer_sync_at_cost(uuid,boolean,boolean) from public,anon,authenticated;
grant execute on function public.dialer_sync_at_cost(uuid,boolean,boolean) to service_role;
create or replace function public.dialer_entitled(p_user uuid,p_live boolean) returns boolean language sql stable security invoker set search_path='' as $$
 select exists(select 1 from public.dialer_accounts a join public.profiles p on p.id=a.user_id where a.user_id=p_user and a.livemode=p_live and p.active and not p.archived and a.period_start<=now() and a.period_end>now() and a.verified_at>now()-interval '5 minutes' and (
 (a.subscription_status='active' and a.paid_invoice)
 or (p_user='8139e230-055d-4247-8133-684ed817b4fa'::uuid and p_live and p.role='admin' and a.subscription_status='owner_exempt' and a.subscription_id is null)
 or (p_live and a.subscription_status='at_cost' and a.subscription_id is null and exists(select 1 from public.dialer_at_cost b where b.user_id=p_user and b.enabled and b.required_role=p.role::text and b.provider_sid is not null and b.provider_secret_cipher is not null))
 ));
$$;
create function public.dialer_claim_at_cost_provider(p_user uuid) returns boolean language plpgsql security invoker set search_path='' as $$
begin
 update public.dialer_at_cost set provisioning=true where user_id=p_user and enabled and not provisioning and provider_secret_cipher is null;
 return found;
end $$;
revoke all on function public.dialer_claim_at_cost_provider(uuid) from public,anon,authenticated;
grant execute on function public.dialer_claim_at_cost_provider(uuid) to service_role;
