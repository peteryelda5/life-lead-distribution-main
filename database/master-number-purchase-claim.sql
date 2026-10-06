alter table public.master_dialer_numbers add column purchase_started boolean not null default false;
create function public.claim_master_number_purchase(p_key uuid)
returns boolean language plpgsql security invoker set search_path='' as $$
declare affected integer;
begin
 update public.master_dialer_numbers set purchase_started=true where purchase_key=p_key and state='pending' and not purchase_started;
 get diagnostics affected=row_count;return affected=1;
end $$;
revoke all on function public.claim_master_number_purchase(uuid) from public,anon,authenticated;
grant execute on function public.claim_master_number_purchase(uuid) to service_role;
