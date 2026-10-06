-- Peter's live account alone receives complimentary access. Agent billing is unchanged.
create or replace function public.dialer_sync_master_access(p_user uuid,p_live boolean) returns jsonb language plpgsql security invoker set search_path='' as $$
declare a public.dialer_accounts%rowtype; start_at timestamptz;end_at timestamptz;begin
 if p_user<>'8139e230-055d-4247-8133-684ed817b4fa'::uuid or not p_live or not exists(select 1 from public.profiles where id=p_user and active and not archived and role='admin') then raise exception 'Master live access only';end if;
 select * into a from public.dialer_accounts where user_id=p_user and livemode=p_live for update;
 if not found then raise exception 'Billing account unavailable';end if;
 if a.subscription_id is not null then raise exception 'Review the existing paid subscription before enabling free access';end if;
 start_at:=date_trunc('month',now() at time zone 'UTC') at time zone 'UTC';end_at:=(date_trunc('month',now() at time zone 'UTC')+interval '1 month') at time zone 'UTC';
 update public.dialer_accounts set subscription_status='owner_exempt',paid_invoice=false,period_start=start_at,period_end=end_at,verified_at=now(),cancel_at_period_end=false where user_id=p_user and livemode=p_live returning * into a;
 insert into public.dialer_periods(user_id,livemode,starts_at,ends_at,subscription_id,customer_id) values(p_user,p_live,start_at,end_at,'owner_exempt_'||p_user::text,a.customer_id) on conflict(user_id,livemode,starts_at) do nothing;
 return to_jsonb(a);
end $$;
revoke all on function public.dialer_sync_master_access(uuid,boolean) from public,anon,authenticated;
grant execute on function public.dialer_sync_master_access(uuid,boolean) to service_role;
create or replace function public.dialer_entitled(p_user uuid,p_live boolean) returns boolean language sql stable security invoker set search_path='' as $$
 select exists(select 1 from public.dialer_accounts a join public.profiles p on p.id=a.user_id where a.user_id=p_user and a.livemode=p_live and p.active and not p.archived and a.period_start<=now() and a.period_end>now() and a.verified_at>now()-interval '5 minutes' and ((a.subscription_status='active' and a.paid_invoice) or (p_user='8139e230-055d-4247-8133-684ed817b4fa'::uuid and p_live and p.role='admin' and a.subscription_status='owner_exempt' and a.subscription_id is null)));
$$;
