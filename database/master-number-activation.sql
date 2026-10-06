create table public.master_dialer_numbers (
 user_id uuid primary key references public.profiles(id) check(user_id='8139e230-055d-4247-8133-684ed817b4fa'::uuid),
 phone_number text not null unique check(phone_number ~ '^\+1[2-9][0-9]{2}[2-9][0-9]{6}$'),
 purchase_key uuid not null unique default gen_random_uuid(),
 state text not null default 'pending' check(state in ('pending','active')),
 twilio_number_sid text unique check(twilio_number_sid ~ '^PN[0-9a-fA-F]{32}$'),
 created_at timestamptz not null default now(),
 activated_at timestamptz,
 check((state='active')=(twilio_number_sid is not null))
);
alter table public.master_dialer_numbers enable row level security;
revoke all on public.master_dialer_numbers from public,anon,authenticated;
grant select,insert,update on public.master_dialer_numbers to service_role;
create function public.begin_master_number_activation(p_session_id uuid,p_expected_phone text)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare pref public.dialer_number_preferences%rowtype; n public.master_dialer_numbers%rowtype;
begin
 if not private.master_dialer_session_active(p_session_id) or not exists(select 1 from public.profiles where id='8139e230-055d-4247-8133-684ed817b4fa'::uuid and active and is_super_admin and role='admin' and not archived) then raise exception 'Master session is unavailable'; end if;
 select * into pref from public.dialer_number_preferences where user_id='8139e230-055d-4247-8133-684ed817b4fa'::uuid for update;
 if not found or pref.phone_number is distinct from p_expected_phone then raise exception 'Load and confirm your saved preferred number first'; end if;
 select * into n from public.master_dialer_numbers where user_id=pref.user_id for update;
 if found then return jsonb_build_object('phoneNumber',n.phone_number,'state',n.state,'purchaseKey',n.purchase_key,'mayPurchase',false); end if;
 insert into public.master_dialer_numbers(user_id,phone_number) values(pref.user_id,pref.phone_number) returning * into n;
 return jsonb_build_object('phoneNumber',n.phone_number,'state',n.state,'purchaseKey',n.purchase_key,'mayPurchase',true);
end $$;
create function public.finish_master_number_activation(p_key uuid,p_phone text,p_sid text)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare n public.master_dialer_numbers%rowtype;
begin
 if p_sid is null or p_sid !~ '^PN[0-9a-fA-F]{32}$' then raise exception 'Invalid Twilio number'; end if;
 select * into n from public.master_dialer_numbers where purchase_key=p_key for update;
 if not found or n.phone_number is distinct from p_phone or (n.state='active' and n.twilio_number_sid is distinct from p_sid) then raise exception 'Number activation mismatch'; end if;
 update public.master_dialer_numbers set state='active',twilio_number_sid=p_sid,activated_at=coalesce(activated_at,now()) where purchase_key=p_key;
 return jsonb_build_object('phoneNumber',p_phone,'state','active');
end $$;
create function public.master_number_activation_status()
returns jsonb language sql security invoker set search_path='' as $$
 select coalesce((select jsonb_build_object('phoneNumber',phone_number,'state',state) from public.master_dialer_numbers where user_id='8139e230-055d-4247-8133-684ed817b4fa'::uuid),'{}'::jsonb);
$$;
create function public.active_master_dialer_number()
returns text language sql security invoker set search_path='' as $$
 select phone_number from public.master_dialer_numbers where user_id='8139e230-055d-4247-8133-684ed817b4fa'::uuid and state='active';
$$;
revoke all on function public.begin_master_number_activation(uuid,text),public.finish_master_number_activation(uuid,text,text),public.master_number_activation_status(),public.active_master_dialer_number() from public,anon,authenticated;
grant execute on function public.begin_master_number_activation(uuid,text),public.finish_master_number_activation(uuid,text,text),public.master_number_activation_status(),public.active_master_dialer_number() to service_role;
