
create table public.dialer_test_wallet_credits (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references public.profiles(id),
 stripe_session_id text not null unique check (stripe_session_id ~ '^cs_test_[A-Za-z0-9]{10,240}$'),
 stripe_payment_intent_id text not null unique check (stripe_payment_intent_id ~ '^pi_[A-Za-z0-9]{10,240}$'),
 amount_cents integer not null check (amount_cents=2500),
 currency text not null default 'usd' check (currency='usd'),
 created_at timestamptz not null default now(),
 check (user_id='8139e230-055d-4247-8133-684ed817b4fa'::uuid)
);
create index dialer_test_wallet_user_time on public.dialer_test_wallet_credits(user_id,created_at desc);
alter table public.dialer_test_wallet_credits enable row level security;
revoke all on public.dialer_test_wallet_credits from public,anon,authenticated,service_role;
grant select on public.dialer_test_wallet_credits to authenticated;
grant select,insert on public.dialer_test_wallet_credits to service_role;
create policy master_reads_own_test_wallet on public.dialer_test_wallet_credits for select to authenticated
 using (user_id=(select auth.uid()) and (select private.verified_portal_session()) and (select public.is_super_admin()));
create function public.credit_dialer_test_wallet(p_session_id text,p_payment_intent_id text)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare inserted integer; total bigint;
begin
 if p_session_id is null or p_payment_intent_id is null or p_session_id !~ '^cs_test_[A-Za-z0-9]{10,240}$' or p_payment_intent_id !~ '^pi_[A-Za-z0-9]{10,240}$' then raise exception 'Invalid test payment reference';end if;
 insert into public.dialer_test_wallet_credits(user_id,stripe_session_id,stripe_payment_intent_id,amount_cents)
 values ('8139e230-055d-4247-8133-684ed817b4fa'::uuid,p_session_id,p_payment_intent_id,2500)
 on conflict do nothing;
 get diagnostics inserted=row_count;
 select coalesce(sum(amount_cents),0) into total from public.dialer_test_wallet_credits where user_id='8139e230-055d-4247-8133-684ed817b4fa'::uuid;
 return jsonb_build_object('balanceCents',total,'credited',inserted=1,'testMode',true);
end $$;
revoke all on function public.credit_dialer_test_wallet(text,text) from public,anon,authenticated;
grant execute on function public.credit_dialer_test_wallet(text,text) to service_role;
create function public.my_dialer_test_wallet() returns jsonb language sql stable security invoker set search_path='' as $$
 select jsonb_build_object('testMode',true,'balanceCents',coalesce((select sum(c.amount_cents) from public.dialer_test_wallet_credits c where c.user_id=auth.uid()),0),
 'transactions',coalesce((select jsonb_agg(t order by t.created_at desc) from (select id,amount_cents,created_at from public.dialer_test_wallet_credits where user_id=auth.uid() order by created_at desc limit 20) t),'[]'::jsonb))
$$;
revoke all on function public.my_dialer_test_wallet() from public,anon;
grant execute on function public.my_dialer_test_wallet() to authenticated;
